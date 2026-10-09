import Foundation

// Protocol reference: CodexBar GrokCreditsProxyFetcher/GrokAuth (MIT), pinned in THIRD_PARTY_NOTICES.txt.
struct GrokClient: Sendable {
    var home = GrokSessions.directory(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
    var http = ProviderHTTP()
    var botDirectory = GrokBotSessions.roots(home: FileManager.default.homeDirectoryForCurrentUser, environment: [:])[0]
    var clock: @Sendable () -> Date = { Date() }
    var readBot: (@Sendable () async throws -> ProviderQuota?)? = nil
    /// User-confirmed links between the Bot cache slot and the CLI account. Stored ids contain no credentials.
    var accountLinksURL = AppSupport.directory.appendingPathComponent("grok-account-links.json")

    func fetch() async throws -> ProviderQuota {
        let cached: ProviderQuota?
        let cacheError: (any Error)?
        do { cached = try await fetchBot(); cacheError = nil }
        catch { try Self.propagateCancellation(error); cached = nil; cacheError = error }
        // A native client's reading is already observed. Polling the CLI proxy must not overwrite it with a
        // different backend's older allowance merely by attaching the HTTP request's completion time.
        if let cached, let linked = linkedBot(cached) { return linked }
        let cli: ProviderQuota
        do {
            cli = try await fetchCLI()
        } catch {
            try Self.propagateCancellation(error)
            guard let bot = cached, bot.isSignedIn else { throw error }
            return bot
        }
        if !cli.isSignedIn, let cacheError { throw cacheError }
        guard let bot = cached, bot.isSignedIn else { return cli }
        guard cli.isSignedIn else { return bot }
        return cli
    }

    private func fetchBot() async throws -> ProviderQuota? {
        if let readBot { return try await readBot() }
        return try GrokBotQuota.fetch(in: botDirectory, now: clock())
    }

    private func linkedBot(_ cached: ProviderQuota) -> ProviderQuota? {
        guard let botAccount = cached.account,
              let json = try? ProviderFiles.json(home.appendingPathComponent("auth.json")),
              let (entry, account) = Self.linkedIdentity(json),
              let links = try? ProviderFiles.json(accountLinksURL), links[botAccount.id].stringValue == account.id else { return nil }
        var quota = cached
        quota.account = account
        quota.label = entry["email"].stringValue
        quota.accountAliases = [botAccount.id]
        return quota
    }

    private func fetchCLI() async throws -> ProviderQuota {
        guard FileManager.default.fileExists(atPath: home.path) else { return ProviderQuota(signedOut: true) }
        let url = home.appendingPathComponent("auth.json")
        guard let json = try? ProviderFiles.json(url) else { throw ProviderFailure.login("Grok CLI") }
        let entry = try Self.credential(json, now: clock())
        guard let token = entry["key"].stringValue else { throw ProviderFailure.login("Grok CLI") }
        let headers = ["Authorization": "Bearer \(token)", "x-xai-token-auth": "xai-grok-cli"]
        let response = try await http.json(URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, headers: headers)
        var quota = try Self.parse(response)
        quota.observedAt = clock()
        quota.client = "Grok CLI"
        quota.account = Self.account(entry)
        if let id = quota.account?.id, let links = try? ProviderFiles.json(accountLinksURL) {
            let aliases = links.objectValue?.filter { $0.value.stringValue == id }.map(\.key) ?? []
            quota.accountAliases = aliases.isEmpty ? nil : aliases
        }
        quota.label = entry["email"].stringValue
        do {
            let settings = try await http.json(URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!, headers: headers, timeout: 2)
            quota.plan = settings["subscription_tier_display"].stringValue ?? quota.plan
        } catch {
            try Self.propagateCancellation(error)
        }
        return quota
    }

    private static func propagateCancellation(_ error: any Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
    }

    static func credential(_ json: ProviderJSON, now: Date) throws -> ProviderJSON {
        let valid = loginEntries(json).filter { entry in
            entry["key"].stringValue?.isEmpty == false
                && DateParsing.internet(entry["expires_at"].stringValue).map { $0 > now } == true
        }
        guard let selected = valid.first else { throw ProviderFailure.login("Grok CLI") }
        if selected["principal_type"].stringValue?.lowercased() == "team" {
            throw UsageProviderError(L10n.text("Grok 团队账户尚未提供可读取的额度", "Grok team quota is not available through this interface"))
        }
        return selected
    }

    private static func loginEntries(_ json: ProviderJSON) -> [ProviderJSON] {
        (json.objectValue ?? [:]).filter { key, _ in
            key.hasPrefix("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in"
        }.sorted { lhs, rhs in
            let a = lhs.key.hasPrefix("https://auth.x.ai::"), b = rhs.key.hasPrefix("https://auth.x.ai::")
            return a != b ? a : lhs.key < rhs.key
        }.map(\.value)
    }

    /// A confirmed identity outlives its CLI token; ambiguous or team login records cannot confirm a personal link.
    private static func linkedIdentity(_ json: ProviderJSON) -> (ProviderJSON, ProviderAccount)? {
        let entries = loginEntries(json)
        guard let first = entries.first, let account = Self.account(first) else { return nil }
        for entry in entries {
            let principal = entry["principal_type"].stringValue?.lowercased()
            // Personal User logins can carry a team_id; principal_type names whose quota it is.
            guard principal != "team",
                  principal == "user" || ["team_id", "organization_id"].allSatisfy({
                      entry[$0].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                  }), Self.account(entry) == account else { return nil }
        }
        return (first, account)
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
