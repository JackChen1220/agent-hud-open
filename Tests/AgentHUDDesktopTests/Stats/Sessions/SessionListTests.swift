import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

final class SessionListTests: XCTestCase {
    @MainActor
    func testActiveOnlyKeepsTheLastDayAndEarlierHoldsWhatStartedBeforeTheWeek() throws {
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
        let groups = SessionList.groups(week, store: store, today: Calendar.current.startOfDay(for: now), calendar: .current)
        XCTAssertEqual(groups.last?.day, .distantPast)
        XCTAssertEqual(groups.last?.sessions.map(\.id), ["running", "resumed"], "sessions that started before the week, newest activity first")
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
