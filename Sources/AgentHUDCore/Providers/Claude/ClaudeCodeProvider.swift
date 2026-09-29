import AgentHUDSupport
import Foundation

/// Real data for the Claude rows.
/// Quota: the Claude Code engine's SDK control protocol (`get_usage`). Sessions and tokens: local transcripts.
/// Burn rate and caps: persisted quota samples.
public struct ClaudeCodeProvider: UsageProvider, LedgerRecording {
    public static let liveThreshold: TimeInterval = 120

    /// Engine queries spawn a process, so they run at most this often regardless of the poll interval.
    public static let engineMinimumInterval = UsageRefresh.accountRequestSpacing

    private let engine: ClaudeEngineUsageClient?
    private let engineCache = EngineUsageCache()
    private let transcripts: ClaudeTranscriptStore
    private let history: QuotaHistoryStore
    private let accountProfileURL: URL?
    /// `ClientHome.key` of the configuration directory, separating unidentified logins of different homes.
    private let home: String
    private let clock: @Sendable () -> Date

    public init(
        engine: ClaudeEngineUsageClient?,
        transcripts: ClaudeTranscriptStore,
        history: QuotaHistoryStore,
        accountProfileURL: URL? = nil,
        home: String = "",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.transcripts = transcripts
        self.history = history
        self.accountProfileURL = accountProfileURL
        self.home = home
        self.clock = clock
    }

    /// Production wiring: the engine binary if present, plus the usage ledger. `persistent` false imports no earlier
    /// version's quota history.
    public static func standard(ledger: UsageLedger, persistent: Bool = true) -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            engine: ClaudeEngineLocator.find().map {
                ClaudeEngineUsageClient(executable: $0, workingDirectory: ClaudeEngineUsageClient.defaultWorkingDirectory)
            },
            transcripts: ClaudeTranscriptStore(ledger: ledger, watchesChanges: true),
            history: QuotaHistoryStore(ledger: ledger, scope: "claude",
                                       importing: persistent ? AppSupport.directory.appendingPathComponent("quota-history.json") : nil),
            accountProfileURL: ClaudeSubscription.accountProfileURL,
            home: ClaudeSubscription.home
        )
    }

    public var watchedDirectories: [URL]? { transcripts.roots + [AttentionHooks.directory] }
    public func fileChanges(_ paths: Set<String>?) async { await transcripts.fileChanges(paths) }

    private func account(for reading: EngineUsageCache.Reading) -> ProviderAccount {
        reading.identity?.account ?? .unresolved(provider: "Claude", home: home)
    }

    public func refreshAccountUsage(historyHours: Int) async {
        let now = clock()
        do {
            let profileURL = accountProfileURL
            let (result, fetchedAt, fresh) = try await engineCache.fetch(client: engine, now: now, minimumInterval: Self.engineMinimumInterval) {
                profileURL.flatMap { try? Data(contentsOf: $0) }
            }
            if fresh {
                let account = account(for: result)
                await history.append(result.usage.usage.rows.map { $0.scoped(to: account) }.map {
                    QuotaSample(agentId: $0.id, timestamp: fetchedAt, remainingPct: $0.window.remainingPct)
                }, now: now)
            }
        } catch { /* The cached result carries the account error into the next local report. */ }
    }

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        let now = clock()
        let weekAgo = now.addingTimeInterval(-AlertPolicy.insightsLookback)
        let cutoff = min(weekAgo, now.addingTimeInterval(-TimeInterval(historyHours) * 3600))

        // Local data: one cooperative indexing step (newest files first); the rest continues on later polls.
        let indexed = await transcripts.index(modifiedSince: cutoff)
        let sessions = indexed.sessions
        let indexing = indexed.pending > 0 ? IndexProgress(done: sessions.count, total: sessions.count + indexed.pending) : nil
        let observations: [(modelId: String, seenAt: Date)] = sessions.flatMap { session in
            session.modelsSeen.map { (modelId: $0.key, seenAt: $0.value) }
        }
        // All observed models are consumers; quota rows remain the plan's independent windows below.
        let consumers = ClaudeModelDiscovery.discover(observations).map(\.descriptor)

        // 1. Quota from the engine. A login without plan limits (API key, third-party platform) keeps the local data.
        var usage: ClaudeUsage?
        var notice: String?
        var updatedAt = now
        var reading: EngineUsageCache.Reading?
        do {
            if let (result, fetchedAt) = try await engineCache.reading() {
                reading = result
                updatedAt = fetchedAt
                if result.usage.rateLimitsAvailable {
                    // Keep the engine's observation intact. A deadline passing is not a confirmed reset.
                    usage = result.usage.usage
                } else {
                    notice = (result.signedIn == false ? ClaudeDataError.signedOut : .planLimitsUnavailable).errorDescription
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Quota availability does not determine whether a local turn completed.
            guard !sessions.isEmpty else { throw error }
            notice = error.localizedDescription
        }
        let plan = reading?.plan
        let account = reading.map(account(for:))
        let sessionRowId = account?.windowID(ClaudeUsage.sessionRowId) ?? ClaudeUsage.sessionRowId

        // Quota rows: one per window (session / weekly / weekly per family), each with its own reset cadence.
        let windowRows = account.map { account in (usage?.rows ?? []).map { $0.scoped(to: account) } } ?? []
        let discovered = windowRows.map(\.descriptor)
        var snapshots: [UsageSnapshot] = []
        for row in windowRows {
            snapshots.append(UsageSnapshot(
                agentId: row.id,
                remainingPct: row.window.remainingPct,
                weeklyRemainingPct: usage?.sevenDay?.remainingPct,
                resetAt: row.window.resetsAt,
                windowDuration: row.duration,
                weeklyResetAt: usage?.sevenDay?.resetsAt,
                updatedAt: updatedAt
            ))
        }

        // 2. Session list: running first, then most recent. A session also runs while the sub-agents and workflow agents
        // it started are at work, after its own agent stopped or went quiet waiting for them.
        let windowStart = usage?.fiveHour?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) } ?? now.addingTimeInterval(-5 * 3600)
        let agents = Self.workingAgents(sessions, now: now)
        func isLive(_ session: TranscriptSession) -> Bool {
            session.isLive(now: now, threshold: Self.liveThreshold) || agents[session.path] != nil
        }
        let candidates = sessions.filter { !$0.isSubagent }.sorted { lhs, rhs in
            let lhsLive = isLive(lhs), rhsLive = isLive(rhs)
            if lhsLive != rhsLive { return lhsLive }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        let windowTokens = await transcripts.tokens(since: windowStart)
        let windowTotal = windowTokens.values.reduce(0, +)
        let utilization = usage?.fiveHour?.utilizationPct ?? 0
        let listed = candidates.map { session -> LiveSession in
            let live = isLive(session)
            let share = windowTotal > 0 ? Double(windowTokens[session.path] ?? 0) / Double(windowTotal) : 0
            let agentId = session.dominantAgentId
            return LiveSession(
                id: session.id,
                agentId: agentId,
                task: session.task ?? L10n.text("（未命名会话）", "(untitled session)"),
                terminal: session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                startedAt: session.startedAt,
                endedAt: live ? nil : session.lastActivityAt,
                // A session that spent nothing in the current window has no share of it, rather than a share of zero.
                pctOfWindow: share > 0 ? share * utilization : nil,
                tokensIn: session.tokensIn,
                tokensOut: session.tokensOut,
                client: ClaudeEntrypoint.clientLabel(session.entrypoint),
                transcriptPath: session.path,
                cacheReadTokens: session.cacheReadTokens, observedAt: now, workingDirectory: session.cwd
            )
        }

        // 3. Insights from each window's readings of the last week; the session window gets them even without a reading.
        let sessionSamples = await history.samples(agentId: sessionRowId, since: weekAgo)
        var insightsByAgent: [String: UsageInsights] = account == nil ? [:] : [sessionRowId: QuotaMath.insights(
            snapshot: snapshots.first { $0.agentId == sessionRowId }, samples: sessionSamples, capsSince: weekAgo, now: now)]
        for row in windowRows where row.id != sessionRowId {
            let samples = await history.samples(agentId: row.id, since: weekAgo)
            insightsByAgent[row.id] = QuotaMath.insights(snapshot: snapshots.first { $0.agentId == row.id }, samples: samples,
                                                         capsSince: weekAgo, now: now)
        }
        let consumerIds = Set(consumers.map(\.id) + listed.map(\.agentId))
        var consumerIdsByQuota: [String: Set<String>] = [:]
        if let account {
            consumerIdsByQuota[sessionRowId] = consumerIds
            consumerIdsByQuota[account.windowID(ClaudeUsage.weeklyRowId)] = consumerIds
            for id in consumerIds {
                if let info = ClaudeModelInfo.parse(String(id.dropFirst("claude-model:".count))) {
                    consumerIdsByQuota[account.windowID("\(ClaudeUsage.weeklyRowId)-\(info.family.lowercased())"), default: []].insert(id)
                }
            }
        }
        return UsageReport(
            generatedAt: now,
            snapshots: snapshots,
            sessions: listed,
            notice: notice,
            discoveredAgents: discovered,
            consumers: consumers,
            indexing: indexing,
            insightsByAgent: insightsByAgent,
            subscriptions: plan.map { ["Claude": $0] } ?? [:],
            sourceNotices: notice.map { ["Claude": $0] } ?? [:],
            consumerIdsByQuota: consumerIdsByQuota,
            completions: sessions.flatMap(\.completions),
            turns: Self.turns(candidates, agentsWorkingAt: agents, requests: AttentionHooks.read(source: AttentionHooks.Source.claude, now: now)),
            // A login without plan limits has no current subscription account; earlier accounts keep their last readings.
            accounts: reading.map { reading in
                ["Claude": usage == nil ? [] : [AccountObservation(account: self.account(for: reading), home: home,
                    label: reading.identity?.email, plan: plan, observedAt: updatedAt)]]
            }
        )
    }
}

/// Serialises engine queries and throttles them, since each one spawns a full engine process.
actor EngineUsageCache {
    /// One engine reading with what the account profile read around it says. The profile can run to megabytes, so
    /// it is decoded once for the reading rather than on every pass that shows it.
    struct Reading: Sendable {
        let usage: ClaudeEngineUsage
        let identity: ClaudeSubscription.Identity?
        let plan: String?
        /// Asked only when there are no plan limits, to say why there are none.
        var signedIn: Bool?
    }

    private var last: (at: Date, result: Result<Reading, any Error>)?

    func reading() throws -> (Reading, Date)? {
        guard let last else { return nil }
        return (try last.result.get(), last.at)
    }

    /// `fresh` is false when the reading comes from the cache rather than a new engine query.
    /// The profile is read before and after the query; a login change in between discards the reading.
    func fetch(client: ClaudeEngineUsageClient?, now: Date, minimumInterval: TimeInterval,
               profile: @Sendable () -> Data? = { nil }) async throws -> (Reading, Date, fresh: Bool) {
        if let last, now.timeIntervalSince(last.at) < minimumInterval {
            return (try last.result.get(), last.at, false)
        }
        let result: Result<Reading, any Error>
        do {
            guard let client else { throw ClaudeDataError.engineNotFound }
            let before = profile()
            let usage = try await client.fetch()
            let after = profile()
            let identity = ClaudeSubscription.identity(profileData: after)
            // An API-key or third-party login can leave an old profile behind; only plan limits make it the reading's account.
            guard ClaudeSubscription.identity(profileData: before) == identity else { throw ClaudeDataError.accountChanged }
            let signedIn = usage.rateLimitsAvailable ? nil : await client.isSignedIn()
            result = .success(Reading(usage: usage, identity: usage.rateLimitsAvailable ? identity : nil,
                                      plan: ClaudeSubscription.plan(type: usage.subscriptionType, profileData: after),
                                      signedIn: signedIn))
        }
        catch {
            try Task.checkCancellation()
            result = .failure(error)
        }
        // Failed attempts use the same interval, so completion polling cannot repeatedly spawn a broken engine.
        last = (now, result)
        return (try result.get(), now, true)
    }
}

extension ClaudeCodeProvider {
    /// When the sub-agents still at work last did something, keyed by the log of the session that started them. Claude
    /// Code keeps a session's sub-agent and workflow agent logs in a directory named after its own log.
    static func workingAgents(_ sessions: [TranscriptSession], now: Date) -> [String: Date] {
        var latest: [String: Date] = [:]
        for agent in sessions where agent.isSubagent && agent.isLive(now: now, threshold: liveThreshold) {
            guard let directory = agent.path.range(of: "/subagents/") else { continue }
            let parent = String(agent.path[..<directory.lowerBound]) + ".jsonl"
            latest[parent] = max(latest[parent] ?? agent.lastActivityAt, agent.lastActivityAt)
        }
        return latest
    }

    /// Each session's turn. A request is compared with the session's own log, which is what answering it writes to; what
    /// its sub-agents write afterwards does not answer it, so their work is added only once that is decided.
    static func turns(_ sessions: [TranscriptSession], agentsWorkingAt: [String: Date],
                      requests: [String: AttentionHooks.Event]) -> [SessionTurn] {
        sessions.compactMap { session in
            session.turn.map { turn(awaiting([$0], requests: requests)[0], agentsWorkingAt: agentsWorkingAt[session.path]) }
        }
    }

    /// The session's turn, running while its agents work: the agent that stopped, or went quiet waiting for them, has not
    /// finished what it was asked. A turn waiting for approval keeps waiting.
    static func turn(_ turn: SessionTurn, agentsWorkingAt: Date?) -> SessionTurn {
        guard let agentsWorkingAt else { return turn }
        return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID,
                           state: turn.state == .waitingForApproval ? .waitingForApproval : .running, startedAtMs: turn.startedAtMs,
                           observedAtMs: max(turn.observedAtMs, RecordCoding.milliseconds(agentsWorkingAt)), message: turn.message)
    }

    /// A turn Claude Code said it is blocked on. The hook only says it needs the user; a turn that is still running is
    /// waiting for approval, and one that already finished is simply waiting for the next prompt. A request older than
    /// the transcript has been answered.

    static func awaiting(_ turns: [SessionTurn], requests: [String: AttentionHooks.Event]) -> [SessionTurn] {
        guard !requests.isEmpty else { return turns }
        return turns.map { turn in
            guard turn.state == .running, let request = requests[turn.sessionID],
                  RecordCoding.milliseconds(request.at) > turn.observedAtMs else { return turn }
            return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID,
                               state: .waitingForApproval, startedAtMs: turn.startedAtMs,
                               observedAtMs: RecordCoding.milliseconds(request.at), message: request.message ?? turn.message)
        }
    }
}
