import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// What the session card, the session page's header, the island and the Sessions page show for the same sessions.
final class SessionSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let consumers = [
        AgentDescriptor(id: "claude-model:opus", vendor: "Claude", model: "Opus", source: "", enabled: true),
        AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: true),
        AgentDescriptor(id: "grok-model:4", vendor: "Grok", model: "4", source: "", enabled: true),
    ]

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// The newest turn reported for the session, after an older finished one.
    private enum Newest: CaseIterable {
        case none, running, runningWithoutStart, waiting, completed, ended

        var state: SessionTurn.State? {
            switch self {
            case .none: return nil
            case .running, .runningWithoutStart: return .running
            case .waiting: return .waitingForApproval
            case .completed: return .completed
            case .ended: return .ended
            }
        }
    }

    /// Where a card's elapsed time counts from.
    private enum Since {
        case sessionStart, turnStart, turnHeard, reading, end
    }

    /// What each surface shows for one session.
    private struct Surfaces: Equatable {
        var cardDot: SessionDot
        var headerDot: SessionDot
        var islandDot: SessionDot
        var cardState: String?
        var cardSince: Date
        var headerLabel: String
    }

    /// The grid of the store's own tests: a Claude session that started five hours ago, has ended two hours ago unless
    /// the source still has it in flight, and was last read `age` seconds ago; its newest turn started three hours ago
    /// and was heard from half an hour later. The three dots always agree, the card and the header count from the same
    /// time, and a session the Mac can no longer vouch for is out of date on the card as on the header.
    @MainActor
    func testTheCardHeaderAndIslandForEachSession() throws {
        let store = try makeStore()
        let count = Newest.allCases.count
        func same<T>(_ value: T) -> [T] { Array(repeating: value, count: count) }
        let heard = [Since.reading] + Array(repeating: Since.turnHeard, count: count - 1)
        let running = "5h 00m running", ended = "ended 2h ago", off = "Live status off"
        // Live status, whether the source has the session in flight and how old its reading is; then, with each newest
        // turn in the order of `Newest.allCases`, the dot, the card's state, where its elapsed time counts from, and the
        // header's label.
        let rows: [(liveStatus: Bool, inFlight: Bool, age: TimeInterval, dot: [SessionDot], state: [String?], since: [Since],
                    header: [String])] = [
            (true, true, 1799.999, [.running, .running, .running, .waiting, .running, .running],
             ["Running", "Running", "Running", "Needs approval", "Running", "Running"],
             [.sessionStart, .turnStart, .sessionStart, .turnStart, .sessionStart, .sessionStart],
             [running, "3h 00m running", running, "Needs approval", running, running]),
            (true, true, 1800, same(.ended), same("Status out of date"), heard, same("Status out of date")),
            (true, false, 1799.999, same(.ended), same("Waiting for you"), same(.end), same(ended)),
            (true, false, 1800, same(.ended), same("Waiting for you"), same(.end), same(ended)),
            (false, true, 1799.999, same(.ended), same(nil), heard, same(off)),
            (false, true, 1800, same(.ended), same(nil), heard, same(off)),
            (false, false, 1799.999, same(.ended), same(nil), same(.end), same(off)),
            (false, false, 1800, same(.ended), same(nil), same(.end), same(off)),
        ]
        for row in rows {
            store.settings.update { $0.setLiveStatus(for: "Claude", enabled: row.liveStatus) }
            for (index, newest) in Newest.allCases.enumerated() {
                let session = session("s", ended: row.inFlight ? nil : -2 * hour, observed: -row.age)
                show([session], turns: gridTurns(of: "s", newest: newest), in: store)
                let since: Date = switch row.since[index] {
                case .sessionStart: session.startedAt
                case .turnStart: now.addingTimeInterval(-3 * hour)
                case .turnHeard: now.addingTimeInterval(-2.5 * hour)
                case .reading: session.observedAt
                case .end: now.addingTimeInterval(-2 * hour)
                }
                let expected = Surfaces(cardDot: row.dot[index], headerDot: row.dot[index], islandDot: row.dot[index],
                                        cardState: row.state[index], cardSince: since, headerLabel: row.header[index])
                XCTAssertEqual(surfaces(session, in: store), expected, "\(row) with the newest turn \(newest)")
            }
        }
    }

    /// A Stop hook that finishes a turn after the client's log went quiet dates the turn later than the session's end:
    /// the header and the card both count from that last event.
    @MainActor
    func testTheHeaderAndTheCardDateAnEndedSessionByItsLastEvent() throws {
        let store = try makeStore()
        let session = session("s", agent: "grok-model:4", ended: -2 * hour, observed: -60)
        show([session], turns: [turn("s", .completed, provider: "grok", started: -3 * hour, observed: -2 * hour + 10)], in: store)
        XCTAssertEqual(surfaces(session, in: store), Surfaces(
            cardDot: .ended, headerDot: .ended, islandDot: .ended, cardState: "Waiting for you",
            cardSince: now.addingTimeInterval(-2 * hour + 10), headerLabel: "ended 1h 59m ago"))
    }

    /// The island summarizes recent sessions — those with work in flight first, the ones waiting for the user ahead
    /// of the ones still running, and up to three ended after them — and counts every running one for the header. One still
    /// in flight that the Mac can no longer vouch for sits with the ended.
    @MainActor
    func testTheIslandListsWaitingThenRunningThenTheRecentlyEnded() throws {
        let store = try makeStore()
        let ended = (1...4).map { session("ended-\($0)", ended: -Double($0) * hour, observed: -Double($0) * hour) }
        let unvouched = session("unvouched", observed: -1800)
        let running = (1...4).map { session("running-\($0)", observed: -Double($0) * 60) }
        let waiting = turn("running-2", .waitingForApproval, started: -600, observed: -100)
        // The sessions shown; the running ones, which the header counts; the rows' dots; hidden active sessions.
        let cases: [(String, [LiveSession], shown: [String], running: Int, dots: [SessionDot], more: Int)] = [
            ("nothing running", ended + [unvouched],
             ["unvouched", "ended-1", "ended-2"], 0,
             [.ended, .ended, .ended], 0),
            ("four running", ended + [unvouched] + running,
             ["running-2", "running-1", "running-3", "running-4", "unvouched", "ended-1", "ended-2"], 4,
             [.waiting, .running, .running, .running, .ended, .ended, .ended], 0),
            ("two running", ended + Array(running.prefix(2)),
             ["running-2", "running-1", "ended-1", "ended-2", "ended-3"], 2,
             [.waiting, .running, .ended, .ended, .ended], 0),
        ]
        for (name, sessions, shown, count, dots, more) in cases {
            show(sessions, turns: [waiting], in: store)
            let rows = HoverPanelView.sessionRows(store)
            XCTAssertEqual(rows.shown.map(\.id), shown, name)
            XCTAssertEqual(rows.running.count, count, name)
            XCTAssertEqual(rows.shown.map { HoverPanelView.sessionDot($0, store: store) }, dots, name)
            XCTAssertEqual(rows.more, more, name)
        }
    }

    /// Active groups use creation order; ended rows follow the last event so resumed conversations stay recent.
    @MainActor
    func testTheIslandOrdersActiveByCreationAndEndedByLastEvent() throws {
        let store = try makeStore()
        show([
            session("running-old", started: -10 * hour, observed: -60),
            session("ended-new", started: -2 * hour, ended: -hour, observed: -hour),
            session("running-new", started: -hour, observed: -120),
            session("ended-old", started: -20 * hour, ended: -1800, observed: -1800),
            session("waiting-new", started: -30 * 60.0, observed: -100),
        ], turns: [turn("waiting-new", .waitingForApproval, started: -600, observed: -100)], in: store)
        let rows = HoverPanelView.sessionRows(store)
        XCTAssertEqual(rows.shown.map(\.id), ["waiting-new", "running-new", "running-old", "ended-old", "ended-new"])
        XCTAssertEqual(rows.running.count, 3)
        XCTAssertEqual(rows.more, 0)
    }

    /// Five active rows and three ended rows leave room for the account picture; only hidden active sessions count.
    @MainActor
    func testTheIslandKeepsSummariesSmallAndCountsOnlyHiddenActiveSessions() throws {
        let store = try makeStore()
        let ended: [LiveSession] = (0..<30).map { index in
            let offset = -Double(index + 1) * 60
            return session("ended-\(index)", started: offset, ended: offset, observed: offset)
        }
        let running: [LiveSession] = (0..<8).map { index in
            let offset = -Double(index + 1) * 60
            return session("running-\(index)", started: offset, observed: -60)
        }
        show(running + ended,
             turns: [turn("running-7", .waitingForApproval, started: -600, observed: -100)], in: store)
        let rows = HoverPanelView.sessionRows(store)
        XCTAssertEqual(rows.shown.count, HoverPanelView.activeSessionRowLimit + HoverPanelView.endedSessionRowLimit)
        XCTAssertEqual(rows.shown.map(\.id), ["running-7", "running-0", "running-1", "running-2", "running-3",
                                             "ended-0", "ended-1", "ended-2"])
        XCTAssertEqual(rows.more, 3)
        XCTAssertEqual(rows.running.count, 8)
    }

    @MainActor
    func testAccountWideReceiptsCannotDisplaceTheLocalBotSummaryButRemainInStatistics() throws {
        let store = try makeStore()
        let bots = (0..<3).map { index in
            session("bot-\(index)", agent: "grok-model:grok-4", started: -hour,
                    ended: -Double(index + 1) * 600, observed: -Double(index + 1) * 600, client: "Grok Bot")
        }
        let receipts = (0..<9).map { index in
            session("receipt-\(index)", agent: "cursor-model:api", started: -hour,
                    ended: -Double(index + 1), observed: -Double(index + 1), accountWide: true)
        }
        show(receipts + bots, in: store)
        let rows = HoverPanelView.sessionRows(store)
        XCTAssertEqual(rows.shown.map(\.id), bots.map(\.id))
        XCTAssertEqual(rows.running.count, 0)
        XCTAssertEqual(rows.more, 0)
        XCTAssertEqual(store.statsSessions.count, bots.count + receipts.count,
                       "Account-wide billing remains available in the full statistics list")
    }

    @MainActor
    func testASessionWithoutATerminalShowsItsTitleWithoutAPlaceholder() {
        let bot = session("New Bot working on the next task", observed: -60, client: "Grok Bot")
        XCTAssertEqual(HoverPanelView.sessionTitle(bot), bot.task)
        let local = LiveSession(id: "terminal-session", agentId: "claude-model:opus", task: "Fix auth bug in middleware",
                                terminal: "project", startedAt: now, pctOfWindow: nil, tokensIn: 0, tokensOut: 0)
        XCTAssertEqual(HoverPanelView.sessionTitle(local), "Fix auth bug · project")
    }

    /// A row's badge counts only the questions put to that exact session: another session's questions and a plain
    /// permission request on the same session stay off it.
    @MainActor
    func testOnlyQuestionsForTheSessionsOwnIDReachItsRow() {
        let session = session("s1", observed: -60)
        func request(_ id: String, _ sessionID: String, questions: [PermissionQuestion] = []) -> PermissionRequest {
            PermissionRequest(id: id, source: .claude, sessionID: sessionID, toolName: questions.isEmpty ? "Bash" : "AskUserQuestion",
                              summary: "Pick one", detail: nil, cwd: nil, questions: questions, at: now)
        }
        let question = request("q1", "s1", questions: [PermissionQuestion(question: "Pick one", options: [.init(label: "A")])])
        let waiting = [question, request("q2", "s2", questions: [PermissionQuestion(question: "Other", options: [.init(label: "B")])]),
                       request("p1", "s1")]
        XCTAssertEqual(HoverPanelView.questionRequests(for: session, waiting: waiting).map(\.id), ["q1"])
        XCTAssertEqual(HoverPanelView.questionRequests(for: session, waiting: []).map(\.id), [])
    }

    /// A day of the list holds the sessions last active on it, and a running session sits under today whenever it
    /// started; a session in flight that the Mac can no longer vouch for goes with its last event. Today starts open, the
    /// other days and the Earlier group, for sessions last active before the named days, start folded.
    @MainActor
    func testADayOfTheListHoldsTheSessionsLastActiveOnIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let store = try makeStore()
        // Now is 08:00 UTC.
        show([
            session("today", started: -2 * hour, ended: -hour, observed: -hour),
            session("yesterday-running", started: -20 * hour, observed: -60),
            session("last-week-running", started: -8 * 24 * hour, observed: -90),
            session("two-days-ago", started: -40 * hour, ended: -39 * hour, observed: -39 * hour),
            session("three-days-ago-unvouched", started: -60 * hour, observed: -30 * hour),
            session("seven-days-ago", started: -10 * 24 * hour, ended: -167 * hour, observed: -167 * hour),
        ], in: store)
        let today = calendar.startOfDay(for: now)
        let groups = SessionList.groups(store.listedSessions(source: nil, activeOnly: false), store: store, today: today, calendar: calendar)
        let days = [0, -1, -2].map { calendar.date(byAdding: .day, value: $0, to: today)! } + [.distantPast]
        XCTAssertEqual(groups.map(\.day), days)
        XCTAssertEqual(groups.map { $0.sessions.map(\.id) },
                       [["yesterday-running", "last-week-running", "today"], ["three-days-ago-unvouched"], ["two-days-ago"], ["seven-days-ago"]])
        let states = groups.map { SessionList.dayState($0.day, sessions: $0.sessions, today: today, store: store) }
        XCTAssertEqual(states.map(\.running), [2, 0, 0, 0])
        XCTAssertEqual(states.map(\.opens), [true, false, false, false])
    }

    /// The card above the list sums the sessions filed under today in either arrangement: last active today or in flight,
    /// one begun on an earlier day included, and one last active yesterday evening, though within the last 24 hours, not.
    @MainActor
    func testTheTodayCardSumsTheSessionsFiledUnderTodayInEitherArrangement() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let store = try makeStore()
        // Now is 08:00 UTC.
        show([
            session("today", started: -2 * hour, ended: -hour, observed: -hour),
            session("yesterday-running", started: -20 * hour, observed: -60),
            session("last-week-active-today", started: -8 * 24 * hour, ended: -3 * hour, observed: -3 * hour),
            session("yesterday-evening", started: -12 * hour, ended: -10 * hour, observed: -10 * hour),
        ], in: store)
        let today = calendar.startOfDay(for: now)
        for activeOnly in [false, true] {
            let listed = store.listedSessions(source: nil, activeOnly: activeOnly)
            XCTAssertTrue(listed.contains { $0.id == "yesterday-evening" })
            XCTAssertEqual(SessionList.filedToday(listed, store: store, today: today, calendar: calendar).map(\.id),
                           ["yesterday-running", "today", "last-week-active-today"], "active only: \(activeOnly)")
        }
    }

    /// The Sessions page counts the listed sessions that are running, by the source picked and the list shown; the island
    /// counts every running session.
    @MainActor
    func testThePageCountsTheListedSessionsThatAreRunning() throws {
        let store = try makeStore()
        store.settings.update { $0.setLiveStatus(for: "Codex", enabled: false) }
        show([
            session("running", observed: -60),
            session("waiting", observed: -60),
            session("unvouched", observed: -hour),
            session("codex-off", agent: "codex-model:gpt-5", observed: -60),
            session("ended", ended: -2 * hour, observed: -2 * hour),
            session("old", started: -30 * hour, ended: -26 * hour, observed: -26 * hour),
        ], turns: [turn("waiting", .waitingForApproval, started: -600, observed: -100)], in: store)
        let claude = SessionSource(vendor: "Claude", client: nil), codex = SessionSource(vendor: "Codex", client: nil)
        // The source picked and whether only active sessions are listed; how many are listed and how many run.
        let cases: [(SessionSource?, activeOnly: Bool, listed: Int, running: Int)] = [
            (nil, false, 6, 2), (nil, true, 5, 2), (claude, false, 5, 2), (claude, true, 4, 2), (codex, false, 1, 0),
        ]
        for (source, activeOnly, listed, running) in cases {
            let counts = StatsView.sessionCounts(store, source: source, activeOnly: activeOnly)
            XCTAssertEqual([counts.listed, counts.running], [listed, running], "\(source?.name ?? "all sources"), active only \(activeOnly)")
        }
        XCTAssertEqual(HoverPanelView.sessionRows(store).running.count, 2)
    }

    /// A session whose client waits for an answer to a permission request needs approval on every surface while it waits.
    @MainActor
    func testASessionWaitingOnAPermissionRequestNeedsApprovalOnEverySurface() throws {
        let store = try makeStore()
        // The demo's requests include one from Codex's session demo-2.
        PermissionRequests.shared.seedDemo(now: now)
        defer { for request in PermissionRequests.shared.pending { PermissionRequests.shared.withdraw(request.id) } }
        let codex = session("demo-2", agent: "codex-model:gpt-5", observed: -30)
        show([codex], turns: [turn("demo-2", .running, provider: "codex", started: -600, observed: -200)], in: store)
        XCTAssertEqual(surfaces(codex, in: store), Surfaces(
            cardDot: .waiting, headerDot: .waiting, islandDot: .waiting, cardState: "Needs approval",
            cardSince: now.addingTimeInterval(-600), headerLabel: "Needs approval"))
        XCTAssertEqual(HoverPanelView.sessionRows(store).running.map(\.id), ["demo-2"])
        XCTAssertEqual(StatsView.sessionCounts(store, source: nil, activeOnly: false).running, 1)
    }

    // MARK: Fixtures

    @MainActor
    private func surfaces(_ session: LiveSession, in store: UsageStore) -> Surfaces {
        let dot = SessionCard.dot(session, store: store)
        return Surfaces(cardDot: dot, headerDot: SessionDetailView.dot(session, store: store),
                        islandDot: HoverPanelView.sessionDot(session, store: store),
                        cardState: SessionCard.state(session, dot: dot, store: store),
                        cardSince: SessionCard.elapsedStart(session, store: store),
                        headerLabel: SessionDetailView.statusLabel(session, store: store))
    }

    /// An older finished turn, then the newest.
    private func gridTurns(of session: String, newest: Newest) -> [SessionTurn] {
        guard let state = newest.state else { return [] }
        return [turn(session, .completed, id: "1", started: -5 * hour, observed: -4 * hour),
                turn(session, state, id: "2", started: newest == .runningWithoutStart ? nil : -3 * hour, observed: -2.5 * hour)]
    }

    /// Times are seconds from now.
    private func session(_ id: String, agent: String = "claude-model:opus", started: TimeInterval = -5 * 3600, ended: TimeInterval? = nil,
                         observed: TimeInterval, client: String? = nil, accountWide: Bool = false) -> LiveSession {
        LiveSession(id: id, agentId: agent, task: id, terminal: nil, startedAt: now.addingTimeInterval(started),
                    endedAt: ended.map { now.addingTimeInterval($0) }, pctOfWindow: nil, tokensIn: 1, tokensOut: 1,
                    client: client, accountWide: accountWide, observedAt: now.addingTimeInterval(observed))
    }

    private func turn(_ session: String, _ state: SessionTurn.State, id: String = "1", provider: String = "claude", started: TimeInterval?,
                      observed: TimeInterval) -> SessionTurn {
        SessionTurn(provider: provider, sessionID: session, turnID: id, state: state, startedAtMs: started.map(milliseconds),
                    observedAtMs: milliseconds(observed))
    }

    private func milliseconds(_ offset: TimeInterval) -> Int64 {
        Int64(((now.timeIntervalSince1970 + offset) * 1000).rounded())
    }

    @MainActor
    private func show(_ sessions: [LiveSession], turns: [SessionTurn] = [], in store: UsageStore) {
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: sessions, consumers: consumers, turns: turns))
        store.now = now
    }

    @MainActor
    private func makeStore() throws -> UsageStore {
        let suite = "SessionSurfaceTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults))
    }
}
