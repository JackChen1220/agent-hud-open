import AgentHUDSupport
import Foundation

/// What the Mac shows of a report at one time: the quota rows it lists and how they group, the balances, the glow's
/// levels, and each session with its source, newest turn, last event, message and phase. Rows, balances, levels and
/// sessions are worked out when the view is built, a window's metrics only when asked for. A session's phase comes from
/// the report, the turns its client's hooks saw and the permission requests waiting for an answer.
public struct ReportView: Sendable {
    /// One session as the Mac shows it.
    public struct Session: Hashable, Sendable, Identifiable {
        public let session: LiveSession
        /// The session's vendor, from the consumer its model is, a settings row, a report row or its id, and its client.
        public let source: SessionSource
        /// The newest turn from the session's vendor, or from any provider without a vendor: the one that started last, a
        /// turn without a start counting from when it was observed, then the one observed last, the later listed of equals.
        public let turn: SessionTurn?
        /// When the session last did something: its newest turn event from any provider, or its end when that is later;
        /// without turns, its end, or while in flight when its log last recorded anything, else the reading that last saw
        /// it. A permission request waiting for an answer is an event too, and so are the prompt and the Stop hook of a
        /// hook turn that takes the reading's place.
        public let lastEventAt: Date
        /// What the agent last said: the message of the newest turn that carries one, from the providers `turn` comes
        /// from, or what it said at the Stop hook of a hook turn that takes the reading's place. Nil while live status is
        /// off.
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
    /// running session nothing has been heard from for half an hour sits below one that just answered. Sessions with the
    /// same last event are ordered by vendor, then id.
    public let sessions: [Session]

    private let report: UsageReport?
    private let settings: Settings
    private let index: Index

    /// - agents: the settings' rows, in their order.
    /// - approvals: the permission requests waiting for an answer. A session whose client waits for one is waiting for
    ///   approval, however its source reads, for as long as the client waits.
    /// - hookTurns: the turns clients' prompt and Stop hooks saw, by session id. A hook turn takes the place of the phase
    ///   the report gives wherever the hooks saw more (`SessionPhase.hookPrevails(_:over:lastEventAt:)`), unless it is out
    ///   of date while the report has the session in flight.
    public init(report: UsageReport?, agents: [AgentDescriptor], settings: Settings, approvals: [PermissionRequest] = [],
                hookTurns: [String: SessionPhase.HookTurn] = [:], now: Date) {
        let visible = report?.visibleRows(agents) ?? agents
        // Without a report, a plan pool's rows stay hidden.
        let enabled = visible.filter { $0.enabled && Self.isPoolActive($0, in: report, withoutReport: false) }
        let rows = enabled.filter { !$0.isAPIBilled }.enumerated().map { index, agent in
            let snapshot = report?.snapshot(for: agent.id)
            // Without a report, a row has no reading and counts as its account's current one.
            let assessment = report?.assess(.window(agent), now: now)
                ?? ReadingAssessment(status: .normal, isCurrentAccount: true, observedAt: nil, now: now)
            return AgentRow(
                agent: agent,
                remainingPct: snapshot?.remainingPct,
                level: assessment.showsLevel ? snapshot.map { AlertPolicy.quotaLevel(remaining: $0.remainingPct) } : nil,
                resetAt: snapshot?.resetAt,
                weeklyRemainingPct: snapshot?.weeklyRemainingPct,
                paletteIndex: index,
                account: agent.account.flatMap { report?.observation(accountID: $0.id) },
                assessment: assessment
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
        let index = Index(report: report, agents: agents, approvals: approvals, hookTurns: hookTurns)
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
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            let lhs = $0.source.vendor ?? "", rhs = $1.source.vendor ?? ""
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    // MARK: Quota

    /// Whether a row's plan pool is active: a row without one always is, and a plan pool is unless the report's inventory
    /// for its provider leaves it out. Without a report, `withoutReport` answers.
    static func isPoolActive(_ agent: AgentDescriptor, in report: UsageReport?, withoutReport: Bool) -> Bool {
        guard let pool = agent.billingPool, pool.product == .plan else { return true }
        guard let report else { return withoutReport }
        return report.activeQuotaPoolIDs?[pool.provider]?.contains(pool.id) ?? true
    }

    /// The vendor of each quota row that shows a status level, in row order. An alert's pulse lights the part of the glow
    /// its vendor's entries take in this list.
    public var alertPulseVendors: [String] { rows.filter { $0.level != nil }.map { $0.agent.vendor } }

    /// The most consumed window of a signed-in account, shown in the menu bar, whatever its reading's status or age.
    public var maxUsedPct: Double? { rows.filter(\.assessment.isCurrentAccount).compactMap(\.usedPct).max() }

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

    /// An account's reading as its section header weighs it at the view's time.
    public func assessment(of account: AccountObservation) -> ReadingAssessment {
        report?.assess(.account(account), now: now)
            ?? ReadingAssessment(status: account.ownStatus, isCurrentAccount: account.isCurrent, observedAt: account.observedAt, now: now)
    }

    /// What the header of an account's section says about its readings: the reason of the account's status, else, with
    /// `clientNotices`, its client's notices. A billing pool speaks only for itself: its vendor's notices can be about
    /// another of its pools.
    public func accountNotice(for section: AccountSection, clientNotices: Bool = true) -> String? {
        guard let account = section.account else { return nil }
        let pooled = section.rows.first?.agent.billingPool != nil
        return assessment(of: account).status.reason ?? (pooled || !clientNotices ? nil : report?.sourceNotices[account.account.provider])
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

    /// How long after its last event a session stays on the Sessions page.
    static let listRecency: TimeInterval = 7 * 86400

    /// The sessions whose last event is at most `listRecency` old, newest first: those the Sessions page lists.
    public var recentSessions: [Session] {
        let cutoff = now.addingTimeInterval(-Self.listRecency)
        return sessions.filter { $0.lastEventAt >= cutoff }
    }

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

    /// What sessions are read against: the vendor of each agent id, the report's turns and newest turn event by session,
    /// when each session's client last asked for approval among the requests still waiting, and the hooks' turns.
    private struct Index: Sendable {
        var vendors: [String: String] = [:]
        var turns: [String: [SessionTurn]] = [:]
        var lastTurnEvents: [String: Date] = [:]
        var requests: [String: Date] = [:]
        let hooks: [String: SessionPhase.HookTurn]

        /// A vendor comes from the consumers, then the settings rows, then the report's own rows.
        init(report: UsageReport?, agents: [AgentDescriptor], approvals: [PermissionRequest], hookTurns: [String: SessionPhase.HookTurn]) {
            hooks = hookTurns
            for agent in (report?.consumers ?? []) + agents + (report?.discoveredAgents ?? []) where vendors[agent.id] == nil {
                vendors[agent.id] = agent.vendor
            }
            for turn in report?.turns ?? [] {
                turns[turn.sessionID, default: []].append(turn)
                let at = RecordCoding.date(turn.observedAtMs)
                if at > lastTurnEvents[turn.sessionID] ?? .distantPast { lastTurnEvents[turn.sessionID] = at }
            }
            for request in approvals where request.at > requests[request.sessionID] ?? .distantPast {
                requests[request.sessionID] = request.at
            }
        }
    }

    /// The newest of a session's turns: the one that started last, a turn without a start counting from when it was
    /// observed, then the one observed last; of equals, the later listed.
    static func newest(_ turns: [SessionTurn]) -> SessionTurn? {
        turns.reduce(nil) { newest, turn in
            guard let newest else { return turn }
            return (turn.startedAtMs ?? turn.observedAtMs, turn.observedAtMs) >= (newest.startedAtMs ?? newest.observedAtMs, newest.observedAtMs)
                ? turn : newest
        }
    }

    private static func read(_ session: LiveSession, index: Index, settings: Settings, now: Date) -> Session {
        let vendor = index.vendors[session.agentId] ?? SessionSource.vendor(impliedBy: session.agentId)
        let provider = vendor?.lowercased()
        let turns = (index.turns[session.id] ?? []).filter { provider == nil || $0.provider.lowercased() == provider }
        let turn = newest(turns)
        let asked = index.requests[session.id]
        var lastEventAt = max(session.lastEvent(turnAt: index.lastTurnEvents[session.id]), asked ?? .distantPast)
        let liveStatus = settings.liveStatusEnabled(for: vendor ?? "")
        var phase = SessionPhase(session: session, turn: turn, lastEventAt: lastEventAt, liveStatus: liveStatus, now: now)
        var message = newest(turns.filter { $0.message != nil })?.message
        if liveStatus, let hook = index.hooks[session.id],
           let hooked = SessionPhase.hooked(hook, over: phase, lastEventAt: lastEventAt, now: now) {
            phase = hooked
            lastEventAt = max(lastEventAt, hook.endedAt ?? hook.startedAt)
            message = hook.message ?? message
        }
        if liveStatus, asked != nil { phase = phase.awaitingApproval(session, turn: turn) }
        return Session(session: session, source: SessionSource(vendor: vendor, client: session.client), turn: turn,
                       lastEventAt: lastEventAt, message: liveStatus ? message : nil, liveStatus: liveStatus, phase: phase)
    }
}
