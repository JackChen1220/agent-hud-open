import Foundation

/// Joins observed account information to the existing ordered display windows.
public struct AgentSettingsGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: SourceStatus?
    public let agents: [AgentDescriptor]
    public let plans: [String]
    public let apiProviders: [String]
    /// Accounts the client has been signed in to, current first, including plan pools.
    public let accounts: [AccountObservation]
    /// API balance identities remain available here even while their readings are hidden.
    public let billingAccounts: [APIBilling]

    public struct DisplayAccount: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let detail: String?
    }

    /// Existing rows still offer a display switch before their account or balance reading is available.
    /// Each identity appears once, and identities already represented by a summary do not need a fallback.
    public var unobservedAccounts: [DisplayAccount] {
        var represented = Set(accounts.map(\.account.id) + billingAccounts.map(\.id))
        return agents.compactMap { agent in
            guard let id = agent.displayAccountID, represented.insert(id).inserted else { return nil }
            let name = agent.isAPIBilled ? agent.vendorName + " · API"
                : L10n.text("账户 ", "Account ") + String(id.split(separator: ":").last?.prefix(6) ?? "")
            return DisplayAccount(id: id, displayName: name, detail: agent.billingPool?.label)
        }
    }

    public func displayedCount(settings: Settings) -> Int {
        agents.filter { $0.enabled && settings.accountVisible($0.displayAccountID) }.count
    }
    public var hasLiveStatus: Bool { SessionSource.agentVendors.contains(id) }

    /// One group per vendor with something to set: rows present, as `ReportView.isPresent(_:in:)` decides, a service, or
    /// a client found on this Mac. A client that is neither installed nor reporting has no group.
    public static func make(sources: [SourceStatus], agents: [AgentDescriptor], report: UsageReport? = nil) -> [Self] {
        let agents = agents.filter { ReportView.isPresent($0, in: report) }
        let existing = agents.agentGroups
        var ids = existing.map(\.id)
        let found = sources.filter { $0.state != .notDetected }.map(\.name)
        for id in found + agents.map(\.vendor) + (report?.services ?? []).map(\.client)
            where !ids.contains(id) { ids.append(id) }
        return ids.map { id in
            let source = sources.first { $0.name == id }
            let windows = existing.first { $0.id == id }?.agents ?? []
            let services = (report?.services ?? []).filter { $0.client == id }
            // Observations retain client-home history; display one summary per account, as quota rows do.
            let accountIDs = Set((report?.accounts?[id] ?? []).map(\.account.id))
            let accounts = accountIDs.compactMap { report?.observation(accountID: $0) }
                .sorted { ($0.isCurrent ? 1 : 0, $0.observedAt) > ($1.isCurrent ? 1 : 0, $1.observedAt) }
            var plans = accounts.isEmpty ? source?.planLabel.map { [$0] } ?? [] : []
            for service in services where service.product == .plan {
                guard !accounts.contains(where: { $0.account.id == service.accountID }) else { continue }
                guard let plan = report?.subscriptions[service.accountID ?? service.provider], !plan.isEmpty else { continue }
                plans.append(service.provider == id ? plan.capitalized : service.provider + " · " + plan.capitalized)
            }
            for window in windows {
                guard let pool = window.billingPool, pool.product == .plan,
                      !accounts.contains(where: { $0.account.id == pool.id }),
                      let plan = report?.subscriptions[pool.id], !plan.isEmpty else { continue }
                plans.append(plan.capitalized)
            }
            var api = services.filter { $0.product == .api }.map(\.provider)
            api += agents.filter { $0.vendor == id && $0.billingPool?.product == .api }.compactMap { $0.billingPool?.provider }
            api += windows.compactMap { $0.billingPool?.product == .api ? $0.billingPool?.provider : nil }
            api += (report?.billing ?? []).filter {
                ($0.billingPool?.provider ?? $0.vendor) == id && (!$0.balances.isEmpty || !$0.costs.isEmpty)
            }.map { $0.billingPool?.provider ?? $0.vendor }
            return Self(id: id, source: source, agents: windows, plans: Array(Set(plans)).sorted(),
                        apiProviders: Array(Set(api)).sorted(), accounts: accounts,
                        billingAccounts: (report?.billing ?? []).filter { ($0.billingPool?.provider ?? $0.vendor) == id })
        }
    }

    /// Rows name their account once a client has been signed in to more than one.
    public func accountName(for agent: AgentDescriptor) -> String? {
        guard accounts.count > 1, let id = agent.account?.id else { return nil }
        return accounts.first { $0.account.id == id }?.displayName
    }
}
