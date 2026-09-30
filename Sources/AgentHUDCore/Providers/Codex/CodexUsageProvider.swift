import AgentHUDSupport
import Foundation

public actor CodexUsageProvider: UsageProvider, LedgerRecording {
    private let readLimits: @Sendable () async throws -> CodexRateLimits
    private let transcripts: CodexTranscriptStore
    private let history: QuotaHistoryStore
    private let clock: @Sendable () -> Date
    /// `ClientHome.key` of the Codex home this provider reads.
    private let home: String
    private let readPiLimits: @Sendable () async throws -> CodexRateLimits?
    private let piHome: String
    private var lastRequestAt: Date?
    private struct Reading {
        let limits: CodexRateLimits
        let at: Date
    }
    private var readings: [String: Reading] = [:]
    private var failures: [String: String] = [:]
    /// The email each home's workspace last came with, by home and workspace hash, kept across launches. Both are part of
    /// the account's key, and a reading can lack either: `account/read` can answer too late for the email, and an engine
    /// can leave out `accountId`.
    private var emails: [String: String] = [:]
    private let identityCacheURL: URL?

    public init(readLimits: @escaping @Sendable () async throws -> CodexRateLimits,
                transcripts: CodexTranscriptStore, history: QuotaHistoryStore, home: String = "",
                clock: @escaping @Sendable () -> Date = { Date() },
                readPiLimits: @escaping @Sendable () async throws -> CodexRateLimits? = { nil }, piHome: String = "pi",
                identityCacheURL: URL? = nil) {
        self.readLimits = readLimits; self.transcripts = transcripts; self.history = history; self.home = home; self.clock = clock
        self.readPiLimits = readPiLimits; self.piHome = piHome; self.identityCacheURL = identityCacheURL
        if let data = identityCacheURL.flatMap({ try? Data(contentsOf: $0) }),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            emails = saved
        }
    }

    /// `persistent` false imports no earlier version's quota history and remembers no workspace's email.
    public static func standard(ledger: UsageLedger, persistent: Bool = true) -> CodexUsageProvider {
        let directory = CodexLocator.dataDirectory
        let pi = PiCodexClient(directory: PiCodexClient.directory)
        return CodexUsageProvider(readLimits: {
            guard let executable = CodexLocator.find() else {
                throw UsageProviderError(L10n.text("安装并登录后即可读取额度", "Install and sign in to read quota"))
            }
            return try await CodexAppServerClient(executable: executable, dataDirectory: directory).fetch()
        }, transcripts: .standard(directory: directory, ledger: ledger),
           history: QuotaHistoryStore(ledger: ledger, scope: "codex",
                                      importing: persistent ? AppSupport.directory.appendingPathComponent("codex-quota-history.json") : nil),
           home: ClientHome.key(directory, defaultDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)),
           readPiLimits: { try await pi.fetch() },
           piHome: "pi:" + ClientHome.key(pi.directory, defaultDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")),
           identityCacheURL: persistent ? AppSupport.directory.appendingPathComponent("codex-identities.json") : nil)
    }

    public nonisolated var watchedDirectories: [URL]? { transcripts.roots }
    public func fileChanges(_ paths: Set<String>?) async { await transcripts.fileChanges(paths) }
    // Pi and other clients can spend the same account without writing Codex rollouts.
    public nonisolated var seesLocalWork: Bool { false }

    public func refreshAccountUsage(historyHours: Int) async {
        let now = clock()
        lastRequestAt = now
        await read(home: home) { try await self.readLimits() }
        await read(home: piHome, fetch: readPiLimits)
        // Several clients can read the same account. Its history, windows and alerts have one owner.
        for (source, reading) in accountReadings where failures[source] == nil {
            await history.append(reading.limits.rows(home: source).map {
                QuotaSample(agentId: $0.id, timestamp: reading.at, remainingPct: $0.window.remainingPct)
            }, now: now)
        }
    }

    private func read(home: String, fetch: @Sendable () async throws -> CodexRateLimits?) async {
        do {
            if let limits = try await fetch() { readings[home] = Reading(limits: identified(limits, home: home), at: clock()) }
            else { readings[home] = nil }
            failures[home] = nil
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            failures[home] = message
        }
    }

    /// A reading with half of its account's key takes the other half from the last reading on this home that had both,
    /// so the account keeps its key instead of reappearing under a second one: a workspace whose `account/read` did not
    /// answer takes the email it came with, and an email without `accountId` the workspace it came with, unless it came
    /// with several.
    private func identified(_ limits: CodexRateLimits, home: String) -> CodexRateLimits {
        let workspace = limits.accountId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = limits.account?.email ?? ""
        var filled = limits
        if !workspace.isEmpty, !email.isEmpty {
            let key = home + "/" + RecordCoding.hash([workspace])
            if emails[key] != email {
                emails[key] = email
                saveEmails()
            }
        } else if !workspace.isEmpty {
            if limits.account == nil, let known = emails[home + "/" + RecordCoding.hash([workspace])] {
                filled.account = .init(type: "chatgpt", email: known, planType: nil)
            }
        } else if !email.isEmpty {
            let workspaces = emails.compactMap { key, known -> String? in
                guard known.lowercased() == email.lowercased(), let slash = key.lastIndex(of: "/"), key[..<slash] == home else { return nil }
                return String(key[key.index(after: slash)...])
            }
            if workspaces.count == 1 { filled.rememberedWorkspace = workspaces[0] }
        }
        return filled
    }

    private func saveEmails() {
        guard let identityCacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: identityCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(emails).write(to: identityCacheURL, options: .atomic)
        } catch { NSLog("[AgentHUD] Codex identity cache write failed: %@", error.localizedDescription) }
    }

    private var accountReadings: [(String, Reading)] {
        var accounts: [String: (String, Reading)] = [:]
        for source in [home, piHome] {
            guard let reading = readings[source] else { continue }
            let key = reading.limits.providerAccount(home: source).id
            // Prefer a successful native read, then a successful Pi read over a failed native read.
            if let old = accounts[key], failures[old.0] == nil || failures[source] != nil { continue }
            accounts[key] = (source, reading)
        }
        return accounts.values.sorted { $0.1.limits.providerAccount(home: $0.0).id < $1.1.limits.providerAccount(home: $1.0).id }
    }

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        let now = clock()
        let weekAgo = now.addingTimeInterval(-AlertPolicy.insightsLookback)
        let indexed = await transcripts.index(since: min(weekAgo, now.addingTimeInterval(-Double(historyHours) * 3600)))
        let selected = accountReadings
        let native = readings[home]
        let windows = selected.flatMap { source, reading in
            reading.limits.rows(home: source).map { (row: $0, reading: reading) }
        }
        let models = Set(indexed.sessions.flatMap(\.transcript.models)).sorted()
        let consumers = models.map { AgentDescriptor(id: "codex-model:\($0)", vendor: "Codex", model: ModelCatalog.consumerName(of: "codex-model:\($0)"),
                                                     source: L10n.sourceCodexAppServer, enabled: true) }
        let snapshots = windows.map { row, reading in
            UsageSnapshot(agentId: row.id, remainingPct: row.window.remainingPct, weeklyRemainingPct: row.weekly?.remainingPct,
                          resetAt: row.window.resetAt, windowDuration: row.window.duration,
                          weeklyResetAt: row.weekly?.resetAt, updatedAt: reading.at)
        }
        var byAgent: [String: UsageInsights] = [:]
        for snapshot in snapshots {
            let samples = await history.samples(agentId: snapshot.agentId, since: QuotaMath.historyStart(for: snapshot, now: now))
            byAgent[snapshot.agentId] = QuotaMath.insights(snapshot: snapshot, samples: samples, now: now)
        }
        // Spawned agents and guardians keep rollouts of their own that name the thread that started them; a session's
        // breakdown takes every rollout below it.
        var children: [String: [(id: String?, path: String)]] = [:]
        for session in indexed.sessions where session.transcript.isSubagent {
            if let parent = session.transcript.parentThreadID { children[parent, default: []].append((session.transcript.id, session.path)) }
        }
        func descendants(of id: String) -> [String] {
            var paths: [String] = [], queue = [id], seen: Set<String> = [id]
            while let next = queue.popLast() {
                for child in children[next] ?? [] {
                    paths.append(child.path)
                    if let childID = child.id, seen.insert(childID).inserted { queue.append(childID) }
                }
            }
            return paths.sorted()
        }
        let sessions = indexed.sessions.filter { !$0.transcript.isSubagent }.map { session in
            (session: session, live: SessionPhase.read(session.transcript.evidence, rule: .rollout, at: now).inFlight)
        }.sorted { a, b in
            if a.live != b.live { return a.live }
            return (a.session.transcript.lastActivityAt ?? .distantPast) > (b.session.transcript.lastActivityAt ?? .distantPast)
        }.map { session, live in
            let t = session.transcript
            return LiveSession(id: t.id!, agentId: "codex-model:\(t.model)",
                               task: session.title ?? t.task ?? t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                               terminal: t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                               startedAt: t.startedAt ?? session.modifiedAt,
                               endedAt: live ? nil : (t.lastActivityAt ?? session.modifiedAt),
                               pctOfWindow: nil, tokensIn: t.inputTokens,
                               tokensOut: t.outputTokens, client: t.client, transcriptPath: session.path,
                               cacheReadTokens: t.cachedInputTokens, observedAt: now, workingDirectory: t.cwd,
                               subagentTranscripts: descendants(of: t.id!), lastActivityAt: t.lastEventAt)
        }
        // An account's failed read is its own, on its observation. A home that failed before it was ever read is a notice
        // under Codex, and a pass that read no account at all is Codex's failed read.
        let unread = failures.filter { readings[$0.key] == nil }.map(\.value).sorted()
        let messages = (selected.compactMap { failures[$0.0] } + unread).sorted()
        let notice = messages.isEmpty ? nil : messages.joined(separator: " · ")
        let failed = selected.isEmpty ? notice.map { ["Codex": $0] } ?? [:] : [:]
        let sourceNotices = selected.isEmpty || unread.isEmpty ? failed : ["Codex": unread.joined(separator: " · ")]
        let consumerIds = Set(consumers.map(\.id) + sessions.map(\.agentId))
        // Pi's distinct account must not claim Codex transcript consumers. Pi owns its own token events.
        let nativeAccount = native?.limits.providerAccount(home: home).id
        var consumerIdsByQuota = Dictionary(uniqueKeysWithValues: windows.map {
            ($0.row.id, $0.row.account?.id == nativeAccount ? consumerIds : Set<String>())
        })
        for agent in agents where agent.vendor == "Codex" && agent.account == nil {
            consumerIdsByQuota[agent.id] = consumerIds
        }
        let observations = selected.map { source, reading in
            AccountObservation(account: reading.limits.providerAccount(home: source), home: source,
                label: reading.limits.account?.email, plan: reading.limits.plan, observedAt: reading.at,
                quotaNotice: failures[source], readingIssue: failures[source].map(ReadingIssue.readFailed),
                resetCredits: reading.limits.rateLimitResetCredits,
                aliases: reading.limits.partialKeys)
        }
        return UsageReport(generatedAt: now, snapshots: snapshots, sessions: sessions,
                           notice: notice, discoveredAgents: windows.map { $0.row.descriptor }, consumers: consumers,
                           indexing: indexed.indexing, insightsByAgent: byAgent,
                           subscriptions: native?.limits.plan.map { ["Codex": $0] } ?? [:],
                           sourceNotices: sourceNotices, quotaNotices: failed, readingIssues: failed.mapValues(ReadingIssue.readFailed),
                           consumerIdsByQuota: consumerIdsByQuota, codexResetCredits: selected.count == 1 ? selected.first?.1.limits.rateLimitResetCredits : nil,
                           codexResetCreditsObservedAt: selected.count == 1 && selected.first?.1.limits.rateLimitResetCredits != nil ? selected.first?.1.at : nil,
                           completions: indexed.sessions.flatMap { $0.transcript.completions ?? [] },
                           turns: indexed.sessions.flatMap { $0.transcript.sessionTurns },
                           accounts: lastRequestAt == nil || selected.isEmpty && !failures.isEmpty ? nil : ["Codex": observations])
    }
}
