import XCTest
@testable import AgentHUDCore

final class LogoQueueVendorTests: XCTestCase {
    /// The queue is what is watched plus what has been used, and a vendor leaves it a day after its last turn.
    @MainActor
    func testQueueKeepsWatchedVendorsAndAddsOnesRunWithinTheDay() {
        let suite = "LogoQueueVendorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let watched = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "Sonnet", source: "", enabled: true)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [watched])
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        let recent = AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: false)
        let stale = AgentDescriptor(id: "grok-model:4", vendor: "Grok", model: "4", source: "", enabled: false)
        let sessions = [
            LiveSession(id: "recent", agentId: recent.id, task: "Task", terminal: nil,
                        startedAt: now.addingTimeInterval(-7200), endedAt: now.addingTimeInterval(-3600),
                        pctOfWindow: nil, tokensIn: 10, tokensOut: 2),
            LiveSession(id: "stale", agentId: stale.id, task: "Task", terminal: nil,
                        startedAt: now.addingTimeInterval(-2 * 86400), endedAt: now.addingTimeInterval(-2 * 86400 + 60),
                        pctOfWindow: nil, tokensIn: 10, tokensOut: 2),
        ]
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: sessions,
                                          consumers: [recent, stale], usage: []))
        store.now = now

        XCTAssertEqual(store.queueVendors.map(\.vendor), ["Claude", "Codex"],
                       "a vendor run within the day joins the watched ones; one last run two days ago does not")
        XCTAssertFalse(store.queueVendors.contains(where: \.isWorking), "every session here has ended")
    }

    /// A vendor's own sessions decide whether its mark bobs; its quota window's id never matches theirs.
    @MainActor
    func testAVendorWithARunningSessionIsWorking() {
        let suite = "LogoQueueVendorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let watched = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "Sonnet", source: "", enabled: true)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [watched])
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        let consumer = AgentDescriptor(id: "claude-model:opus", vendor: "Claude", model: "Opus", source: "", enabled: false)
        let running = LiveSession(id: "running", agentId: consumer.id, task: "Task", terminal: nil,
                                  startedAt: now.addingTimeInterval(-60), pctOfWindow: nil, tokensIn: 10, tokensOut: 2,
                                  observedAt: now)
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [running],
                                          consumers: [consumer], usage: []))
        store.now = now

        XCTAssertEqual(store.queueVendors.map(\.vendor), ["Claude"], "one mark for the vendor, not one per model")
        XCTAssertEqual(store.workingVendors, ["Claude"])
        XCTAssertTrue(store.queueVendors.allSatisfy(\.isWorking))
    }
}
