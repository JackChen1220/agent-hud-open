import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class HoverPanelLayoutTests: XCTestCase {
    @MainActor
    func testLongContentScrollsAboveAFixedFooterAndReportsItsNaturalHeight() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.panel-layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let agents = (0..<32).map {
            AgentDescriptor(id: "quota-\($0)", vendor: "Claude", model: "Quota \($0)", source: "Test", enabled: true)
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update {
            $0.showIslandQuota = true
            $0.showIslandTokens = false
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        store.replace(report: UsageReport(generatedAt: now, snapshots: agents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600),
                          windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: []))

        let observation = HeightObservation()
        let width = IslandController.expandedWidth + 2 * NotchGeometry.expandedTopRadius
        let cap: CGFloat = 320
        var root = IslandRootView(store: store, isOpen: true, collapsedSize: CGSize(width: 216, height: 32),
                                  collapsedTopRadius: 16, collapsedBottomRadius: 12,
                                  lightBorder: false, onOpenStats: {},
                                  additionalHUDControls: { AnyView(FooterMarker().frame(width: 16, height: 28)) })
        root.presentationSize = CGSize(width: width, height: cap)
        root.animatesGeometry = false
        root.onContentHeight = { observation.value = $0 }
        let controller = IslandWindowController(
            frame: CGRect(x: -20000, y: -20000, width: width, height: cap), rootView: root)
        let window = controller.panel
        let hosting = try XCTUnwrap(window.contentView)
        controller.show()
        defer { window.orderOut(nil) }

        try await waitUntil("the long panel lays out its overflowing content", hosting: hosting) {
            guard let scroll = self.firstScrollView(in: hosting), let document = scroll.documentView else { return false }
            return observation.value > cap && document.bounds.height > scroll.contentView.bounds.height + 100
                && self.footerMarker(in: hosting) != nil
        }
        let scroll = try XCTUnwrap(firstScrollView(in: hosting))
        let document = try XCTUnwrap(scroll.documentView)
        let marker = try XCTUnwrap(footerMarker(in: hosting))
        let footerBefore = marker.convert(marker.bounds, to: hosting)
        XCTAssertNil(marker.enclosingScrollView, "Footer controls must remain outside the scrolling content")
        XCTAssertTrue(hosting.bounds.contains(footerBefore), "The footer must stay within the visible panel")
        XCTAssertEqual(window.frame.height, cap, accuracy: 1)
        let naturalHeight = controller.contentHeight(for: root)
        XCTAssertGreaterThan(naturalHeight, cap + 100, "Natural measurement must ignore the presentation height")
        XCTAssertEqual(observation.value, naturalHeight, accuracy: 2,
                       "Height preferences must report all natural content, rather than the capped viewport")

        let previousOffset = scroll.contentView.bounds.origin.y
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil("the panel reaches the bottom of its content", hosting: hosting) {
            abs(scroll.contentView.bounds.origin.y - bottom) < 1
        }
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, previousOffset)
        let footerAfter = marker.convert(marker.bounds, to: hosting)
        XCTAssertEqual(footerAfter.minY, footerBefore.minY, accuracy: 1, "Scrolling must not move the footer")
        XCTAssertEqual(footerAfter.minX, footerBefore.minX, accuracy: 1)
        XCTAssertEqual(footerAfter.height, footerBefore.height, accuracy: 1)

        // SwiftUI updates the content while the window remains capped. Its preference must still report the
        // shorter natural height, so the owner can shrink the window instead of retaining an empty viewport.
        settings.update { $0.showIslandQuota = false }
        try await waitUntil("shorter content reports a height below the cap", hosting: hosting) {
            observation.value > 0 && observation.value < cap - 100
        }
        let shorterHeight = controller.contentHeight(for: root).rounded()
        XCTAssertEqual(observation.value, shorterHeight, accuracy: 2)
        XCTAssertLessThan(shorterHeight, naturalHeight)
        root.presentationSize = CGSize(width: width, height: shorterHeight)
        controller.setRootView(root)
        controller.setFrame(CGRect(x: -20000, y: -20000, width: width, height: shorterHeight))
        try await waitUntil("the shorter panel restores its natural height", hosting: hosting) {
            guard let scroll = self.firstScrollView(in: hosting), let document = scroll.documentView,
                  let marker = self.footerMarker(in: hosting) else { return false }
            return document.bounds.height <= scroll.contentView.bounds.height + 1
                && hosting.bounds.contains(marker.convert(marker.bounds, to: hosting))
        }
        XCTAssertEqual(window.frame.height, shorterHeight, accuracy: 1)
        XCTAssertEqual(observation.value, shorterHeight, accuracy: 2,
                       "Restoring a shorter viewport must preserve the natural height report")
    }

    @MainActor
    private func waitUntil(_ what: String, hosting: NSView, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            hosting.layoutSubtreeIfNeeded()
            hosting.window?.displayIfNeeded()
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(what)")
                throw LayoutTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    @MainActor
    private func footerMarker(in view: NSView) -> FooterMarkerView? {
        if let marker = view as? FooterMarkerView { return marker }
        return view.subviews.lazy.compactMap { self.footerMarker(in: $0) }.first
    }
}

@MainActor
private final class HeightObservation {
    var value: CGFloat = 0
}

private struct LayoutTimeout: Error {}

private struct FooterMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> FooterMarkerView { FooterMarkerView() }
    func updateNSView(_ view: FooterMarkerView, context: Context) {}
}

private final class FooterMarkerView: NSView {}
