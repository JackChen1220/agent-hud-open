import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class StatsWindowLifecycleTests: XCTestCase {
    @MainActor
    func testNativeRestoreFitsContentUpdatedWhileMiniaturized() async throws {
        let app = NSApplication.shared
        let activationPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(activationPolicy) }
        let domain = "app.agenthud.tests.stats-window.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.statsTab = .sessions
        let now = Date()
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: []))
        let controller = StatsWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        let hosting = try XCTUnwrap(window.contentView)
        let initialHeight = window.frame.height
        // Keep the native window outside the user's desktop, including when show() orders it forward.
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        controller.show()
        defer { window.orderOut(nil) }
        try await waitUntil("the empty sessions page sizes its window") {
            hosting.layoutSubtreeIfNeeded()
            return window.frame.height < initialHeight - 1 && findScrollView(in: hosting)?.documentView != nil
        }
        let scroll = try XCTUnwrap(findScrollView(in: hosting))
        let document = try XCTUnwrap(scroll.documentView)
        let emptyContentHeight = document.bounds.height
        let emptyFrame = window.frame

        window.miniaturize(nil)
        try await waitUntil("the native window is miniaturized") { window.isMiniaturized }
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: now))
        // Wait for the real SwiftUI content to grow before restoring, so a deferred data update cannot mask the bug.
        try await waitUntil("the minimized sessions page lays out its refreshed content") {
            hosting.layoutSubtreeIfNeeded()
            return document.bounds.height > emptyContentHeight + 100
        }
        XCTAssertEqual(window.frame.height, emptyFrame.height, accuracy: 1,
                       "A minimized window keeps its frame while caching the new content height")

        // Dock restoration uses AppKit's native path and does not call StatsWindowController.show().
        window.deminiaturize(nil)
        try await waitUntil("native restoration applies the cached content height") {
            hosting.layoutSubtreeIfNeeded()
            return !window.isMiniaturized && window.isVisible && window.frame.height > emptyFrame.height + 1
        }
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
