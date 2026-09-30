import Foundation

// Protocol reference: CodexBar GrokCreditsProxyFetcher/GrokAuth (MIT), pinned in THIRD_PARTY_NOTICES.txt.
struct GrokClient: Sendable {
    var home = GrokSessions.directory(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
    var http = ProviderHTTP()

    func fetch() async throws -> ProviderQuota {
        guard FileManager.default.fileExists(atPath: home.path) else { return ProviderQuota() }
        let url = home.appendingPathComponent("auth.json")
        guard let json = try? ProviderFiles.json(url) else { throw ProviderFailure.login("Grok CLI") }
        let entry = try Self.credential(json, now: Date())
        guard let token = entry["key"].stringValue else { throw ProviderFailure.login("Grok CLI") }
        let headers = ["Authorization": "Bearer \(token)", "x-xai-token-auth": "xai-grok-cli"]
        let response = try await http.json(URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, headers: headers)
        var quota = try Self.parse(response)
        quota.account = Self.account(entry)
        quota.label = entry["email"].stringValue
        if let settings = try? await http.json(URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!, headers: headers, timeout: 2) {
            quota.plan = settings["subscription_tier_display"].stringValue ?? quota.plan
        }
        return quota
    }

    static func credential(_ json: ProviderJSON, now: Date) throws -> ProviderJSON {
        guard let entries = json.objectValue else { throw ProviderFailure.login("Grok CLI") }
        let valid = entries.filter { key, value in
            (key.hasPrefix("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in")
                && value["key"].stringValue?.isEmpty == false
                && DateParsing.internet(value["expires_at"].stringValue).map { $0 > now } == true
        }.sorted { lhs, rhs in
            let a = lhs.key.hasPrefix("https://auth.x.ai::"), b = rhs.key.hasPrefix("https://auth.x.ai::")
            return a != b ? a : lhs.key < rhs.key
        }
        guard let selected = valid.first?.value else { throw ProviderFailure.login("Grok CLI") }
        if selected["principal_type"].stringValue?.lowercased() == "team" {
            throw UsageProviderError(L10n.text("Grok 团队账户尚未提供可读取的额度", "Grok team quota is not available through this interface"))
        }
        return selected
    }

    /// The login record names the user and team; the billing service does not confirm them.
    static func account(_ entry: ProviderJSON) -> ProviderAccount? {
        ProviderAccount.identified(provider: "Grok", user: entry["user_id"].stringValue ?? entry["principal_id"].stringValue,
                                   workspace: entry["team_id"].stringValue ?? entry["organization_id"].stringValue, evidence: .credential)
    }

    static func parse(_ response: ProviderJSON) throws -> ProviderQuota {
        let config = response["config"]
        guard config.objectValue != nil else { throw ProviderFailure.format }
        let period = config["currentPeriod"]
        let start = DateParsing.internet(period["start"].stringValue)
        let end = DateParsing.internet(period["end"].stringValue) ?? DateParsing.internet(config["billingPeriodEnd"].stringValue)
        let duration = ProviderDate.period(start: start, end: end)
        var quota = ProviderQuota()
        if let used = config["creditUsagePercent"].numberValue, used >= 0 {
            // xAI's weekly usage limit, which its billing service can also report by the month.
            let label: String, short: String
            switch period["type"].stringValue {
            case "USAGE_PERIOD_TYPE_WEEKLY": (label, short) = (L10n.text("每周用量额度", "Weekly usage limit"), WindowNames.Period.week.shortName)
            case "USAGE_PERIOD_TYPE_MONTHLY": (label, short) = (L10n.text("每月用量额度", "Monthly usage limit"), WindowNames.Period.month.shortName)
            default: (label, short) = (L10n.text("用量额度", "Usage limit"), L10n.text("用量", "Usage"))
            }
            quota.windows.append(.init(id: "grok", label: label, remaining: QuotaMath.remaining(usedPercent: used), reset: end, duration: duration,
                                       shortLabel: short))
        } else {
            quota.displayNotice = L10n.text("Grok 已连接，但服务未返回已用额度", "Grok is connected, but used credits were not reported")
        }
        // Extra spending is a distinct budget, never a substitute for subscription consumption.
        if let cap = config["onDemandCap"]["val"].numberValue, cap > 0,
           let used = config["onDemandUsed"]["val"].numberValue, used >= 0 {
            quota.windows.append(.init(id: "grok:extra", label: L10n.text("额外用量", "Extra usage"),
                remaining: QuotaMath.remaining(usedPercent: used / cap * 100), reset: end, duration: duration,
                shortLabel: L10n.text("额外用量", "Extra")))
        }
        return quota
    }
}
