import Foundation
import Darwin

// Local service discovery and quota schema follow CodexBar (MIT). Only already-running services are queried.
struct AntigravityClient: Sendable {
    struct Candidate: Sendable {
        let pid: Int
        let token: String
        let extensionPort: Int?
        let extensionToken: String?
        let priority: Int
    }
    var http = ProviderHTTP()

    func fetch() async throws -> ProviderQuota {
        let candidates = Self.candidates(try await ProviderCommand.run("/bin/ps", ["-U", String(getuid()), "-o", "pid=,command="]))
        guard !candidates.isEmpty else {
            return ProviderQuota(notice: AdditionalSource.antigravity.isInstalled()
                ? L10n.text("启动并登录 Antigravity 或 agy 后读取额度", "Start and sign in to Antigravity or agy to load quota") : nil)
        }
        let deadline = Date().addingTimeInterval(20)
        var fallback: ProviderQuota?
        for candidate in candidates.prefix(6) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let ports = (try? await ProviderCommand.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(candidate.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]))
                .map(Self.ports) ?? []
            var endpoints = ports.map { ("https", $0, candidate.token) }
            if let port = candidate.extensionPort { endpoints.append(("http", port, candidate.extensionToken ?? candidate.token)) }
            for (scheme, port, token) in endpoints.prefix(8) {
                try Task.checkCancellation()
                guard Date() < deadline else { break }
                let base = "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/"
                var headers = ["Connect-Protocol-Version": "1"]
                if !token.isEmpty { headers["X-Codeium-Csrf-Token"] = token }
                let body: ProviderJSON = .object(["metadata": .object([
                    "ideName": .string("antigravity"), "extensionName": .string("antigravity"), "locale": .string("en"), "ideVersion": .string("unknown")
                ])])
                if let json = try? await http.json(URL(string: base + "RetrieveUserQuotaSummary")!, headers: headers, body: body, timeout: 2),
                   var result = try? Self.summary(json), !result.windows.isEmpty {
                    // The IDE and agy can be signed in to different accounts, so identity comes from the same server.
                    if let status = try? await http.json(URL(string: base + "GetUserStatus")!, headers: headers, body: body, timeout: 2) {
                        (result.account, result.label) = Self.identity(status)
                    }
                    return result
                }
                if let json = try? await http.json(URL(string: base + "GetUserStatus")!, headers: headers, body: body, timeout: 2),
                   var result = try? Self.userStatus(json), !result.windows.isEmpty {
                    (result.account, result.label) = Self.identity(json)
                    fallback = fallback ?? result; break
                }
            }
        }
        if let fallback { return fallback }
        throw UsageProviderError(L10n.text("Antigravity 本地服务未返回可读取的额度", "Antigravity's local service returned no readable quota"))
    }

    static func candidates(_ output: String) -> [Candidate] {
        output.split(separator: "\n").compactMap { line in
            let pieces = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pieces.count == 2, let pid = Int(pieces[0]) else { return nil }
            let command = String(pieces[1]), lower = command.lowercased()
            let cli = lower.contains("/antigravity-cli/") || lower.contains("/antigravity_cli/")
                || lower.range(of: #"(?:^|/)agy(?:\s|$)"#, options: .regularExpression) != nil
            let server = (lower.contains("language_server") || lower.contains("language-server"))
                && (lower.contains("antigravity.app/") || lower.contains("antigravity ide.app/")
                    || lower.contains("/antigravity/") || flag("app_data_dir", command: command)?.hasPrefix("antigravity") == true)
            guard cli || server else { return nil }
            let token = flag("csrf_token", command: command)
            guard cli || token?.isEmpty == false else { return nil }
            let extensionPort = flag("extension_server_port", command: command).flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
            return Candidate(pid: pid, token: token ?? "", extensionPort: extensionPort,
                extensionToken: flag("extension_server_csrf_token", command: command),
                priority: cli ? 1 : lower.contains("antigravity-ide") || lower.contains("antigravity ide.app") ? 2 : 0)
        }.sorted { ($0.priority, $0.pid) < ($1.priority, $1.pid) }
    }

    private static func flag(_ name: String, command: String) -> String? {
        let pattern = #"(?:^|\s)--"# + NSRegularExpression.escapedPattern(for: name) + #"(?:=|\s+)(?:"([^"]+)"|'([^']+)'|([^\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: command) { return String(command[range]) }
        }
        return nil
    }

    static func ports(_ output: String) -> [Int] {
        Set(output.split(separator: "\n").filter { $0.hasPrefix("n") }.compactMap { line -> Int? in
            guard let raw = line.split(separator: ":").last, let port = Int(raw), (1...65535).contains(port) else { return nil }
            return port
        }).sorted()
    }

    static func summary(_ json: ProviderJSON) throws -> ProviderQuota {
        let groups = json["response"]["groups"].arrayValue ?? json["summary"]["groups"].arrayValue ?? json["groups"].arrayValue
        guard let groups else { throw ProviderFailure.format }
        var result = ProviderQuota(), ids = Set<String>()
        for group in groups {
            guard let buckets = group["buckets"].arrayValue else { throw ProviderFailure.format }
            for bucket in buckets {
                guard bucket["disabled"].boolValue != true, let id = bucket["bucketId"].stringValue, !id.isEmpty else { continue }
                let remaining = bucket["remaining"]
                let fraction = bucket["remainingFraction"].numberValue ?? remaining["remainingFraction"].numberValue
                    ?? (remaining["case"].stringValue == "remainingFraction" ? remaining["value"].numberValue : nil)
                guard let fraction, (0...1).contains(fraction) else { continue }
                guard ids.insert(id).inserted else { throw ProviderFailure.format }
                let label = [group["displayName"].stringValue, bucket["displayName"].stringValue ?? id].compactMap { $0 }.joined(separator: " · ")
                // Antigravity names its buckets Weekly Limit and Five Hour Limit; ids write the period with an underscore.
                let cadence = (id + " " + (bucket["displayName"].stringValue ?? "")).lowercased()
                    .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                let duration: TimeInterval? = cadence.contains("weekly") ? 604800
                    : cadence.contains("five hour") || cadence.contains("5 hour") ? 18000 : nil
                result.windows.append(.init(id: "antigravity:\(id)", label: label, remaining: fraction * 100,
                    reset: DateParsing.internet(bucket["resetTime"].stringValue), duration: duration))
            }
        }
        return result
    }

    static func identity(_ json: ProviderJSON) -> (ProviderAccount?, String?) {
        let status = json["userStatus"], email = status["email"].stringValue
        return (ProviderAccount.identified(provider: "Antigravity", user: email?.lowercased(), workspace: status["teamId"].stringValue), email)
    }

    static func userStatus(_ json: ProviderJSON) throws -> ProviderQuota {
        let status = json["userStatus"]
        guard let configs = status["cascadeModelConfigData"]["clientModelConfigs"].arrayValue else { throw ProviderFailure.format }
        var pools: [String: ProviderQuota.Window] = [:]
        for config in configs {
            guard let fraction = config["quotaInfo"]["remainingFraction"].numberValue, (0...1).contains(fraction) else { continue }
            let model = config["modelOrAlias"]["model"].stringValue ?? ""
            let label = config["label"].stringValue ?? model, lower = (model + " " + label).lowercased()
            if ["lite", "autocomplete", "image"].contains(where: lower.contains) { continue }
            let family = lower.contains("gemini") ? "gemini" : lower.contains("claude") || lower.contains("gpt") ? "claude-gpt" : model
            guard !family.isEmpty else { continue }
            let name = family == "gemini" ? "Gemini" : family == "claude-gpt" ? "Claude + GPT" : label
            let window = ProviderQuota.Window(id: "antigravity:legacy:\(family)", label: name, remaining: fraction * 100,
                reset: DateParsing.internet(config["quotaInfo"]["resetTime"].stringValue))
            if pools[family].map({ window.remaining < $0.remaining }) ?? true { pools[family] = window }
        }
        let plan = status["userTier"]["name"].stringValue ?? status["planStatus"]["planInfo"]["planName"].stringValue
        return ProviderQuota(windows: pools.keys.sorted().compactMap { pools[$0] }, plan: plan)
    }
}

/// Runs only fixed system inspection tools. Output (including CSRF tokens) stays in memory and is never logged.
enum ProviderCommand {
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: executable), arguments, timeout: 3, stdoutLimit: 2 * 1024 * 1024)
        guard output.status != nil, !output.truncated else { throw ProviderFailure.limit }
        return String(decoding: output.stdout, as: UTF8.self)
    }
}
