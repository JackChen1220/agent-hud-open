import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class ScreenHUDPointerTests: XCTestCase {
    @MainActor
    func testHoverIncludesDisplayEdgesAndRejectsPointsOutsideTheVisibleTarget() {
        for region in [CGRect(x: 700, y: 1085, width: 216, height: 32),
                       CGRect(x: -2400, y: -100, width: 216, height: 32)] {
            for point in [CGPoint(x: region.midX, y: region.maxY),
                          CGPoint(x: region.maxX, y: region.midY),
                          CGPoint(x: region.minX, y: region.minY),
                          CGPoint(x: region.maxX, y: region.maxY)] {
                XCTAssertTrue(ScreenHUD.containsPointer(point, in: region))
            }
            for point in [CGPoint(x: region.midX, y: region.maxY + 1),
                          CGPoint(x: region.maxX + 1, y: region.midY),
                          CGPoint(x: region.minX - 1, y: region.midY),
                          CGPoint(x: region.midX, y: region.minY - 1)] {
                XCTAssertFalse(ScreenHUD.containsPointer(point, in: region))
            }
        }
        XCTAssertFalse(ScreenHUD.containsPointer(.zero, in: .zero))
    }

    @MainActor
    func testTopEdgeHoverSurvivesTrackingExitsAndCanOpenAgainAfterLeaving() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let domain = "app.agenthud.tests.pointer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update {
            $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .notch)
            $0.requiresOptionToOpen = false
            $0.hoverDelayMs = 0
            $0.collapseDelayMs = 0
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let pointer = TestPointerLocation(CGPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20))
        let hud = ScreenHUD(key: ScreenIdentity.key(for: screen), screen: screen, store: store,
                            settings: settings, mouseLocation: { pointer.point })
        defer { hud.close() }
        XCTAssertEqual(hud.geometry.mode, .notch)
        let top = CGPoint(x: hud.geometry.rect.midX, y: hud.geometry.rect.maxY)

        pointer.point = top
        hud.samplePointer()
        await settle()
        XCTAssertGreaterThan(hud.island.panel.frame.height, hud.geometry.islandFrame.height)

        // AppKit may send this while the hosting view is resized during expansion. The physical pointer
        // remains at the top of the HUD, so the event must not close it.
        let nativePointerChange = try XCTUnwrap(hud.island.onPointerChange)
        nativePointerChange(false)
        await settle()
        XCTAssertGreaterThan(hud.island.panel.frame.height, hud.geometry.islandFrame.height)

        pointer.point = CGPoint(x: hud.geometry.rect.midX, y: hud.geometry.screenFrame.minY + 20)
        hud.samplePointer()
        let deadline = Date().addingTimeInterval(5)
        while hud.island.panel.frame != hud.geometry.islandFrame, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(hud.island.panel.frame, hud.geometry.islandFrame)

        pointer.point = top
        hud.samplePointer()
        await settle()
        XCTAssertGreaterThan(hud.island.panel.frame.height, hud.geometry.islandFrame.height)
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .seconds(IslandAnimation.duration + 0.15))
    }
}

@MainActor
private final class TestPointerLocation {
    var point: CGPoint
    init(_ point: CGPoint) { self.point = point }
}
