import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

final class SessionListTests: XCTestCase {
    /// The project is the recorded path, shared across clients. Every list surface uses the same combined filter.
    @MainActor
    func testProjectSearchAndSourceFiltersAgreeWithCountsAndKeepLocalUsage() throws {
        let suite = "SessionListTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: []))
        let now = store.now, home = FileManager.default.homeDirectoryForCurrentUser.path
        let personal = home + "/Projects/web", client = home + "/Clients/web"
        func session(_ id: String, agent: String = "codex", task: String, path: String?, tokens: Int, endedHoursAgo: Double? = nil) -> LiveSession {
            LiveSession(id: id, agentId: agent, task: task, terminal: "web", startedAt: now.addingTimeInterval(-40 * 3600),
                        endedAt: endedHoursAgo.map { now.addingTimeInterval(-$0 * 3600) }, pctOfWindow: nil,
                        tokensIn: tokens, tokensOut: 0, observedAt: now, workingDirectory: path)
        }
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [
            session("personal-codex", task: "Review cache attribution", path: personal, tokens: 12),
            session("personal-claude", agent: "claude", task: "Implement search", path: personal, tokens: 23),
            session("client", task: "Review cache attribution", path: client, tokens: 34),
            session("unknown", task: "Local draft", path: nil, tokens: 45),
            session("older", task: "Previous change", path: personal, tokens: 56, endedHoursAgo: 30),
        ]))
        store.now = now
        let range = store.statsRange, dimensions = store.tokenDimensions, bucket = store.tokenBucketSize
        func listed(project: SessionProject? = nil, search: String = "", source: SessionSource? = nil, activeOnly: Bool = false) -> [LiveSession] {
            store.listedSessions(source: source, activeOnly: activeOnly, project: project, search: search)
        }
        let codex = SessionSource(vendor: "Codex", client: nil)
        XCTAssertEqual(Set(listed(project: .directory(personal)).map(\.id)), ["personal-codex", "personal-claude", "older"])
        XCTAssertEqual(listed(project: .directory(client)).map(\.id), ["client"], "same folder name, different physical path")
        XCTAssertEqual(listed(project: .unassigned).map(\.id), ["unknown"], "the terminal's folder name does not invent a project path")
        XCTAssertEqual(listed(project: .directory(personal), search: "review", source: codex).map(\.id), ["personal-codex"])
        XCTAssertEqual(listed(project: .directory(client), search: "implement").map(\.id), [])
        XCTAssertEqual(Set(listed(search: "~/Projects/web").map(\.id)), ["personal-codex", "personal-claude", "older"])
        XCTAssertEqual(listed(search: "  LOCAL DRAFT  ").map(\.id), ["unknown"])
        let active = listed(project: .directory(personal), activeOnly: true)
        XCTAssertEqual(Set(active.map(\.id)), ["personal-codex", "personal-claude"])
        let counts = StatsView.sessionCounts(store, source: nil, activeOnly: true, project: .directory(personal))
        XCTAssertEqual(counts.listed, active.count)
        XCTAssertEqual(counts.running, 2)
        let all = listed()
        XCTAssertEqual(all.count, 5, "clearing the local filters restores the whole list")
        XCTAssertEqual(all.reduce(0) { $0 + store.sessionTokens($1).total }, 170, "no signed-in quota account is needed to count local usage")
        XCTAssertEqual(store.statsRange, range, "list filters do not change the chart's range")
        XCTAssertEqual(store.tokenDimensions, dimensions)
        XCTAssertEqual(store.tokenBucketSize, bucket)
    }

    @MainActor
    func testActiveOnlyKeepsTheLastDayAndEachDayHoldsWhatWasLastActiveOnIt() throws {
        let suite = "SessionListTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: []))
        let now = store.now
        func session(_ id: String, startedHoursAgo: Double, endedHoursAgo: Double? = nil) -> LiveSession {
            LiveSession(id: id, agentId: "codex", task: id, terminal: nil,
                        startedAt: now.addingTimeInterval(-startedHoursAgo * 3600),
                        endedAt: endedHoursAgo.map { now.addingTimeInterval(-$0 * 3600) },
                        pctOfWindow: nil, tokensIn: 0, tokensOut: 0, observedAt: now)
        }
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [
            session("running", startedHoursAgo: 240),
            session("recent", startedHoursAgo: 10, endedHoursAgo: 2),
            session("resumed", startedHoursAgo: 240, endedHoursAgo: 20),
            session("quiet", startedHoursAgo: 40, endedHoursAgo: 30),
        ]))
        XCTAssertEqual(store.listedSessions(source: nil, activeOnly: true).map(\.id), ["running", "recent", "resumed"])
        let week = store.listedSessions(source: nil, activeOnly: false)
        XCTAssertEqual(week.map(\.id), ["running", "recent", "resumed", "quiet"])
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        let groups = SessionList.groups(week, store: store, today: today, calendar: calendar)
        let days = Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.sessions.map { ($0.id, group.day) } })
        XCTAssertEqual(days["running"], today, "a running session sits under today, however long ago it started")
        XCTAssertEqual(days["recent"], calendar.startOfDay(for: now.addingTimeInterval(-2 * 3600)))
        XCTAssertEqual(days["resumed"], calendar.startOfDay(for: now.addingTimeInterval(-20 * 3600)),
                       "a session that started before the week sits under the day it was last active")
        XCTAssertEqual(days["quiet"], calendar.startOfDay(for: now.addingTimeInterval(-30 * 3600)))
        XCTAssertFalse(groups.contains { $0.day == .distantPast }, "nothing active in the named days falls into Earlier")
    }

    /// Active only keeps a session whose last event is exactly a day old and drops one a millisecond older. A running
    /// session stays whatever its last event; one in flight that the Mac can no longer vouch for, or whose live status is
    /// off, goes with its last event.
    @MainActor
    func testActiveOnlyKeepsASessionLastActiveExactlyADayAgo() throws {
        let suite = "SessionListTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: []))
        store.settings.update { $0.setLiveStatus(for: "Codex", enabled: false) }
        let now = Date(timeIntervalSince1970: 1_800_000_000), day: TimeInterval = 86_400
        func session(_ id: String, agent: String = "claude-model:opus", ended: TimeInterval? = nil, observed: TimeInterval) -> LiveSession {
            LiveSession(id: id, agentId: agent, task: id, terminal: nil, startedAt: now.addingTimeInterval(-2 * day),
                        endedAt: ended.map { now.addingTimeInterval($0) }, pctOfWindow: nil, tokensIn: 0, tokensOut: 0,
                        observedAt: now.addingTimeInterval(observed))
        }
        let heardADayAndAnHourAgo = Int64((now.timeIntervalSince1970 - day - 3600) * 1000)
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [
            session("edge", ended: -day, observed: -day),
            session("late", ended: -day - 0.001, observed: -day),
            session("running", observed: -60),
            session("unvouched", observed: -7200),
            session("live-status-off", agent: "codex-model:gpt-5", observed: -60),
        ], turns: ["running", "unvouched", "live-status-off"].map {
            SessionTurn(provider: $0 == "live-status-off" ? "codex" : "claude", sessionID: $0, turnID: "1", state: .running,
                        startedAtMs: nil, observedAtMs: heardADayAndAnHourAgo)
        }))
        store.now = now
        XCTAssertEqual(store.listedSessions(source: nil, activeOnly: true).map(\.id), ["edge", "running"])
    }
}
