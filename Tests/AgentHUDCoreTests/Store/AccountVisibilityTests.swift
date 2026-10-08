import XCTest
@testable import AgentHUDCore

@MainActor
final class AccountVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let work = ProviderAccount.identified(provider: "Codex", user: "work@example.com", workspace: "team")!
    private let personal = ProviderAccount.identified(provider: "Codex", user: "me@example.com", workspace: "personal")!

    func testDefaultsAndPersistenceKeepWindowPreferencesIndependent() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.hiddenAccountIDs.isEmpty)
        XCTAssertTrue(old.accountVisible(work.id))
        XCTAssertTrue(old.accountVisible(nil), "Unattributed rows keep their own window selection")

        let defaults = try makeDefaults()
        let settings = SettingsStore(defaults: defaults, defaultAgents: quotaAgents)
        settings.moveAgent(id: personal.windowID("codex"), to: 0)
        let orderedWindows = settings.agents
        let savedWindows = defaults.data(forKey: SettingsStore.Keys.agents)
        var changes: [String] = []
        settings.onChange = { change in
            switch change {
            case .settings: changes.append("settings")
            case .agents: changes.append("agents")
            case .discovery: changes.append("discovery")
            }
        }

        settings.setAccount(id: work.id, visible: false)
        XCTAssertEqual(changes, ["settings"], "Account visibility is not an agent inventory change")
        XCTAssertEqual(settings.agents, orderedWindows)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.Keys.agents), savedWindows)
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.settings.accountVisible(work.id))
        XCTAssertTrue(reloaded.settings.accountVisible(personal.id))
        XCTAssertEqual(reloaded.agents, orderedWindows)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(reloaded.settings)), reloaded.settings)

        reloaded.setAccount(id: work.id, visible: true)
        XCTAssertTrue(reloaded.settings.hiddenAccountIDs.isEmpty)
        XCTAssertEqual(reloaded.agents, orderedWindows, "Showing an account restores each window's switch and order")
    }

    func testQuotaVisibilityFiltersPresentationAndKeepsAllTokenAndSessionStatistics() throws {
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: quotaAgents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        let report = quotaReport()
        store.replace(report: report)
        store.now = now
        let originalRows = store.rows
        let originalColumns = store.tokenColumns
        let originalUsage = store.agentUsage
        let originalCost = store.statsListCost
        let originalCards = store.shownAgents
        let originalSessions = store.sessions
        let originalLiveSessions = store.liveSessions
        let originalWindows = settings.agents
        XCTAssertEqual(originalRows.map(\.id), [work.windowID("codex"), personal.windowID("codex")])
        XCTAssertEqual(store.levels.count, 2)
        XCTAssertEqual(originalColumns.map(\.total).reduce(0, +), 1650)
        XCTAssertEqual(originalSessions.count, 2, "Local use with no account is included")
        XCTAssertNotNil(originalCost)

        settings.setAccount(id: work.id, visible: false)
        XCTAssertEqual(store.rows.map(\.id), [personal.windowID("codex")])
        XCTAssertEqual(store.rows.first?.paletteIndex, originalRows.last?.paletteIndex)
        XCTAssertEqual(store.levels.count, 1)
        XCTAssertEqual(store.visibleAgents, originalWindows)
        XCTAssertEqual(store.enabledAgents, originalWindows.filter(\.enabled))
        XCTAssertEqual(store.report, report)
        XCTAssertEqual(store.tokenColumns, originalColumns)
        XCTAssertEqual(store.agentUsage, originalUsage)
        XCTAssertEqual(store.statsListCost, originalCost)
        XCTAssertEqual(store.shownAgents, originalCards)
        XCTAssertEqual(store.sessions, originalSessions)
        XCTAssertEqual(store.liveSessions, originalLiveSessions)
        let group = try XCTUnwrap(AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report).first)
        XCTAssertEqual(Set(group.accounts.map(\.account.id)), [work.id, personal.id])
        XCTAssertTrue(group.unobservedAccounts.isEmpty, "Account summaries already own these switches")
        XCTAssertEqual(group.displayedCount(settings: settings.settings), 1)

        settings.setAccount(id: personal.id, visible: false)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.levels.isEmpty)
        XCTAssertTrue(store.alertPulseVendors.isEmpty)
        XCTAssertEqual(group.displayedCount(settings: settings.settings), 0)
        XCTAssertEqual(group.accounts.count, 2, "All hidden accounts remain available to restore in Settings")
        XCTAssertEqual(store.tokenColumns, originalColumns)
        XCTAssertEqual(store.sessions, originalSessions)
        settings.setAccount(id: work.id, visible: true)
        settings.setAccount(id: personal.id, visible: true)
        XCTAssertEqual(settings.agents, originalWindows)
        XCTAssertEqual(store.rows, originalRows)
    }

    func testAPIBalancesUseTheirOwnPoolIdentityAndKeepRestorationEntries() throws {
        let shared = pool("shared"), other = pool("other")
        let agents = [
            AgentDescriptor(id: "open-shared", vendor: "OpenCode", model: "Model A", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "open-other", vendor: "OpenCode", model: "Model B", source: "", enabled: true, billingPool: other),
            AgentDescriptor(id: "deepseek-model:chat", vendor: "DeepSeek", model: "Chat", source: "", enabled: true),
        ]
        let billing = [balance(pool: shared), balance(pool: other), balance(vendor: "DeepSeek")]
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents, billing: billing)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: agents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        store.replace(report: report)
        store.now = now
        XCTAssertEqual(store.enabledBilling, billing)
        XCTAssertEqual(store.levels.count, 3)

        settings.setAccount(id: shared.id, visible: false)
        XCTAssertEqual(store.enabledBilling.map(\.id), [other.id, "DeepSeek"])
        XCTAssertEqual(store.levels.count, 2)
        XCTAssertEqual(store.report?.billing, billing, "Hiding a balance does not alter its readings or costs")
        XCTAssertEqual(settings.agents, agents)
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(groups.first { $0.id == "Anthropic" }?.billingAccounts.map(\.id), [shared.id, other.id])
        XCTAssertTrue(groups.flatMap(\.unobservedAccounts).isEmpty, "Billing summaries already own these switches")
        settings.setAccount(id: other.id, visible: false)
        settings.setAccount(id: "DeepSeek", visible: false)
        XCTAssertTrue(store.enabledBilling.isEmpty)
        XCTAssertTrue(store.levels.isEmpty)
        XCTAssertEqual(groups.first { $0.id == "DeepSeek" }?.billingAccounts.map(\.id), ["DeepSeek"])
        settings.setAccount(id: shared.id, visible: true)
        settings.setAccount(id: other.id, visible: true)
        settings.setAccount(id: "DeepSeek", visible: true)
        XCTAssertEqual(store.enabledBilling, billing)
        XCTAssertEqual(settings.agents, agents)
    }

    func testQuotaRowsWithoutAccountObservationsKeepOneRestorableControlPerIdentity() throws {
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: quotaAgents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        let report = quotaReport(includeAccountObservations: false)
        store.replace(report: report)
        store.now = now
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(groups.map(\.id), ["Codex"])
        let group = try XCTUnwrap(groups.first)
        XCTAssertTrue(group.accounts.isEmpty)
        XCTAssertEqual(group.unobservedAccounts.map(\.id), [work.id, personal.id], "Two windows of one account share one switch")
        XCTAssertEqual(Set(group.unobservedAccounts.map(\.displayName)).count, 2, "Distinct accounts retain their six-character identity labels")
        XCTAssertTrue(group.unobservedAccounts.allSatisfy { $0.displayName.hasSuffix(String($0.id.split(separator: ":").last!.prefix(6))) })

        for account in group.unobservedAccounts { settings.setAccount(id: account.id, visible: false) }
        XCTAssertTrue(store.rows.isEmpty)
        let hiddenGroups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(hiddenGroups, groups, "Hiding changes neither the groups nor their restore controls")
        for account in hiddenGroups.flatMap(\.unobservedAccounts) { settings.setAccount(id: account.id, visible: true) }
        XCTAssertEqual(store.rows.map(\.id), [work.windowID("codex"), personal.windowID("codex")])
        XCTAssertEqual(settings.agents, quotaAgents, "The disabled weekly window remains disabled")
        XCTAssertEqual(store.report, report)
    }

    func testAPIRowsWithoutBillingReadingsKeepTheirPoolAndLegacyRestoreControls() throws {
        let shared = pool("shared"), other = pool("other")
        let agents = [
            AgentDescriptor(id: "shared-a", vendor: "OpenCode", model: "Model A", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "shared-b", vendor: "OpenCode", model: "Model B", source: "", enabled: false, billingPool: shared),
            AgentDescriptor(id: "other", vendor: "OpenCode", model: "Model C", source: "", enabled: true, billingPool: other),
            AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true),
        ]
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: agents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        store.replace(report: report)
        store.now = now
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        let controls = groups.flatMap(\.unobservedAccounts)
        XCTAssertEqual(controls.map(\.id), [shared.id, other.id, "DeepSeek"])
        XCTAssertEqual(controls.first { $0.id == shared.id }?.detail, shared.label)
        XCTAssertEqual(controls.first { $0.id == other.id }?.detail, other.label)
        XCTAssertEqual(controls.first { $0.id == "DeepSeek" }?.displayName, "DeepSeek · API")
        XCTAssertTrue(groups.flatMap(\.billingAccounts).isEmpty)

        for account in controls { settings.setAccount(id: account.id, visible: false) }
        let hiddenGroups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(hiddenGroups, groups)
        for account in hiddenGroups.flatMap(\.unobservedAccounts) { settings.setAccount(id: account.id, visible: true) }
        XCTAssertTrue(settings.settings.hiddenAccountIDs.isEmpty)
        XCTAssertEqual(settings.agents, agents)
        XCTAssertTrue(store.enabledBilling.isEmpty, "A restore switch does not invent a missing balance reading")
        let billing = [balance(pool: shared), balance(pool: other), balance(vendor: "DeepSeek")]
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents, billing: billing))
        store.now = now
        XCTAssertEqual(store.enabledBilling, billing, "The next available readings follow the restored preference")
    }

    func testAccountControlsFollowExistingGroupsAndReadingsAloneDoNotCreateGroups() {
        let plan = BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "plan", evidence: .account, entitlement: "coding-plan")
        let account = AccountObservation(account: ProviderAccount(pool: plan), plan: "Allegretto", observedAt: now)
        let absent = AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true)
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [],
                                 subscriptions: [plan.id: "Allegretto"], billing: [balance(vendor: "DeepSeek")],
                                 services: [.init(client: "Kimi", provider: "Kimi", product: .plan, accountID: plan.id)],
                                 accounts: ["Kimi": [account], "Codex": [.init(account: work, observedAt: now)]], rowSeenAt: [:])
        let groups = AgentSettingsGroup.make(sources: [], agents: [absent], report: report)
        XCTAssertEqual(groups.map(\.id), ["Kimi"], "A balance or account observation does not replace the source/row presence rule")
        XCTAssertEqual(groups.first { $0.id == "Kimi" }?.accounts, [account])
        XCTAssertEqual(groups.first { $0.id == "Kimi" }?.plans, [], "The plan is already in its account summary")
        XCTAssertNil(groups.first { $0.id == "Codex" })
        XCTAssertNil(groups.first { $0.id == "DeepSeek" })
    }

    func testConfirmedAliasesMoveVisibilityPreferenceOnceAndAllowShowingTheAccount() throws {
        let unresolved = ProviderAccount.unresolved(provider: "Codex", home: "test-home")
        let settings = SettingsStore(defaults: try makeDefaults())
        settings.setAccount(id: unresolved.id, visible: false)
        let observation = AccountObservation(account: work, observedAt: now, aliases: [unresolved.id])
        settings.mergeDiscovered([], accounts: ["Codex": [observation]])
        XCTAssertEqual(settings.settings.hiddenAccountIDs, [work.id])
        settings.setAccount(id: work.id, visible: true)
        settings.mergeDiscovered([], accounts: ["Codex": [observation]])
        XCTAssertTrue(settings.settings.hiddenAccountIDs.isEmpty, "A later reading cannot undo the user's Show action")
    }

    private var quotaAgents: [AgentDescriptor] {
        [AgentDescriptor(id: work.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: work),
         AgentDescriptor(id: work.windowID("codex-weekly"), vendor: "Codex", model: "Weekly", source: "", enabled: false, account: work),
         AgentDescriptor(id: personal.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: personal)]
    }

    private func quotaReport(includeAccountObservations: Bool = true) -> UsageReport {
        let consumers = [AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: true),
                         AgentDescriptor(id: "unknown-model:custom", vendor: "Local Agent", model: "Custom", source: "", enabled: true)]
        let sessions = consumers.map {
            LiveSession(id: $0.id + ":session", agentId: $0.id, task: "Local work", terminal: nil,
                        startedAt: now.addingTimeInterval(-600), pctOfWindow: nil, tokensIn: 100, tokensOut: 20, observedAt: now)
        }
        return UsageReport(generatedAt: now, snapshots: quotaAgents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 25, resetAt: now.addingTimeInterval(3600), windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: sessions, discoveredAgents: quotaAgents, consumers: consumers,
        usage: [UsageBucket(start: now.addingTimeInterval(-900), agentId: consumers[0].id, tokensIn: 1000, tokensOut: 200, cacheReadTokens: 50),
                UsageBucket(start: now.addingTimeInterval(-900), agentId: consumers[1].id, tokensIn: 400, tokensOut: 50)],
        accounts: includeAccountObservations ? ["Codex": [.init(account: work, observedAt: now), .init(account: personal, observedAt: now)]] : nil)
    }

    private func pool(_ scope: String) -> BillingPool {
        BillingPool(provider: "Anthropic", realm: "Global", product: .api, scope: scope, evidence: .account, entitlement: "api")
    }

    private func balance(vendor: String = "Anthropic", pool: BillingPool? = nil) -> APIBilling {
        APIBilling(vendor: vendor, balances: [.init(currency: "USD", total: 10, granted: 0, toppedUp: 10)],
                   isAvailable: true, updatedAt: now, notice: nil, billingPool: pool)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "AccountVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private struct NoReadProvider: UsageProvider {
        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            throw UsageProviderError("Account visibility tests install their reports directly")
        }
    }
}
