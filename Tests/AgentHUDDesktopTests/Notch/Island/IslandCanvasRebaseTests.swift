import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class IslandCanvasRebaseTests: XCTestCase {
    @MainActor
    func testShrinkingTheCanvasAfterCollapseDoesNotAnimateTheContourAgain() async throws {
        _ = NSApplication.shared
        let canvas = CGRect(x: -20000, y: -20000, width: 572, height: 500)
        let collapsedSize = CGSize(width: 216, height: 32)
        var root = IslandRootView(store: nil, isOpen: true, collapsedSize: collapsedSize,
                                  collapsedTopRadius: 16, collapsedBottomRadius: 12,
                                  lightBorder: false, onOpenStats: {})
        root.presentationSize = canvas.size
        root.presentationFrame = CGRect(origin: .zero, size: canvas.size)
        root.animatesGeometry = false
        let controller = IslandWindowController(frame: canvas, rootView: root)
        controller.show()
        defer { controller.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(80))

        root = IslandRootView(store: nil, isOpen: false, collapsedSize: collapsedSize,
                              collapsedTopRadius: 16, collapsedBottomRadius: 12,
                              lightBorder: false, onOpenStats: {})
        root.animatesGeometry = true
        root.presentationSize = collapsedSize
        root.presentationFrame = CGRect(x: (canvas.width - collapsedSize.width) / 2, y: 0,
                                        width: collapsedSize.width, height: collapsedSize.height)
        controller.setRootView(root)
        try await Task.sleep(for: .seconds(IslandAnimation.duration + 0.08))
        let baseline = try visibleContour(controller)
        XCTAssertGreaterThan(baseline.width, 200, "The baseline must contain the whole collapsed silhouette")
        XCTAssertEqual(baseline.height, collapsedSize.height, accuracy: 1)

        controller.setFrame(CGRect(x: canvas.midX - collapsedSize.width / 2,
                                   y: canvas.maxY - collapsedSize.height,
                                   width: collapsedSize.width, height: collapsedSize.height))
        try await Task.sleep(for: .milliseconds(20))
        assertContour(try visibleContour(controller), equals: baseline,
                      "Canvas cleanup must not clip or restart the settled contour")
        try await Task.sleep(for: .milliseconds(50))
        assertContour(try visibleContour(controller), equals: baseline,
                      "The contour must stay fixed through the next animation frames")
        try await Task.sleep(for: .seconds(IslandAnimation.duration + 0.08))
        assertContour(try visibleContour(controller), equals: baseline,
                      "Cleanup must retain the same screen position after settling")
    }

    @MainActor
    func testGrowingTheNativeCanvasKeepsTheCollapsedContourAtItsScreenPosition() async throws {
        _ = NSApplication.shared
        let collapsed = CGRect(x: -20000, y: -20000, width: 216, height: 32)
        var root = IslandRootView(store: nil, isOpen: false, collapsedSize: collapsed.size,
                                  collapsedTopRadius: 16, collapsedBottomRadius: 12,
                                  lightBorder: false, onOpenStats: {})
        root.presentationSize = collapsed.size
        root.presentationFrame = CGRect(origin: .zero, size: collapsed.size)
        root.animatesGeometry = true
        let controller = IslandWindowController(frame: collapsed, rootView: root)
        controller.show()
        defer { controller.panel.orderOut(nil) }
        try await Task.sleep(for: .seconds(IslandAnimation.duration + 0.08))
        let baseline = try visibleContour(controller)

        controller.setFrame(CGRect(x: collapsed.midX - 572 / 2, y: collapsed.maxY - 500,
                                   width: 572, height: 500))
        try await Task.sleep(for: .milliseconds(20))
        assertContour(try visibleContour(controller), equals: baseline,
                      "Adding a transition canvas must not move the existing silhouette")
        try await Task.sleep(for: .seconds(IslandAnimation.duration + 0.08))
        assertContour(try visibleContour(controller), equals: baseline,
                      "Rebasing the larger canvas must not start a delayed move")
    }

    @MainActor
    func testShrinkingOnlyTheQueueReleasesTheCanvasAfterTheCardAnimation() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        for changesDuringOpening in [false, true] {
            if changesDuringOpening && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { continue }
            let domain = "app.agenthud.tests.queue-canvas.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let agents = (0..<32).map {
                AgentDescriptor(id: "quota-\($0)", vendor: "Synthetic \($0)", model: "Quota",
                                source: "Test", enabled: true)
            }
            let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
            settings.update {
                $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .logos, edge: .left, offset: 0.5)
                $0.showIslandQuota = false
                $0.showIslandTokens = false
                $0.showIslandSessions = false
                $0.requiresOptionToOpen = false
            }
            let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
            store.glowHidden = true
            let now = Date()
            store.replace(report: UsageReport(generatedAt: now, snapshots: agents.map {
                UsageSnapshot(agentId: $0.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600),
                              windowDuration: 5 * 3600, updatedAt: now)
            }, sessions: [], discoveredAgents: agents, consumers: []))
            let hud = ScreenHUD(key: ScreenIdentity.key(for: screen), screen: screen, store: store,
                                settings: settings, mouseLocation: { CGPoint(x: screen.frame.maxX, y: screen.frame.minY) })
            defer { hud.close() }
            try await Task.sleep(for: .milliseconds(80))
            hud.forceOpen()
            try await Task.sleep(for: .seconds(changesDuringOpening ? 0.12 : IslandAnimation.duration + 0.2))
            let canvas = hud.island.panel.frame
            let localCard = try XCTUnwrap(hud.island.rootView.presentationFrame)
            let card = CGRect(x: canvas.minX + localCard.minX, y: canvas.maxY - localCard.maxY,
                              width: localCard.width, height: localCard.height)
            XCTAssertGreaterThan(canvas.height, card.height + 100, "The initial queue must actually require a long canvas")

            settings.updateAgents { _ in Array(agents.prefix(2)) }
            hud.apply(animated: true)
            if changesDuringOpening {
                XCTAssertEqual(hud.island.panel.frame, canvas,
                               "A queue update must not clip the card's still-running expansion")
            } else {
                assertContour(hud.island.panel.frame, equals: card,
                              "A settled card must release the old queue canvas without awaiting a new card animation")
            }
            let deadline = Date().addingTimeInterval(3)
            while abs(hud.island.panel.frame.height - card.height) > 1, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            assertContour(hud.island.panel.frame, equals: card,
                          "The current card's completion must release the latest queue target")
        }
    }

    @MainActor
    private func visibleContour(_ controller: IslandWindowController) throws -> CGRect {
        let view = try XCTUnwrap(controller.panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            XCTFail("The rendered black silhouette disappeared")
            throw MissingContour()
        }
        let xScale = view.bounds.width / CGFloat(bitmap.pixelsWide)
        let yScale = view.bounds.height / CGFloat(bitmap.pixelsHigh)
        // Cached bitmap rows run down from the hosting view's top; screen coordinates run upward.
        return CGRect(x: controller.panel.frame.minX + CGFloat(minX) * xScale,
                      y: controller.panel.frame.maxY - CGFloat(maxY + 1) * yScale,
                      width: CGFloat(maxX - minX + 1) * xScale,
                      height: CGFloat(maxY - minY + 1) * yScale)
    }

    private func assertContour(_ actual: CGRect, equals expected: CGRect, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, message, file: file, line: line)
    }
}

private struct MissingContour: Error {}
