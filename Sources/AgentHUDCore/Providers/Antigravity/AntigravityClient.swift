import Foundation

// Local service discovery and quota schema follow CodexBar (MIT). Only already-running services are queried.
struct AntigravityClient: Sendable {
    var http = ProviderHTTP()
    private static let statusRequest: ProviderJSON = .object(["metadata": .object([
        "ideName": .string("antigravity"), "extensionName": .string("antigravity"), "locale": .string("en"), "ideVersion": .string("unknown")
    ])])

    func fetch() async throws -> ProviderQuota {
        let candidates = try await AntigravityService.running()
        guard !candidates.isEmpty else {
            return ProviderQuota(notice: AdditionalSource.antigravity.isInstalled()
                ? L10n.text("启动并登录 Antigravity 或 agy 后读取额度", "Start and sign in to Antigravity or agy to load quota") : nil)
        }
        let deadline = Date().addingTimeInterval(20)
        var fallback: ProviderQuota?
        for candidate in candidates.prefix(6) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let endpoints = (try? await AntigravityService.endpoints(for: candidate)) ?? []
            for endpoint in endpoints {
                try Task.checkCancellation()
                guard Date() < deadline else { break }
                if let result = try? await quota(from: endpoint) { return result }
                if let json = try? await endpoint.json("GetUserStatus", body: Self.statusRequest, http: http),
                   var result = try? Self.userStatus(json), !result.windows.isEmpty {
                    (result.account, result.label) = Self.identity(json)
                    fallback = fallback ?? result; break
                }
            }
        }
        if let fallback { return fallback }
        throw UsageProviderError(L10n.text("Antigravity 本地服务未返回可读取的额度", "Antigravity's local service returned no readable quota"))
    }

    func quota(from endpoint: AntigravityService.Endpoint) async throws -> ProviderQuota {
        // Opening Antigravity's native quota popover forces a new summary rather than its local service's cached one.
        let json = try await endpoint.json("RetrieveUserQuotaSummary", body: .object(["forceRefresh": .bool(true)]), http: http)
        var result = try Self.summary(json)
        guard !result.windows.isEmpty else { throw ProviderFailure.format }
        // The IDE and agy can be signed in to different accounts, so identity comes from the same server. Its legacy
        // per-model quotas may be older than the fresh summary and supply no readings while the summary is available.
        if let status = try? await endpoint.json("GetUserStatus", body: Self.statusRequest, http: http) {
            (result.account, result.label) = Self.identity(status)
        }
        return result
    }

    static func candidates(_ output: String) -> [AntigravityService.Candidate] { AntigravityService.candidates(output) }
    static func ports(_ output: String) -> [Int] { AntigravityService.ports(output) }

    static func summary(_ json: ProviderJSON) throws -> ProviderQuota {
        let groups = json["response"]["groups"].arrayValue ?? json["summary"]["groups"].arrayValue ?? json["groups"].arrayValue
        guard let groups else { throw ProviderFailure.format }
        var result = ProviderQuota(), ids = Set<String>()
        var found: [(group: Int, name: String?, window: ProviderQuota.Window)] = []
        for (index, group) in groups.enumerated() {
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
                found.append((index, group["displayName"].stringValue, .init(id: "antigravity:\(id)", label: label, remaining: fraction * 100,
                    reset: DateParsing.internet(bucket["resetTime"].stringValue), duration: duration)))
            }
        }
        // One group's windows are the account's main set, known by their period alone and plan-wide; with several groups
        // a window limits its group's models and is known by its group's word, and by its period too where the group has
        // more than one window.
        let counts = Dictionary(grouping: found, by: \.group).mapValues(\.count)
        result.windows = found.map { entry in
            var window = entry.window
            window.allModels = counts.count == 1
            let period = WindowNames.Period(seconds: window.duration)
            if counts.count == 1 {
                window.shortLabel = period?.shortName
            } else if let word = entry.name.map(groupWord) {
                window.shortLabel = counts[entry.group] == 1 ? word : period.map { "\(word) \($0.afterWord)" }
            }
            return window
        }
        return result
    }

    /// The word a group of models is known by in tight places: its first word, as Gemini for Gemini Models, and
    /// third-party for Claude and GPT models, as Antigravity's plans describe them.
    static func groupWord(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("claude") || lower.contains("gpt") { return L10n.text("第三方", "3rd-party") }
        return name.split(separator: " ").first.map(String.init) ?? name
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
            // The groups by Antigravity's own names; any other model by its label.
            let name = family == "gemini" ? "Gemini Models" : family == "claude-gpt" ? "Claude and GPT models" : label
            let short = family == "gemini" ? "Gemini" : family == "claude-gpt" ? groupWord(name) : WindowNames.word(label)
            let window = ProviderQuota.Window(id: "antigravity:legacy:\(family)", label: name, remaining: fraction * 100,
                reset: DateParsing.internet(config["quotaInfo"]["resetTime"].stringValue), shortLabel: short)
            if pools[family].map({ window.remaining < $0.remaining }) ?? true { pools[family] = window }
        }
        let plan = status["userTier"]["name"].stringValue ?? status["planStatus"]["planInfo"]["planName"].stringValue
        // Several families' quotas each limit their own models, as several groups' windows do.
        let windows = pools.keys.sorted().compactMap { pools[$0] }.map { pool in
            var window = pool
            window.allModels = pools.count == 1
            return window
        }
        return ProviderQuota(windows: windows, plan: plan)
    }
}

/// Runs only fixed system inspection tools. Output (including CSRF tokens) stays in memory and is never logged.
enum ProviderCommand {
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: executable), arguments, timeout: 3, stdoutLimit: 2 * 1024 * 1024)
        guard output.status != nil, !output.truncated else { throw ProviderFailure.limit }
        guard output.status == 0 else { throw ProviderFailure.format }
        return String(decoding: output.stdout, as: UTF8.self)
    }
}
