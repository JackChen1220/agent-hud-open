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
    func testImmediateTopEdgeIsLimitedToTheHUDOnEachDisplay() {
        for screen in [CGRect(x: 0, y: 0, width: 1600, height: 900),
                       CGRect(x: -1600, y: -200, width: 1600, height: 900)] {
            let rect = CGRect(x: screen.midX - 108, y: screen.maxY - 32, width: 216, height: 32)
            for edge in [HUDEdge.top, .bottom, .left, .right] {
                let geometry = NotchGeometry(screenFrame: screen, mode: .notch, edge: edge, hasNotch: false,
                                             rect: rect, cornerRadius: 12, backingScale: 2, menuBarHeight: 32)
                for y in [screen.maxY, screen.maxY - 1] {
                    XCTAssertEqual(ScreenHUD.pointerTouchesTop(CGPoint(x: rect.midX, y: y), geometry: geometry), edge == .top)
                }
                for point in [CGPoint(x: rect.midX, y: screen.maxY - 2),
                              CGPoint(x: rect.midX, y: screen.maxY + 1),
                              CGPoint(x: rect.minX - 1, y: screen.maxY),
                              CGPoint(x: rect.maxX + 1, y: screen.maxY)] {
                    XCTAssertFalse(ScreenHUD.pointerTouchesTop(point, geometry: geometry))
                }
            }
        }
    }

    @MainActor
    func testTopEdgeOptionSkipsOnlyTheOpenDelayAndRespectsManualCollapse() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let domain = "app.agenthud.tests.top-edge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update {
            $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .notch)
            $0.requiresOptionToOpen = false
            $0.hoverDelayMs = 1500
            $0.collapseDelayMs = 0
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let pointer = TestPointerLocation(CGPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20))
        let hud = ScreenHUD(key: ScreenIdentity.key(for: screen), screen: screen, store: store,
                            settings: settings, mouseLocation: { pointer.point })
        defer { hud.close() }
        let ordinary = CGPoint(x: hud.geometry.rect.midX, y: hud.geometry.rect.midY)
        let top = CGPoint(x: hud.geometry.rect.midX, y: hud.geometry.screenFrame.maxY - 1)
        let outside = pointer.point

        pointer.point = ordinary
        hud.samplePointer()
        XCTAssertEqual(hud.island.panel.frame, hud.geometry.islandFrame)
        pointer.point = top
        hud.samplePointer()
        XCTAssertEqual(hud.island.panel.frame, hud.geometry.islandFrame, "The disabled option keeps the ordinary delay")

        settings.update { $0.openImmediatelyAtTop = true }
        hud.samplePointer()
        // No timer or run-loop wait: enabling the option finishes the already-pending hover immediately.
        XCTAssertGreaterThan(hud.island.panel.frame.height, hud.geometry.islandFrame.height)
        await settle()
        hud.forceCollapse()
        await waitForCollapse(hud)
        hud.samplePointer()
        XCTAssertEqual(hud.island.panel.frame, hud.geometry.islandFrame, "A handoff remains closed until the pointer leaves")

        pointer.point = outside
        hud.samplePointer()
        pointer.point = ordinary
        hud.samplePointer()
        XCTAssertEqual(hud.island.panel.frame, hud.geometry.islandFrame, "Ordinary hovering still waits even with the option enabled")
        pointer.point = top
        hud.samplePointer()
        XCTAssertGreaterThan(hud.island.panel.frame.height, hud.geometry.islandFrame.height)
        XCTAssertEqual(settings.settings.hoverDelayMs, 1500)
        XCTAssertEqual(settings.settings.collapseDelayMs, 0)
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
        await waitForCollapse(hud)

        pointer.point = top
        hud.samplePointer()
        await settle()
        XCTAssertGreaterThan(hud.island.panel.frame.height, hud.geometry.islandFrame.height)
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .seconds(IslandAnimation.duration + 0.15))
    }

    @MainActor
    private func waitForCollapse(_ hud: ScreenHUD) async {
        let deadline = Date().addingTimeInterval(5)
        while hud.island.panel.frame != hud.geometry.islandFrame, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(hud.island.panel.frame, hud.geometry.islandFrame)
    }
}

@MainActor
private final class TestPointerLocation {
    var point: CGPoint
    init(_ point: CGPoint) { self.point = point }
}
