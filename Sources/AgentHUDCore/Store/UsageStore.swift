import AgentHUDSupport
import Foundation
import Observation

/// One agent as shown in the hover panel / menu: descriptor + latest reading.
public struct AgentRow: Hashable, Sendable, Identifiable {
    public let agent: AgentDescriptor
    public let remainingPct: Double?
    public let level: StatusLevel?
    public let resetAt: Date?
    public let weeklyRemainingPct: Double?
    /// Index into `AgentPalette` (position among enabled agents).
    public let paletteIndex: Int
    /// The account this window belongs to, when the provider identifies accounts.
    public let account: AccountObservation?
    /// Other accounts show their last reading without a status level, so they stay out of the glow and alerts.
    public let isCurrentAccount: Bool

    public var id: String { agent.id }

    /// Share of the window already consumed; the UI shows usage, not what is left.
    public var usedPct: Double? { remainingPct.map { max(0, min(100, 100 - $0)) } }

    public var missingQuotaLabel: String {
        "—"
    }

    public func resetLabel(now: Date, compact: Bool = false) -> String {
        guard isCurrentAccount else { return "—" }
        if let resetAt {
            if resetAt <= now { return L10n.text("等待更新", "Pending update") }
            if resetAt.timeIntervalSince(now) < 60 { return "<1m" }
        }
        return compact ? Countdown.resetLabelCompact(resetAt, now: now) : Countdown.resetLabel(resetAt, now: now)
    }
}

extension UsageReport {
    /// The times at which this report's activity changes with time alone: when a running turn reaches the age at which
    /// it no longer counts as current, and when a session whose source never said what its turn is doing reaches the
    /// age at which a quiet log ends it. A source is read again at these times instead of being polled.
    var activityChecks: [Date] {
        let margin: TimeInterval = 1
        var times = sessions.filter(\.isLive).map { $0.observedAt.addingTimeInterval(SessionPhase.Limits.quiet + margin) }
        for turn in turns where turn.state == .running {
            let observed = RecordCoding.date(turn.observedAtMs)
            times.append(observed.addingTimeInterval(SessionPhase.Limits.quiet + margin))
            times.append(observed.addingTimeInterval(UsageRefresh.activeTurnFreshness + margin))
            times.append(observed.addingTimeInterval(SessionPhase.Limits.abandoned + margin))
        }
        return times
    }

    /// When an account reading of this source is next worth taking, counted from `since`, when its steps last ran.
    /// A window moves only while work runs, so a running turn is read often, a session between turns slowly, and work
    /// that finished after the last reading once more. An idle source's windows change only when they reset, and a
    /// source that cannot see this Mac's work keeps the account interval.
    func accountCheck(since: Date, now: Date, seesLocalWork: Bool) -> Date {
        // A deadline remains due until an account request has actually run at or after it.
        // Comparing with `now` loses the scheduled refresh as soon as the deadline arrives.
        let reset = snapshots.filter { snapshot in
            discoveredAgents.first(where: { $0.id == snapshot.agentId }).map(isCurrent) ?? true
        }.compactMap(\.resetAt).filter { $0 > since }.min()
        let regular: Date
        let stale = now.addingTimeInterval(-UsageRefresh.activeTurnFreshness)
        if turns.contains(where: { $0.state == .running && RecordCoding.date($0.observedAtMs) > stale }) {
            regular = since.addingTimeInterval(UsageRefresh.runningAccountInterval)
        } else if sessions.contains(where: { $0.isLive(at: now) }) {
            regular = since.addingTimeInterval(UsageRefresh.liveAccountInterval)
        } else if !seesLocalWork {
            regular = since.addingTimeInterval(UsageRefresh.accountInterval)
        } else if sessions.contains(where: { ($0.endedAt ?? .distantPast) > since }) {
            regular = now
        } else {
            regular = reset == nil || snapshots.contains(where: { ($0.resetAt ?? .distantFuture) <= since })
                ? since.addingTimeInterval(UsageRefresh.accountInterval) : .distantFuture
        }
        return min(regular, reset ?? .distantFuture)
    }
}

/// Keeps a change handler registered with `UsageStore.observeChanges(_:)`; releasing it unregisters the handler.
public final class UsageChangeObservation {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    public func cancel() { cancellation?(); cancellation = nil }
    deinit { cancellation?() }
}

/// Rows of one account inside a vendor group.
public struct AccountSection: Identifiable, Sendable {
    public let id: String
    public let account: AccountObservation?
    public let isCurrent: Bool
    public let rows: [AgentRow]
}

/// Observable app state: the collected report, derived rows, glow appearance and stats selections.
@MainActor
@Observable
public final class UsageStore {
    public internal(set) var report: UsageReport? { didSet { reportGeneration += 1 } }
    public internal(set) var lastError: String?
    public internal(set) var pausedUntil: Date?
    public internal(set) var isRefreshing = false
    public private(set) var statsRange: StatsRange = .hours24
    public var tokenBucketSize: TokenBucketSize = .hour1
    public var tokenDimensions: TokenDimensions = .fresh
    /// The agents whose cards the Tokens page shows, once picked there; until then the ones Settings shows that this Mac has.
    public var pickedAgents: Set<String>?
    /// Keep every selectable range ready, including the partial hour at the start of the rolling window.
    public static var historyHours: Int { StatsRange.days7.hours + 1 }
    /// The statistics window's page. Pointing out a quota window turns to Tokens, focusing a session to Sessions.
    public var statsTab: StatsTab = .tokens
    /// The quota window the statistics window points out, set by whatever opened it.
    public var selectedQuotaId: String? { didSet { if selectedQuotaId != nil { statsTab = .tokens } } }
    /// The session the Sessions page shows in place of its list; nil shows the list.
    public var focusedSessionID: String? {
        didSet {
            if focusedSessionID != nil { statsTab = .sessions }
            if focusedSessionID != oldValue { focusedTurn = nil }
        }
    }
    /// The focused session's turn whose calls its page lays out, by its place in the session's breakdown.
    public var focusedTurn: Int? { didSet { if focusedTurn != oldValue { focusedTurnCalls = nil } } }
    /// The focused turn's calls once read, with the tools their logs name.
    public internal(set) var focusedTurnCalls: [TurnCall]?
    /// Where turns' calls are read from; without a ledger (the demo) the demo's calls stand in.
    @ObservationIgnored public var ledger: UsageLedger?
    public var glowHidden = false
    /// Advances every few seconds so countdowns re-render.
    public internal(set) var now = Date()
    /// The turns clients' prompt and Stop hooks saw, by session id, which a host that receives those hooks hands in. A hook
    /// turn takes the place of what a session's log says wherever the hooks saw more
    /// (`SessionPhase.hookPrevails(_:over:lastEventAt:)`), so the panel follows a Stop hook at once.
    public var hookTurns: [String: SessionPhase.HookTurn] = [:]

    public let settings: SettingsStore
    private let accessAllowed: () -> Bool
    private let collector: UsageCollector
    private var clockTask: Task<Void, Never>?
    /// A later poll that found nothing changed extends the report's coverage.
    var checkedAt: Date?
    @ObservationIgnored private var changeObservers: [UUID: @MainActor (UsageChanges) -> Void] = [:]
    /// Counts the reports shown, so that a new one is told from the last without comparing them.
    @ObservationIgnored private var reportGeneration = 0
    /// The last view built, and what it was built from.
    @ObservationIgnored private var built: (generation: Int, agents: [AgentDescriptor], settings: Settings, approvals: [String],
                                            hookTurns: [String: SessionPhase.HookTurn], view: ReportView)?

    /// `hooks` let a host choose the history window, publish each provider report and merge it into the displayed report.
    public init(provider: any UsageProvider, settings: SettingsStore, accessAllowed: @escaping () -> Bool = { true },
                hooks: UsageCollectionHooks = UsageCollectionHooks()) {
        self.settings = settings
        self.accessAllowed = accessAllowed
        collector = UsageCollector(provider: provider, settings: settings, hooks: hooks)
        collector.store = self
    }

    public var isAccessAllowed: Bool { accessAllowed() }

    // MARK: Lifecycle

    public func start() {
        stop()
        collector.start()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.now = Date()
                self.collector.confirmQuiet(at: self.now)
            }
        }
    }

    public func stop() {
        collector.stop()
        clockTask?.cancel()
        clockTask = nil
    }

    /// Reads local data now unless a pass is already running, in which case the next pass reads it.
    public func refresh() async {
        await collector.refresh()
    }

    /// Reads the accounts again as soon as the next pass can, for when someone looks at the numbers instead of waiting
    /// for work to move them. Every provider's own request spacing still holds, so looking twice in a minute reads once.
    public func refreshAccounts() async {
        await collector.refreshAccounts()
    }

    /// Runs only the merge hook again on the provider's last report, for data the merge adds that changed since the pass.
    /// Never overlaps a local poll: one in progress merges for it.
    public func remerge() async {
        await collector.remerge()
    }

    /// Installs a report directly (snapshots, tests) without going through the provider.
    public func replace(report: UsageReport) {
        show(report)
        collector.forgetLocalReport()
        checkedAt = nil
        lastError = nil
        now = Date()
    }

    /// Calls `handler` with what each newly displayed report changed, until the returned observation is released or cancelled.
    public func observeChanges(_ handler: @escaping @MainActor (UsageChanges) -> Void) -> UsageChangeObservation {
        let id = UUID()
        changeObservers[id] = handler
        return UsageChangeObservation { [weak self] in
            // An observation can be released off the main thread; the handler is then removed on it.
            guard Thread.isMainThread else {
                Task { @MainActor [weak self] in _ = self?.changeObservers.removeValue(forKey: id) }
                return
            }
            MainActor.assumeIsolated { _ = self?.changeObservers.removeValue(forKey: id) }
        }
    }

    /// A pass's merged report replaces the displayed one.
    func collected(_ report: UsageReport) {
        show(report)
        checkedAt = nil
        lastError = nil
    }

    /// A merge run again on the provider's last report.
    func merged(_ report: UsageReport) {
        show(report)
    }

    private func show(_ report: UsageReport) {
        let changes = UsageChanges(from: self.report, to: report)
        self.report = report
        guard !changes.isEmpty else { return }
        for handler in changeObservers.values { handler(changes) }
    }

    public func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
    }

    public func resume() {
        pausedUntil = nil
        Task { await refreshAccounts() }
    }

    public var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > now
    }

    // MARK: Stats selections

    public func setStatsRange(_ range: StatsRange) {
        guard range != statsRange else { return }
        statsRange = range
        if !range.bucketSizes.contains(tokenBucketSize) { tokenBucketSize = range.bucketSizes.last ?? .day1 }
    }

    // MARK: Derived

    /// What the Mac shows of the report now: its rows, balances, levels and sessions, with the sessions whose clients wait
    /// for an answer to a permission request (`PermissionRequests.shared`) waiting for approval and the hooks' turns in
    /// their place. It is built again only when the report, the agent list, the settings, the waiting requests, the hooks'
    /// turns or the time changed, and reading it tracks all six.
    public var view: ReportView {
        let report = self.report, agents = settings.agents, preferences = settings.settings, now = self.now
        let approvals = PermissionRequests.shared.pending, requests = approvals.map(\.id), hookTurns = self.hookTurns
        if let built, built.generation == reportGeneration, built.view.now == now, built.agents == agents,
           built.settings == preferences, built.approvals == requests, built.hookTurns == hookTurns { return built.view }
        let view = ReportView(report: report, agents: agents, settings: preferences, approvals: approvals, hookTurns: hookTurns, now: now)
        built = (reportGeneration, agents, preferences, requests, hookTurns, view)
        return view
    }

    /// `view.visibleAgents`.
    public var visibleAgents: [AgentDescriptor] { view.visibleAgents }

    /// `view.enabledAgents`.
    public var enabledAgents: [AgentDescriptor] { view.enabledAgents }

    /// `view.rows`.
    public var rows: [AgentRow] { view.rows }

    public func row(for agentId: String) -> AgentRow? { view.rows.first { $0.id == agentId } }

    /// `view.forecastHint(for:)`.
    public func quotaForecastHint(for agentId: String) -> String? { view.forecastHint(for: agentId) }

    /// `view.tokensPerHour(for:)`, the same reading sent to the phone.
    public func quotaTokensPerHour(for agentId: String) -> Double? { view.tokensPerHour(for: agentId) }

    /// `view.billing`.
    public var enabledBilling: [APIBilling] { view.billing }

    public func balanceLevel(_ balance: AccountBalance, billing: APIBilling) -> StatusLevel? {
        guard !balance.total.isNaN else { return nil }
        return AlertPolicy.balanceLevel([balance], isAvailable: billing.isAvailable)
    }

    /// `view.levels`.
    public var levels: [StatusLevel] { view.levels }

    /// `view.alertPulseVendors`.
    public var alertPulseVendors: [String] { view.alertPulseVendors }

    public var isIndexing: Bool { report?.indexing != nil }

    /// Includes the brief interval before the first refresh starts; a failed fetch ends loading.
    public var isLoading: Bool { isAccessAllowed && report == nil && !isPaused && (isRefreshing || lastError == nil) }

    /// `view.maxUsedPct`.
    public var maxUsedPct: Double? { view.maxUsedPct }

    /// `view.sessions`, newest first.
    public var sessions: [LiveSession] { view.sessions.map(\.session) }

    /// How long after its last event a vendor still belongs in a logo queue.
    public static let queueRecency: TimeInterval = ReportView.queueRecency

    /// `view.queueVendors`.
    public var queueVendors: [(vendor: String, isWorking: Bool)] { view.queueVendors }

    /// `view.workingVendors`.
    public var workingVendors: Set<String> { view.workingVendors }

    /// The session's source as the view reads it.
    public func sessionSource(_ session: LiveSession) -> SessionSource { view.session(for: session).source }

    /// `view.subscriptions`.
    public var subscriptions: [String: String] { view.subscriptions }

    /// The end of the data on screen: the report's time, or the latest poll that confirmed nothing changed.
    public var dataDate: Date { max(report?.generatedAt ?? now, checkedAt ?? .distantPast) }
    public var statsInterval: DateInterval { statsRange.interval(endingAt: dataDate) }

    /// Sessions active in the last seven days, including ones that started before them, whatever range the charts show.
    public var statsSessions: [LiveSession] {
        let interval = StatsRange.days7.interval(endingAt: dataDate)
        return sessions.filter { $0.startedAt <= interval.end && ($0.endedAt ?? now) >= interval.start }
    }

    /// Whether live status is on for the session's vendor.
    public func liveStatusEnabled(for session: LiveSession) -> Bool { view.session(for: session).liveStatus }

    /// Running, including a turn blocked on the user: both are work in flight, and the panel tells them apart by colour.
    public func isSessionLive(_ session: LiveSession) -> Bool { view.phase(of: session).isInFlight }

    /// What the newest turn of this session is doing, when its source reported one.
    public func sessionState(_ session: LiveSession) -> SessionTurn.State? { view.session(for: session).turn?.state }

    public func isSessionWaiting(_ session: LiveSession) -> Bool { view.phase(of: session).state == .waitingForApproval }

    public func sessionStatusLabel(_ session: LiveSession) -> String {
        let shown = view.session(for: session)
        guard shown.liveStatus else { return L10n.text("状态显示已关闭", "Live status off") }
        switch shown.phase.state {
        case .unverified: return L10n.text("状态待更新", "Status out of date")
        case .waitingForApproval: return L10n.text("等待批准", "Needs approval")
        // Counts a running session from its own start, not its turn's, and an ended one from its end.
        case .running, .idle: return Countdown.sessionLabel(session, now: now)
        }
    }

    /// `view.liveSessions`.
    public var liveSessions: [LiveSession] { view.liveSessions.map(\.session) }

    /// The focused session while this Mac still reports it.
    public var focusedSession: LiveSession? { focusedSessionID.flatMap { view.session($0)?.session } }

    public func sessionUsage(_ session: LiveSession) -> SessionUsage? { report?.sessionUsage?[session.id] }

    /// Reads the focused turn's calls from the ledger, and the tools they asked for from their logs, once per focus.
    public func loadFocusedTurnCalls() async {
        guard focusedTurnCalls == nil, let session = focusedSession, let index = focusedTurn,
              let turns = sessionUsage(session)?.turns, turns.indices.contains(index) else { return }
        let turn = turns[index]
        let calls: [TurnCall]
        if let ledger {
            let read = (try? await ledger.turnCalls(SessionUsageRequest(session), from: turn.start, through: turn.end)) ?? []
            calls = await Task.detached(priority: .userInitiated) { CallTools.attach(to: read) }.value
        } else {
            calls = DemoData.turnCalls(session: session.id, turn: turn)
        }
        // The focus may have moved while the calls were read.
        guard focusedSession?.id == session.id, focusedTurn == index else { return }
        focusedTurnCalls = calls
    }

    /// What the agent last said in the session's newest turn that carries a message; nothing while live status is off.
    public func sessionMessage(_ session: LiveSession) -> String? { view.session(for: session).message }

    /// Every token the session and its sub-agents spent, by kind: its breakdown, or its log's counts, which do not split
    /// cache writes and reasoning apart.
    public func sessionTokens(_ session: LiveSession) -> TokenKinds {
        sessionUsage(session)?.total.kinds
            ?? TokenKinds(tokensIn: session.tokensIn, tokensOut: session.tokensOut, cacheRead: session.cacheReadTokens)
    }

    /// Sessions under the local day they started on, in the order given; the newest day first. A session keeps its day
    /// however long it runs, so a day's sessions and their totals do not move as they carry on.
    public func sessionsByDay(_ sessions: [LiveSession], calendar: Calendar = .current) -> [(day: Date, sessions: [LiveSession])] {
        var days: [(day: Date, sessions: [LiveSession])] = []
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            if let index = days.firstIndex(where: { $0.day == day }) { days[index].sessions.append(session) }
            else { days.append((day, [session])) }
        }
        return days.sorted { $0.day > $1.day }
    }

    public var hasLiveSession: Bool { view.sessions.contains { $0.phase.isInFlight } }

    public var updatedAt: Date? { report?.generatedAt }

    /// - screen: which display's glow to resolve; nothing asks for the default one.
    public func glowAppearance(light: Bool, on screen: String? = nil) -> GlowAppearance {
        let appearance = GlowAppearance.resolve(
            levels: levels,
            paused: isPaused || !isAccessAllowed,
            anyAgentActive: hasLiveSession,
            glow: settings.settings.glow(on: screen),
            light: light
        )
        guard glowHidden else { return appearance }
        return GlowAppearance(
            stops: appearance.stops, peakOpacity: appearance.peakOpacity, troughOpacity: appearance.troughOpacity,
            breathing: appearance.breathing, breathSeconds: appearance.breathSeconds, hidden: true
        )
    }

    // MARK: Consumers (token spenders, e.g. model families)

    /// Token spend is independent of which remaining-quota windows the user monitors.
    public var consumers: [AgentDescriptor] { report?.consumers ?? [] }

    /// Both surfaces show every model's token spend.
    public var tokenColumns: [TokenColumn] {
        ChartData.tokenBars(usage: report?.usage ?? [], agentIds: consumers.map(\.id), range: statsRange, bucketSize: tokenBucketSize,
                            now: dataDate, dimensions: tokenDimensions)
    }

    public var statsActivity: ActivityGrid {
        UsageAnalytics.activityGrid(usage: (report?.usage ?? []).filter { $0.start < dataDate },
            since: dataDate.addingTimeInterval(-7 * 86400), calendar: .current, dimensions: tokenDimensions)
    }

    /// The platform each model's calls are priced on: the one its client reaches.
    public var priceRegions: PriceRegions { PriceRegions(report: report) }

    /// What each agent spent in the charted range, the most tokens of the selected kinds first.
    public var agentUsage: [AgentUsage] {
        AgentUsage.build(usage: report?.usage ?? [], consumers: consumers, sessions: sessions, breakdowns: report?.sessionUsage ?? [:],
                         vendor: { self.sessionSource($0).vendor }, interval: statsInterval, dimensions: tokenDimensions,
                         region: priceRegions.region(for:))
    }

    /// An agent's tokens of the selected kinds in each of the chart's buckets.
    public func agentSeries(_ vendor: String) -> [Int] {
        ChartData.tokenBars(usage: report?.usage ?? [], agentIds: consumers.filter { $0.vendor == vendor }.map(\.id), range: statsRange,
                            bucketSize: tokenBucketSize, now: dataDate, dimensions: tokenDimensions).map(\.total)
    }

    /// The agents the Tokens page shows cards for: the ones picked there, or the vendors Settings shows that this Mac has.
    public var shownAgents: Set<String> { pickedAgents ?? Set(enabledAgents.filter(\.connected).map(\.vendor)) }

    /// What the charted tokens of the selected kinds would cost at list price, counted as the chart counts them, each
    /// model on its client's platform and DeepSeek's peak hours at its peak rates.
    public var statsListCost: ModelCatalog.ListCost? {
        let interval = statsInterval, ids = Set(consumers.map(\.id)), dimensions = tokenDimensions
        var tokens: [String: TokenKinds] = [:], peak: [String: TokenKinds] = [:], peakRated: [String: Bool] = [:]
        for bucket in report?.usage ?? [] where ids.contains(bucket.agentId) && bucket.overlaps(interval) {
            let kinds = dimensions.masking(bucket.kinds)
            tokens[bucket.agentId, default: TokenKinds()] += kinds
            let rated = peakRated[bucket.agentId] ?? (ModelCatalog.model(for: bucket.agentId)?.peakHours == true)
            peakRated[bucket.agentId] = rated
            if rated, ModelCatalog.isPeak(bucket.start) { peak[bucket.agentId, default: TokenKinds()] += kinds }
        }
        return ModelCatalog.cost(of: tokens, peak: peak, region: priceRegions.region)
    }

    /// What a period's tokens of the selected kinds would cost at list price.
    public func periodListCost(_ period: UsagePeriods.Period) -> ModelCatalog.ListCost? {
        let dimensions = tokenDimensions
        return ModelCatalog.cost(of: periodTokens(period).mapValues(dimensions.masking),
                                 peak: (report?.periods?.peak[period] ?? [:]).mapValues(dimensions.masking), region: priceRegions.region)
    }

    /// Each model's tokens in a period, for the models the charts show.
    public func periodTokens(_ period: UsagePeriods.Period) -> [String: TokenKinds] {
        let ids = Set(consumers.map(\.id))
        return (report?.periods?.tokens[period] ?? [:]).filter { ids.contains($0.key) && !$0.value.isEmpty }
    }

    /// Quota switches do not change token-chart colors.
    public func consumerPaletteIndex(_ id: String) -> Int {
        consumers.firstIndex { $0.id == id } ?? 0
    }

    public func consumerName(_ id: String) -> String {
        guard let consumer = consumers.first(where: { $0.id == id }) else {
            guard let row = rows.first(where: { $0.id == id }) else { return id }
            return L10n.modelLabel(row.agent.model)
        }
        return L10n.modelLabel(consumer.model)
    }

    /// `view.rowGroups`.
    public var rowGroups: [(vendor: String, rows: [AgentRow])] { view.rowGroups }

    /// `view.accountSections(_:)`.
    public func accountSections(_ rows: [AgentRow]) -> [AccountSection] { view.accountSections(rows) }

    /// `view.accountNotice(for:)`.
    public func accountNotice(for section: AccountSection) -> String? { view.accountNotice(for: section) }
}
