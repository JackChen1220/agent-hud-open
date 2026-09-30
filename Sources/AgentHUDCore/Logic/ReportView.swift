import AgentHUDSupport
import Foundation

/// What the Mac shows of a report at one time: the quota rows it lists and how they group, the balances, the glow's
/// levels, and each session with its source, newest turn, last event, message and phase. Rows, balances, levels and
/// sessions are worked out when the view is built, a window's metrics only when asked for. A session's phase comes from
/// the report alone: neither a client's hook turns nor a permission request waiting for an answer changes it.
public struct ReportView: Sendable {
    /// One session as the Mac shows it.
    public struct Session: Hashable, Sendable, Identifiable {
        public let session: LiveSession
        /// The session's vendor, from the consumer its model is, a settings row, a report row or its id, and its client.
        public let source: SessionSource
        /// The newest turn: the last one listed from the session's vendor, or from any provider without a vendor.
        public let turn: SessionTurn?
        /// When the session last did something: its newest turn event from any provider, or its end when that is later;
        /// without turns, its end, or while in flight the reading that last saw it.
        public let lastEventAt: Date
        /// What the agent last said: the message of the last turn listed that carries one, from the providers `turn`
        /// comes from.
        public let message: String?
        /// Whether live status is on for the session's vendor; a session without a vendor answers to no vendor's switch.
        public let liveStatus: Bool
        public let phase: SessionPhase

        public var id: String { session.id }
    }

    public let now: Date
    /// Rows a provider reported within the retention period, in the settings' order. Settings keep the switch and place
    /// of a row that stopped being reported, so it comes back as it was; until then it is not shown anywhere.
    public let visibleAgents: [AgentDescriptor]
    /// The visible rows switched on, but for plan pools the report does not list as active.
    public let enabledAgents: [AgentDescriptor]
    /// A quota row for each enabled row that is not billed through an API account.
    public let rows: [AgentRow]
    /// Rows grouped by displayed vendor, in row order.
    public let rowGroups: [(vendor: String, rows: [AgentRow])]
    /// Account cards follow the agent switches: a billing pool's card its pool's rows, any other its vendor's.
    public let billing: [APIBilling]
    /// Status per enabled row that has one, in glow order, each balance once. Rows without a reading stay out of the glow.
    public let levels: [StatusLevel]
    /// Newest first, by the last event each source reported: a prompt, a reply, a tool result or an approval request. A
    /// running session nothing has been heard from for half an hour sits below one that just answered.
    public let sessions: [Session]

    private let report: UsageReport?
    private let settings: Settings
    private let index: Index

    /// - agents: the settings' rows, in their order.
    public init(report: UsageReport?, agents: [AgentDescriptor], settings: Settings, now: Date) {
        let visible = report?.visibleRows(agents) ?? agents
        let enabled = visible.filter { agent in
            guard agent.enabled else { return false }
            guard let pool = agent.billingPool, pool.product == .plan else { return true }
            guard let report else { return false }
            return report.activeQuotaPoolIDs?[pool.provider]?.contains(pool.id) ?? true
        }
        let rows = enabled.filter { !$0.isAPIBilled }.enumerated().map { index, agent in
            let snapshot = report?.snapshot(for: agent.id)
            let isCurrent = report?.isCurrent(agent) ?? true
            return AgentRow(
                agent: agent,
                remainingPct: snapshot?.remainingPct,
                level: isCurrent && report?.quotaNotice(for: agent) == nil ? snapshot.flatMap {
                    ($0.resetAt ?? .distantFuture) > now && now.timeIntervalSince($0.updatedAt) < AlertPolicy.maximumReadingAge
                        ? AlertPolicy.quotaLevel(remaining: $0.remainingPct) : nil
                } : nil,
                resetAt: snapshot?.resetAt,
                weeklyRemainingPct: snapshot?.weeklyRemainingPct,
                paletteIndex: index,
                account: agent.account.flatMap { report?.observation(accountID: $0.id) },
                isCurrentAccount: isCurrent
            )
        }
        let vendors = Set(enabled.map(\.vendor))
        let billing = (report?.billing ?? []).filter { billing in
            billing.billingPool.map { pool in enabled.contains { $0.billingPool?.id == pool.id } } ?? vendors.contains(billing.vendor)
        }
        let quota = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.level.map { (row.id, $0) } })
        var seenAccounts: Set<String> = []
        let levels = enabled.flatMap { model -> [StatusLevel] in
            if !model.isAPIBilled { return quota[model.id].map { [$0] } ?? [] }
            return billing.filter { $0.contains(model) && seenAccounts.insert($0.id).inserted }.compactMap {
                AlertPolicy.balanceLevel($0.balances, isAvailable: $0.isAvailable)
            }
        }
        var order: [String] = []
        var groups: [String: [AgentRow]] = [:]
        for row in rows {
            let vendor = row.agent.displayVendor
            if groups[vendor] == nil { order.append(vendor) }
            groups[vendor, default: []].append(row)
        }
        let index = Index(report: report, agents: agents)
        self.report = report
        self.settings = settings
        self.index = index
        self.now = now
        visibleAgents = visible
        enabledAgents = enabled
        self.rows = rows
        rowGroups = order.map { ($0, groups[$0] ?? []) }
        self.billing = billing
        self.levels = levels
        sessions = (report?.sessions ?? []).map { Self.read($0, index: index, settings: settings, now: now) }.sorted {
            $0.lastEventAt == $1.lastEventAt ? $0.id < $1.id : $0.lastEventAt > $1.lastEventAt
        }
    }

    // MARK: Quota

    /// The vendor of each quota row that shows a status level, in row order. An alert's pulse lights the part of the glow
    /// its vendor's entries take in this list.
    public var alertPulseVendors: [String] { rows.filter { $0.level != nil }.map { $0.agent.vendor } }

    /// The most consumed window of a signed-in account, shown in the menu bar.
    public var maxUsedPct: Double? { rows.filter(\.isCurrentAccount).compactMap(\.usedPct).max() }

    /// Plans of the vendors that have an enabled row.
    public var subscriptions: [String: String] {
        let vendors = Set(enabledAgents.map(\.vendor))
        return (report?.subscriptions ?? [:]).filter { vendors.contains($0.key) }
    }

    /// A vendor group's rows split by account, in row order. One section without an account when nothing is identified.
    public func accountSections(_ rows: [AgentRow]) -> [AccountSection] {
        var order: [String] = []
        var sections: [String: [AgentRow]] = [:]
        for row in rows {
            let key = row.agent.account?.id ?? ""
            if sections[key] == nil { order.append(key) }
            sections[key, default: []].append(row)
        }
        return order.map { key in
            let rows = sections[key] ?? []
            return AccountSection(id: key, account: rows.first?.account, isCurrent: rows.first?.isCurrentAccount ?? true, rows: rows)
        }
    }

    /// What the header of an account's section says about its readings: the account's own notice, else its client's.
    /// A billing pool speaks only for itself: its vendor's notices can be about another of its pools.
    public func accountNotice(for section: AccountSection) -> String? {
        guard let account = section.account else { return nil }
        let pooled = section.rows.first?.agent.billingPool != nil
        return account.quotaNotice ?? (pooled ? nil : report?.sourceNotices[account.account.provider])
    }

    /// Tokens per hour over the observed part of this quota window's current cycle. Token history before the local ledger
    /// begins is not guessed at.
    public func tokensPerHour(for agentId: String) -> Double? {
        guard let report, let snapshot = report.snapshot(for: agentId),
              let consumers = report.consumerIdsByQuota[agentId] else { return nil }
        return QuotaMath.tokensPerHour(snapshot: snapshot, consumers: consumers, usage: report.usage, now: now)
    }

    /// What the window's reading and recent pace say about the rest of its cycle.
    public func outlook(for agentId: String) -> QuotaOutlook? {
        guard let report, let snapshot = report.snapshot(for: agentId) else { return nil }
        return QuotaMath.outlook(snapshot: snapshot, insights: report.insightsByAgent[agentId], now: now)
    }

    /// The window's outlook in words.
    public func forecastHint(for agentId: String) -> String? {
        guard let report, let snapshot = report.snapshot(for: agentId) else { return nil }
        return QuotaForecast.hint(snapshot: snapshot, insights: report.insightsByAgent[agentId], now: now)
    }

    // MARK: Sessions

    /// The session with this id, the first listed where several share it.
    public func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    /// A session as this view reads it, one that is not among `sessions` included, such as a copy from an earlier report.
    public func session(for session: LiveSession) -> Session {
        Self.read(session, index: index, settings: settings, now: now)
    }

    /// The phase of a session, one that is not among `sessions` included.
    public func phase(of session: LiveSession) -> SessionPhase { self.session(for: session).phase }

    /// The sessions in flight, newest first.
    public var liveSessions: [Session] { sessions.filter(\.phase.isInFlight) }

    /// The vendors with work in flight. A session names the model it spends rather than the quota row it belongs to, so
    /// its vendor is resolved instead of its id being compared with a row's.
    public var workingVendors: Set<String> { Set(liveSessions.compactMap(\.source.vendor)) }

    /// How long after its last event a vendor still belongs in a logo queue.
    static let queueRecency: TimeInterval = 24 * 3600

    /// What a logo queue shows: every row's vendor, in row order, then any vendor with a session whose last event is at
    /// most `queueRecency` old and has no row on that list, most recently used first. An agent used this morning belongs
    /// in the queue whether or not its quota is followed; one nobody has run for a day and nobody watches does not. A
    /// vendor whose live status is off is not counted as having run, since that switch is what says its runs may be
    /// reported at all.
    public var queueVendors: [(vendor: String, isWorking: Bool)] {
        let working = workingVendors
        var order = rows.map(\.agent.vendor)
        var seen = Set(order)
        let cutoff = now.addingTimeInterval(-Self.queueRecency)
        for session in sessions where session.lastEventAt >= cutoff {
            guard session.liveStatus, let vendor = session.source.vendor, seen.insert(vendor).inserted else { continue }
            order.append(vendor)
        }
        return order.map { (vendor: $0, isWorking: working.contains($0)) }
    }

    /// What sessions are read against: the vendor of each agent id, and the report's turns and newest turn event by session.
    private struct Index: Sendable {
        var vendors: [String: String] = [:]
        var turns: [String: [SessionTurn]] = [:]
        var lastTurnEvents: [String: Date] = [:]

        /// A vendor comes from the consumers, then the settings rows, then the report's own rows.
        init(report: UsageReport?, agents: [AgentDescriptor]) {
            for agent in (report?.consumers ?? []) + agents + (report?.discoveredAgents ?? []) where vendors[agent.id] == nil {
                vendors[agent.id] = agent.vendor
            }
            for turn in report?.turns ?? [] {
                turns[turn.sessionID, default: []].append(turn)
                let at = RecordCoding.date(turn.observedAtMs)
                if at > lastTurnEvents[turn.sessionID] ?? .distantPast { lastTurnEvents[turn.sessionID] = at }
            }
        }
    }

    private static func read(_ session: LiveSession, index: Index, settings: Settings, now: Date) -> Session {
        let vendor = index.vendors[session.agentId] ?? SessionSource.vendor(impliedBy: session.agentId)
        let provider = vendor?.lowercased()
        let turns = (index.turns[session.id] ?? []).filter { provider == nil || $0.provider.lowercased() == provider }
        let lastEventAt = session.lastEvent(turnAt: index.lastTurnEvents[session.id])
        let liveStatus = settings.liveStatusEnabled(for: vendor ?? "")
        return Session(session: session, source: SessionSource(vendor: vendor, client: session.client), turn: turns.last,
                       lastEventAt: lastEventAt, message: turns.last { $0.message != nil }?.message, liveStatus: liveStatus,
                       phase: SessionPhase(session: session, turn: turns.last, lastEventAt: lastEventAt, liveStatus: liveStatus, now: now))
    }
}
