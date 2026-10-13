import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// The island and its glow in real windows: measured expansion, a stable canvas while the silhouette animates, and an
/// unclipped glow around tall panels.
final class IslandAnimationTests: XCTestCase {
    @MainActor
    func testIslandExpandsToMeasuredHeightAndKeepsItsCanvasWhileAnimating() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.animation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0.collapseDelayMs = 5000; $0.showIslandQuota = true; $0.showIslandTokens = false }
        // This measures the island against its glow, which is the notch's shape. A screen left on its own
        // default would run the logo queue instead, which draws no silhouette to measure.
        for screen in NSScreen.screens {
            settings.update { $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .notch) }
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let controller = IslandController(store: store, settings: settings)
        let window = controller.island.panel
        // A machine that reduces motion has no transition to cover, so the island resizes its canvas at once.
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        defer { window.orderOut(nil); controller.glow.panel.orderOut(nil) }
        await settle(0.1)

        func checkContour() throws {
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let x = rep.pixelsWide / 2
            let occupied = (0..<rep.pixelsHigh).filter { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.9 }
            let height = CGFloat(occupied.count) * view.bounds.height / CGFloat(rep.pixelsHigh)
            let glowLayer = controller.glow.glowLayer
            let visible = (glowLayer.presentation() ?? glowLayer).frame
            let glowHeight = visible.height - ceil(settings.settings.glowBlur * 3) * 2
                - settings.settings.glowRange - settings.settings.glowBlur * 3
            XCTAssertEqual(height, glowHeight, accuracy: 1, "The island and glow must settle to the same contour")
        }

        func measure() -> CGFloat {
            NSHostingView(rootView: HoverPanelView(store: store, onOpenStats: {}, navigation: controller.navigation)
                .environment(\.colorScheme, .dark)
                .frame(width: IslandController.expandedWidth).fixedSize(horizontal: false, vertical: true)).fittingSize.height.rounded()
        }

        let expectedHeight = measure()
        controller.forceOpen()
        XCTAssertEqual(window.frame.height, expectedHeight, "Opening must use the measured height immediately")
        for _ in 0..<8 {
            await settle(0.05)
            XCTAssertEqual(window.frame.height, expectedHeight, "Content measurement must not resize the canvas mid-animation")
        }
        await settle(0.1)
        try checkContour()

        controller.forceCollapse()
        await settle(0.1)
        XCTAssertEqual(window.frame.height, animates ? expectedHeight : controller.geometry.islandFrame.height,
                       "Closing must keep its canvas while the silhouette shrinks")
        controller.forceOpen()
        await settle(0.5)
        XCTAssertEqual(window.frame.height, expectedHeight, "Reopening must cancel the pending canvas shrink")

        settings.update { $0.showIslandQuota = false }
        await settle(0.1)
        let shorterHeight = max(80, measure())
        XCTAssertEqual(window.frame.height, animates ? expectedHeight : shorterHeight,
                       "Live content changes must keep the transition canvas")
        await settle(0.5)
        XCTAssertEqual(window.frame.height, shorterHeight, "Live content height must settle to its measured target")
        controller.forceCollapse()
        await settle(0.5)
        XCTAssertEqual(window.frame, controller.geometry.islandFrame, "Closing must finish at the notch frame")
        try checkContour()
    }

    @MainActor
    func testTallPanelsKeepTheWholeGlowOnScreen() async throws {
        _ = NSApplication.shared
        for screenHeight: CGFloat in [900, 1117, 1440] {
            let screen = CGRect(x: -20000, y: -20000, width: 1728, height: screenHeight)
            let geometry = NotchGeometry(screenFrame: screen, mode: .notch, edge: .top, hasNotch: true,
                rect: CGRect(x: screen.midX - 108, y: screen.maxY - 32, width: 216, height: 32),
                cornerRadius: 12, backingScale: 2, menuBarHeight: 24)
            let controller = GlowWindowController(geometry: geometry)
            defer { controller.panel.orderOut(nil) }
            let canvas = controller.panel.frame
            let maximum = Settings.glowSizeRange.upperBound

            func update(height: CGFloat, animated: Bool) {
                let island = geometry.expandedFrame(size: CGSize(width: IslandController.expandedWidth, height: height))
                // The controller shrinks a glow that would not fit the screen; the test drives the same path.
                let glow = GlowGeometry.compute(islandWidth: island.width, islandHeight: island.height,
                    islandRadius: IslandController.expandedRadius, range: maximum, blur: maximum)
                    .fitted(within: screenHeight)
                controller.update(geometry: geometry, island: island, islandRadius: IslandController.expandedRadius,
                    glow: glow, outwardOnly: true, appearance: .idle(), animated: animated)
            }

            func checkClipping() throws {
                XCTAssertEqual(controller.panel.frame, canvas, "The glow canvas must stay fixed during expansion and collapse")
                let host = try XCTUnwrap(controller.panel.contentView)
                for layer in [controller.shadowLayer, controller.glowLayer] {
                    let frame = (layer.presentation() ?? layer).frame
                    // Only the part above the display's top edge may be clipped.
                    XCTAssertTrue(frame.minY >= host.bounds.minY - 0.01 && frame.minX >= host.bounds.minX
                        && frame.maxX <= host.bounds.maxX, "Tall panels must keep the full bottom glow and shadow (\(screenHeight) pt screen)")
                }
            }

            update(height: screenHeight - 80, animated: false)
            try checkClipping()
            update(height: IslandController.defaultPanelHeight, animated: true)
            await settle(0.1)
            try checkClipping()
            update(height: screenHeight - 80, animated: true)
            await settle(IslandAnimation.duration + 0.1)
            try checkClipping()
        }
    }

    @MainActor
    func testAGlowThatClosesStopsItsFrames() throws {
        _ = NSApplication.shared
        let screen = CGRect(x: -20000, y: -20000, width: 1728, height: 1117)
        let geometry = NotchGeometry(screenFrame: screen, mode: .notch, edge: .top, hasNotch: true,
            rect: CGRect(x: screen.midX - 108, y: screen.maxY - 32, width: 216, height: 32),
            cornerRadius: 12, backingScale: 2, menuBarHeight: 24)
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.panel.orderOut(nil) }
        let breathing = GlowAppearance(stops: GlowGradient.idleStops, peakOpacity: 0.9, troughOpacity: 0.4, breathing: true,
                                       breathSeconds: 3, hidden: false)
        controller.update(geometry: geometry, island: geometry.rect, islandRadius: 12,
            glow: GlowGeometry.compute(islandWidth: 216, islandHeight: 32, islandRadius: 12, range: 14, blur: 8),
            outwardOnly: true, appearance: breathing, animated: false, pattern: GlowPattern(style: .dots, effect: .flow))
        try XCTSkipUnless(controller.isAnimating, "motion is reduced on this Mac, so no frames run")
        controller.close()
        XCTAssertFalse(controller.isAnimating, "a HUD whose display went away draws no more frames")
        XCTAssertFalse(controller.panel.isVisible)
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
