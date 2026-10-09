import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class DockAnimationTests: XCTestCase {
    @MainActor
    func testEveryEdgeKeepsItsCanvasAndStationaryLogosThroughCollapseAndReopening() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        for edge in HUDEdge.allCases {
            let domain = "app.agenthud.tests.dock-animation.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
            settings.update {
                $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .logos, edge: edge, offset: 0.98)
                $0.showIslandQuota = true
                $0.showIslandTokens = false
                $0.showIslandSessions = false
                $0.collapseDelayMs = 5000
            }
            let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
            store.replace(report: DemoUsageProvider.report(agents: settings.agents,
                historyHours: UsageStore.historyHours, now: Date()))
            let hud = ScreenHUD(key: ScreenIdentity.key(for: screen), screen: screen, store: store, settings: settings)
            defer { hud.close() }
            let collapsed = hud.island.panel.frame
            let marks = hud.geometry.rect
            let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

            func checkPositions() throws {
                let root = hud.island.rootView
                let queue = globalFrame(try XCTUnwrap(root.logoQueueFrame), canvas: hud.island.panel.frame)
                assertFrame(queue, equals: marks, message: "\(edge): logos stay on their original screen coordinates")
                let card = globalFrame(try XCTUnwrap(root.presentationFrame), canvas: hud.island.panel.frame)
                switch edge {
                case .top: XCTAssertEqual(card.maxY, screen.frame.maxY, accuracy: 1)
                case .bottom: XCTAssertEqual(card.minY, screen.frame.minY, accuracy: 1)
                case .left: XCTAssertEqual(card.minX, screen.frame.minX, accuracy: 1)
                case .right: XCTAssertEqual(card.maxX, screen.frame.maxX, accuracy: 1)
                }
            }

            hud.forceOpen()
            try checkPositions()
            await settle()
            try checkPositions()
            let opened = hud.island.panel.frame
            XCTAssertGreaterThan(opened.width * opened.height, collapsed.width * collapsed.height)
            hud.forceCollapse()
            assertFrame(hud.island.panel.frame, equals: animates ? opened : collapsed,
                        message: "\(edge): closing keeps the canvas until its animation ends")
            try checkPositions()
            // Reversing before cleanup must cancel the old shrink, including on a bottom or side edge.
            hud.forceOpen()
            await settle()
            assertFrame(hud.island.panel.frame, equals: opened, message: "\(edge): reopening cancels cleanup")
            try checkPositions()
            settings.update { $0.showIslandQuota = false }
            hud.apply(animated: true)
            if animates {
                assertFrame(hud.island.panel.frame, equals: opened,
                            message: "\(edge): a shorter card uses the same transition canvas")
            }
            try checkPositions()
            await settle()
            XCTAssertLessThan(hud.island.panel.frame.height, opened.height)
            try checkPositions()
            hud.forceCollapse()
            await settle()
            assertFrame(hud.island.panel.frame, equals: collapsed, message: "\(edge): cleanup returns to the strip")
            try checkPositions()
        }
    }

    @MainActor
    func testChangingEdgeCancelsTheOldCoordinateSystemAndPendingCleanup() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.dock-edge-change.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0.screens[key] = ScreenPlacement(mode: .logos, edge: .right) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
        defer { hud.close() }
        hud.forceOpen()
        settings.update { $0.screens[key]?.edge = .bottom }
        hud.apply(animated: true)
        XCTAssertFalse(hud.island.rootView.animatesGeometry, "Changing edge replaces the canvas mapping immediately")
        let target = hud.island.panel.frame
        XCTAssertEqual(target.minY, screen.frame.minY, accuracy: 1)
        XCTAssertLessThan(target.width, screen.frame.width, "The old right-edge canvas must not be unioned into the new one")
        await settle()
        assertFrame(hud.island.panel.frame, equals: target, message: "Old cleanup must not move the new bottom panel")
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .seconds(IslandAnimation.duration + 0.08))
    }

    private func globalFrame(_ local: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + local.minX, y: canvas.maxY - local.maxY, width: local.width, height: local.height)
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect, message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, message, file: file, line: line)
    }
}
