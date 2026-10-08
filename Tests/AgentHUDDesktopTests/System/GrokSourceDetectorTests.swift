import Foundation
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class GrokSourceDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var sources: [SourceStatus] {
        [SourceStatus(id: "grok", name: "Grok CLI", detail: "CLI", state: .installed, provider: "Grok"),
         SourceStatus(id: "grok-bot", name: "Grok Bot", detail: "unsupported", state: .installed,
                      provider: "Grok", supportsLiveStatus: false)]
    }

    func testSharedAccountQuotaAndConsumersDoNotMakeEitherExecutionClientReady() {
        let window = AgentDescriptor(id: "grok", vendor: "Grok", model: "Plan", source: "fixture", enabled: true)
        let consumer = AgentDescriptor(id: "grok-model:grok-4", vendor: "Grok", model: "grok-4", source: "Grok CLI", enabled: true)
        let report = UsageReport(generatedAt: now, snapshots: [
            UsageSnapshot(agentId: window.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600), updatedAt: now),
        ], sessions: [], discoveredAgents: [window], consumers: [consumer], subscriptions: ["Grok": "supergrok"])
        XCTAssertEqual(SourceDetector.resolve(sources, report: report), sources)
    }

    func testActualCLISessionsMakeOnlyCLIReadyAndPreserveBotCapabilities() {
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session(client: "Grok CLI")])
        let resolved = SourceDetector.resolve(sources, report: report)
        XCTAssertEqual(resolved.map(\.state), [.ready(plan: nil), .installed])
        XCTAssertEqual(resolved.map(\.provider), ["Grok", "Grok"])
        XCTAssertEqual(resolved.map(\.supportsLiveStatus), [true, false])
        XCTAssertEqual(resolved[1], sources[1])
    }

    func testCachedBotSessionsMakeOnlyBotReadyWithoutAddingLiveStatus() {
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session(client: "Grok Bot")])
        let resolved = SourceDetector.resolve(sources, report: report)
        XCTAssertEqual(resolved.map(\.state), [.installed, .ready(plan: nil)])
        XCTAssertFalse(resolved[1].supportsLiveStatus)
    }

    func testOtherProvidersCannotBorrowCLIReadiness() {
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session(client: "Grok CLI", agent: "cursor-model:other")])
        XCTAssertEqual(SourceDetector.resolve(sources, report: report), sources)
    }

    func testOldGrokSessionsRemainCLIAndUnspecifiedSourcesKeepExistingDefaults() {
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session(client: nil)])
        XCTAssertEqual(SourceDetector.resolve(sources, report: report).map(\.state), [.ready(plan: nil), .installed])
        let existing = SourceStatus(id: "claude-code", name: "Claude", detail: "fixture", state: .installed)
        XCTAssertEqual(existing.provider, "Claude")
        XCTAssertTrue(existing.supportsLiveStatus)
        XCTAssertEqual(SourceDetector.resolve([existing], report: nil), [existing])
    }

    private func session(client: String?, agent: String = "grok-model:grok-4") -> LiveSession {
        LiveSession(id: "session", agentId: agent, task: "fixture", terminal: nil, startedAt: now,
                    pctOfWindow: nil, tokensIn: 0, tokensOut: 0, client: client)
    }
}
