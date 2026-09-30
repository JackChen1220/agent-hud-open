import Foundation
import Security

// Credential order and request headers follow Tokscale usage/copilot.rs (MIT); quota fields are informed by CodexBar CopilotUsageFetcher (MIT).
struct CopilotClient: Sendable {
    /// Quota reading needs the user's consent in Settings; without it no credential is touched and nothing is sent.
    var enabled: @Sendable () async -> Bool
    var token: @Sendable () -> String? = { CopilotCredentials().token() }
    var http = ProviderHTTP()

    /// The consent as `settings` holds it when asked. The switch in Settings changes it through the same store, which
    /// wakes collection, so a reading follows the switch at once.
    static func consent(in settings: SettingsStore) -> @Sendable () async -> Bool {
        { await settings.settings.readCopilotQuota }
    }

    func fetch() async throws -> ProviderQuota {
        guard await enabled() else { return ProviderQuota(forgetAccounts: true) }
        guard let token = token() else { return ProviderQuota(notice: ProviderFailure.login("GitHub CLI").message) }
        let headers = ["Authorization": "token \(token)", "Editor-Version": "vscode/1.96.2", "Editor-Plugin-Version": "copilot-chat/0.26.7",
                       "User-Agent": "GitHubCopilotChat/0.26.7", "X-Github-Api-Version": "2025-04-01"]
        var quota = try Self.parse(try await http.json(URL(string: "https://api.github.com/copilot_internal/user")!, headers: headers))
        // The quota response does not name the user; GitHub's profile of the same token does. Without it the rows stay unresolved.
        if let user = try? await http.json(URL(string: "https://api.github.com/user")!, headers: headers) {
            (quota.account, quota.label) = (Self.account(user), user["login"].stringValue)
        }
        return quota
    }

    /// The numeric GitHub id is stable across renames; organisation membership does not show which one holds the seat.
    static func account(_ user: ProviderJSON) -> ProviderAccount? {
        guard let id = user["id"].countValue else { return nil }
        return .identified(provider: AdditionalSource.copilot.vendor, user: "github.com:\(id)", workspace: nil)
    }

    static func parse(_ response: ProviderJSON) throws -> ProviderQuota {
        guard response.objectValue != nil else { throw ProviderFailure.format }
        func number(_ value: ProviderJSON) -> Double? { value.numberValue ?? value.stringValue.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        func keys(_ object: [String: ProviderJSON]) -> [String] {
            let known = ["premium_interactions", "chat", "completions"]
            return known.filter { object[$0] != nil } + object.keys.filter { !known.contains($0) }.sorted()
        }
        var quota = ProviderQuota(plan: response["copilot_plan"].stringValue.flatMap { $0.isEmpty ? nil : $0 })
        let snapshots = response["quota_snapshots"].objectValue ?? [:], reset = date(response["quota_reset_date"].stringValue)
        for key in keys(snapshots) {
            let item = snapshots[key]!, entitlement = number(item["entitlement"]), remaining = number(item["remaining"])
            // Unlimited windows and zero-entitlement placeholders are not metered.
            guard item["unlimited"].boolValue != true, !(entitlement == 0 && remaining == 0),
                  let percent = number(item["percent_remaining"]) ?? entitlement.flatMap({ total in
                      total > 0 ? remaining.map { $0 / total * 100 } : nil }) else { continue }
            quota.windows.append(.init(id: "copilot:\(key)", label: label(key), remaining: min(100, max(0, percent)), reset: reset))
        }
        // Free accounts report remaining and monthly counts instead of snapshots.
        if quota.windows.isEmpty, let limited = response["limited_user_quotas"].objectValue {
            let reset = date(response["limited_user_reset_date"].stringValue)
            for key in keys(limited) {
                guard let remaining = number(limited[key]!), let total = number(response["monthly_quotas"][key]), total > 0 else { continue }
                quota.windows.append(.init(id: "copilot:\(key)", label: label(key), remaining: min(100, max(0, remaining / total * 100)), reset: reset))
            }
        }
        return quota
    }

    static func label(_ key: String) -> String {
        switch key {
        case "premium_interactions": L10n.text("高级请求", "Premium requests")
        case "chat": L10n.text("对话", "Chat")
        case "completions": L10n.text("代码补全", "Completions")
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func date(_ text: String?) -> Date? {
        DateParsing.internet(text) ?? DateParsing.day(text)
    }
}

/// The GitHub CLI sign-in, read in memory only.
struct CopilotCredentials: Sendable {
    var environment = ProcessInfo.processInfo.environment
    var home = FileManager.default.homeDirectoryForCurrentUser
    var keychain: @Sendable (String) -> String? = { CopilotCredentials.genericPassword(service: $0) }
    var file: @Sendable (URL) -> String? = { url in
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 <= 1024 * 1024 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var hostsFile: URL {
        let folder = environment["GH_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).appendingPathComponent("gh") }
            ?? home.appendingPathComponent(".config/gh")
        return folder.appendingPathComponent("hosts.yml")
    }

    func token() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let value = Self.clean(environment[key]) { return value }
        }
        if let stored = keychain("gh:github.com") {
            // go-keyring may store the secret base64-encoded behind a prefix.
            guard stored.hasPrefix("go-keyring-base64:") else { return Self.clean(stored) }
            if let data = Data(base64Encoded: String(stored.dropFirst("go-keyring-base64:".count))),
               let value = Self.clean(String(data: data, encoding: .utf8)) { return value }
        }
        return file(hostsFile).flatMap(Self.hostsToken)
    }

    /// `oauth_token` inside the top-level `github.com:` section of `hosts.yml`.
    static func hostsToken(_ text: String) -> String? {
        var inHost = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "github.com:" && !(line.first?.isWhitespace ?? false) { inHost = true; continue }
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !(line.first?.isWhitespace ?? false) { inHost = false }
            if inHost, trimmed.hasPrefix("oauth_token:"), let value = clean(String(trimmed.dropFirst("oauth_token:".count))) {
                return value
            }
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func genericPassword(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
