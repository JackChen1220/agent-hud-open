import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// Preparing a future panel must leave the current windows alone and follow the hover's lifetime.
final class HoverPreparationLifecycleTests: XCTestCase {
    @MainActor
    func testPreparationKeepsTheCollapsedWindowsAndLeavingCancelsTheOpen() async throws {
        let fixture = try HoverPreparationFixture(quotaCount: 32)
        defer { fixture.close() }
        let hud = fixture.hud
        let collapsedFrame = hud.island.panel.frame
        let glowFrame = hud.glow.glowLayer.frame
        let shadowFrame = hud.glow.shadowLayer.frame
        let glowImage = try XCTUnwrap(hud.glow.glowLayer.contents) as AnyObject
        let shadowImage = try XCTUnwrap(hud.glow.shadowLayer.contents) as AnyObject

        fixture.enter()
        XCTAssertEqual(hud.island.panel.frame, collapsedFrame)
        XCTAssertEqual(hud.glow.glowLayer.frame, glowFrame)
        XCTAssertEqual(hud.glow.shadowLayer.frame, shadowFrame)
        XCTAssertTrue((hud.glow.glowLayer.contents as AnyObject?) === glowImage,
                      "Preparing the open glow must not replace the collapsed image")
        XCTAssertTrue((hud.glow.shadowLayer.contents as AnyObject?) === shadowImage,
                      "Preparing the open shadow must not replace the collapsed image")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hud.island.panel.frame, collapsedFrame)
        XCTAssertTrue((hud.glow.glowLayer.contents as AnyObject?) === glowImage)

        fixture.leave()
        // Wait past the cancelled deadline, without asserting a performance threshold.
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(hud.island.panel.frame, collapsedFrame,
                       "A hover that ended during preparation must not open later")
        XCTAssertEqual(hud.glow.glowLayer.frame, glowFrame)
        XCTAssertTrue((hud.glow.glowLayer.contents as AnyObject?) === glowImage)
    }

    @MainActor
    func testHoverDeadlineOpensAtTheCurrentMeasuredHeight() async throws {
        let fixture = try HoverPreparationFixture(quotaCount: 32)
        defer { fixture.close() }
        let expected = fixture.expectedHeight()

        fixture.enter()
        XCTAssertEqual(fixture.hud.island.panel.frame, fixture.hud.geometry.islandFrame)
        try await waitUntil("the delayed hover opens") {
            fixture.hud.island.panel.frame.height > fixture.hud.geometry.islandFrame.height
        }
        XCTAssertEqual(fixture.hud.island.panel.frame.height, expected, accuracy: 1,
                       "The first expanded window must use the prepared, bounded content height")
    }

    @MainActor
    func testSettingsChangedDuringTheDelayReplaceThePreparedHeight() async throws {
        let fixture = try HoverPreparationFixture(quotaCount: 32)
        defer { fixture.close() }
        let original = fixture.expectedHeight()
        fixture.enter()

        fixture.settings.update { $0.showIslandQuota = false }
        // The coordinator applies settings observations to every ScreenHUD through this entry point.
        fixture.hud.apply(animated: false)
        let expected = fixture.expectedHeight()
        XCTAssertLessThan(expected, original)
        XCTAssertEqual(fixture.hud.island.panel.frame, fixture.hud.geometry.islandFrame)

        try await waitUntil("the hover opens after its settings changed") {
            fixture.hud.island.panel.frame.height > fixture.hud.geometry.islandFrame.height
        }
        XCTAssertEqual(fixture.hud.island.panel.frame.height, expected, accuracy: 1,
                       "A prepared height from the previous settings must not be committed")
    }

    @MainActor
    func testReportChangedDuringTheDelayUsesTheNewSessionRowsHeight() async throws {
        let fixture = try HoverPreparationFixture(quotaCount: 4, showsTokens: true, showsSessions: true)
        defer { fixture.close() }
        let original = fixture.expectedHeight()
        fixture.enter()

        fixture.store.replace(report: fixture.report(consumerCount: 25, sessionCount: 12))
        fixture.hud.apply(animated: false)
        let expected = fixture.expectedHeight()
        XCTAssertGreaterThan(expected, original,
                             "The replacement report must actually change the panel's natural height")
        XCTAssertEqual(fixture.hud.island.panel.frame, fixture.hud.geometry.islandFrame)

        try await waitUntil("the hover opens after its report changed") {
            fixture.hud.island.panel.frame.height > fixture.hud.geometry.islandFrame.height
        }
        XCTAssertEqual(fixture.hud.island.panel.frame.height, expected, accuracy: 1,
                       "The first expanded frame must show the new report rather than its prepared predecessor")
    }

    @MainActor
    func testReportChangedWithoutACoordinatorApplyIsCheckedBeforeOpening() async throws {
        let fixture = try HoverPreparationFixture(quotaCount: 4, showsTokens: true, showsSessions: true)
        defer { fixture.close() }
        let original = fixture.expectedHeight()
        fixture.enter()

        fixture.store.replace(report: fixture.report(consumerCount: 25, sessionCount: 12))
        // Sessions can change without being part of the coordinator's observed inputs.
        let expected = fixture.expectedHeight()
        XCTAssertGreaterThan(expected, original)
        XCTAssertEqual(fixture.hud.island.panel.frame, fixture.hud.geometry.islandFrame)

        try await waitUntil("the hover opens after a report change without a coordinator apply") {
            fixture.hud.island.panel.frame.height > fixture.hud.geometry.islandFrame.height
        }
        XCTAssertEqual(fixture.hud.island.panel.frame.height, expected, accuracy: 1,
                       "Consuming preparation must validate the report even without an intervening apply")
    }

    @MainActor
    func testForceOpenCommitsAPendingHoverWithoutAnotherDelay() throws {
        let fixture = try HoverPreparationFixture(quotaCount: 8)
        defer { fixture.close() }
        let expected = fixture.expectedHeight()
        fixture.enter()
        XCTAssertEqual(fixture.hud.island.panel.frame, fixture.hud.geometry.islandFrame)

        fixture.hud.forceOpen()
        // No run-loop wait: explicit opening remains a synchronous commit.
        XCTAssertEqual(fixture.hud.island.panel.frame.height, expected, accuracy: 1)
    }

    @MainActor
    func testImmediateHoverPathsDoNotGainAPreparationDelay() async throws {
        for opensAtTop in [false, true] {
            let fixture = try HoverPreparationFixture(quotaCount: 8)
            defer { fixture.close() }
            fixture.settings.update {
                $0.hoverDelayMs = opensAtTop ? 1500 : 0
                $0.openImmediatelyAtTop = opensAtTop
            }
            fixture.hud.apply(animated: false)
            let expected = fixture.expectedHeight()
            fixture.enter(atTop: opensAtTop)
            if !opensAtTop {
                // A zero-delay hover retains the state machine's existing timer/run-loop transition.
                try await waitUntil("the zero-delay hover timer opens") {
                    fixture.hud.island.panel.frame.height > fixture.hud.geometry.islandFrame.height
                }
            }
            XCTAssertEqual(fixture.hud.island.panel.frame.height, expected, accuracy: 1,
                           opensAtTop ? "The immediate top edge must open in the same call"
                               : "Zero-delay hovering must open through its ordinary timer transition")
        }
    }

    @MainActor
    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(description)")
                throw HoverPreparationTimeout()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

@MainActor
private final class HoverPreparationFixture {
    let settings: SettingsStore
    let store: UsageStore
    let hud: ScreenHUD
    private let defaults: UserDefaults
    private let domain: String
    private let agents: [AgentDescriptor]
    private let pointer: HoverPreparationPointer
    private let outside: CGPoint

    init(quotaCount: Int, showsTokens: Bool = false, showsSessions: Bool = false) throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let domain = "app.agenthud.tests.hover-preparation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let agents = (0..<quotaCount).map {
            AgentDescriptor(id: "quota-\($0)", vendor: "Claude", model: "Quota \($0)",
                            source: "Test", enabled: true)
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update {
            $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .notch)
            $0.requiresOptionToOpen = false
            $0.openImmediatelyAtTop = false
            $0.hoverDelayMs = 1500
            $0.collapseDelayMs = 0
            $0.showIslandQuota = true
            $0.showIslandTokens = showsTokens
            $0.showIslandSessions = showsSessions
        }
        // Opening still requests an account refresh; keep the explicitly installed report authoritative.
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
        let outside = CGPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20)
        let pointer = HoverPreparationPointer(outside)
        self.defaults = defaults
        self.domain = domain
        self.agents = agents
        self.settings = settings
        self.store = store
        self.pointer = pointer
        self.outside = outside
        // Populate the store before constructing the HUD, without starting a real provider.
        store.replace(report: Self.report(agents: agents, consumerCount: showsTokens ? 1 : 0))
        hud = ScreenHUD(key: ScreenIdentity.key(for: screen), screen: screen, store: store,
                        settings: settings, mouseLocation: { pointer.point })
    }

    func enter(atTop: Bool = false) {
        pointer.point = CGPoint(x: hud.geometry.rect.midX,
                                y: atTop ? hud.geometry.screenFrame.maxY - 1 : hud.geometry.rect.midY)
        hud.samplePointer()
    }

    func leave() {
        pointer.point = outside
        hud.samplePointer()
    }

    func expectedHeight() -> CGFloat {
        let measured = NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {})
            .frame(width: IslandController.expandedWidth).fixedSize(horizontal: false, vertical: true))
        return max(80, min(measured.fittingSize.height.rounded(), hud.geometry.screenFrame.height - 80))
    }

    func report(consumerCount: Int, sessionCount: Int = 0) -> UsageReport {
        Self.report(agents: agents, consumerCount: consumerCount, sessionCount: sessionCount)
    }

    private static func report(agents: [AgentDescriptor], consumerCount: Int, sessionCount: Int = 0) -> UsageReport {
        let now = Date()
        let consumers = (0..<consumerCount).map {
            AgentDescriptor(id: "consumer-\($0)", vendor: "Claude", model: "Model \($0)",
                            source: "Test", enabled: true)
        }
        let usage = consumers.flatMap { consumer in
            (0..<24).map { hour in
                UsageBucket(start: now.addingTimeInterval(-Double(hour + 1) * 3600), agentId: consumer.id,
                            tokensIn: 10000, tokensOut: 1000)
            }
        }
        let sessions = (0..<sessionCount).map {
            LiveSession(id: "prep-session-\($0)", agentId: agents.first?.id ?? "consumer-0", task: "Task \($0)",
                        terminal: "proj", startedAt: now.addingTimeInterval(-Double($0 + 1) * 3600),
                        pctOfWindow: nil, tokensIn: 1000, tokensOut: 100, observedAt: now)
        }
        return UsageReport(generatedAt: now, snapshots: agents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600),
                          windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: sessions, discoveredAgents: agents, consumers: consumers, usage: usage)
    }

    func close() {
        hud.close()
        defaults.removePersistentDomain(forName: domain)
    }
}

@MainActor
private final class HoverPreparationPointer {
    var point: CGPoint
    init(_ point: CGPoint) { self.point = point }
}

private struct HoverPreparationTimeout: Error {}
