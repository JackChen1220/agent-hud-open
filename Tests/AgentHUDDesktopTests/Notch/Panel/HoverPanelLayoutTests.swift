import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class HoverPanelLayoutTests: XCTestCase {
    @MainActor
    func testNativeSessionBoundsIgnoreHeaderTextStatusDotsAndFooterIcons() {
        let hosting = PanelActionFrameView(frame: CGRect(x: 0, y: 0, width: 420, height: 220))
        let group = PanelActionFrameView(frame: hosting.bounds)
        hosting.addSubview(group)
        let title = CGRect(x: 18, y: 94, width: 332, height: 15)
        let tokens = [CGRect(x: 358, y: 94, width: 44, height: 15),
                      CGRect(x: 358, y: 115, width: 44, height: 15)]
        // Drawing views can share a button's row without being that button. The disabled title has no proxy here.
        let frames = [CGRect(x: 18, y: 72, width: 52, height: 16),
                      CGRect(x: 343, y: 73, width: 59, height: 15),
                      CGRect(x: 18, y: 72, width: 384, height: 16),
                      CGRect(x: 18, y: 99, width: 6, height: 6),
                      CGRect(x: 32, y: 94, width: 91, height: 15), title, tokens[0],
                      CGRect(x: 18, y: 120, width: 6, height: 6), tokens[1],
                      CGRect(x: 25, y: 153, width: 15, height: 15),
                      CGRect(x: 380, y: 154, width: 16, height: 14)]
        for frame in frames { group.addSubview(NSView(frame: frame)) }
        XCTAssertEqual(rowTitleFrames(in: hosting), [title])
        XCTAssertEqual(rowTokenFrames(in: hosting), tokens)
    }

    @MainActor
    func testSessionTitleHitAreaReturnsToAgentWhileTokensOpenOnlyThatSessionsUsage() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.panel-actions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let agent = AgentDescriptor(id: "panel-model", vendor: "Codex", model: "Test", source: "Test", enabled: true)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [agent])
        settings.update {
            $0.showIslandQuota = false
            $0.showIslandTokens = false
            $0.showIslandSessions = true
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings), now = Date()
        let available = LiveSession(id: "available-session", agentId: agent.id, task: "Short task", terminal: "proj",
                                    startedAt: now.addingTimeInterval(-60), pctOfWindow: nil, tokensIn: 1_000, tokensOut: 500,
                                    observedAt: now, navigationTarget: .codexThread(id: UUID().uuidString))
        let unavailable = LiveSession(id: "unavailable-session", agentId: agent.id, task: "No destination", terminal: "proj",
                                      startedAt: now.addingTimeInterval(-50), pctOfWindow: nil, tokensIn: 200, tokensOut: 100,
                                      observedAt: now)
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [available, unavailable], consumers: [agent]))
        XCTAssertEqual(HoverPanelView.sessionRows(store).shown.map(\.id), [available.id, unavailable.id])
        let observation = PanelActionObservation()
        let width: CGFloat = 420, height: CGFloat = 220
        let panel = HoverPanelView(store: store, onOpenStats: { observation.stats += 1 },
                                   onOpenListedSession: { observation.sessions.append($0) })
        let hosting = PanelActionHostingView(rootView: panel.frame(width: width))
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = PanelActionTestWindow(contentRect: CGRect(x: -20000, y: -20000, width: width, height: height))
        window.contentView = hosting
        window.acceptsMouseMovedEvents = true
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }

        // SwiftUI's focus proxies can be nested, and a disabled title need not have a proxy. Find the enabled
        // title and both enabled token controls; the second token row locates the disabled title below it.
        try await waitUntil("the native session controls have laid-out bounds", hosting: hosting) {
            !self.rowTitleFrames(in: hosting).isEmpty && self.rowTokenFrames(in: hosting).count == 2
        }
        let titleBounds = try XCTUnwrap(rowTitleFrames(in: hosting).first)
        let tokenBounds = rowTokenFrames(in: hosting)
        let tokensBounds = try XCTUnwrap(tokenBounds.first { abs($0.midY - titleBounds.midY) < 1 })
        let disabledTokensBounds = try XCTUnwrap(tokenBounds.first { abs($0.midY - titleBounds.midY) > 1 })
        let disabledBounds = CGRect(x: titleBounds.minX, y: disabledTokensBounds.minY,
                                    width: titleBounds.width, height: disabledTokensBounds.height)
        func screenFrame(_ bounds: CGRect) -> CGRect { window.convertToScreen(hosting.convert(bounds, to: nil)) }
        let tokensFrame = screenFrame(tokensBounds), disabledFrame = screenFrame(disabledBounds)
        let disabledTokensFrame = screenFrame(disabledTokensBounds)
        let titleFrame = screenFrame(titleBounds)
        XCTAssertGreaterThan(titleFrame.width, 180, "The short title keeps a real trailing blank area before the token button")
        let gap = CGPoint(x: titleFrame.minX + 10, y: titleFrame.midY) // The 6 pt dot is followed by an 8 pt gap.
        let trailingBlank = CGPoint(x: titleFrame.maxX - 4, y: titleFrame.midY)
        for point in [gap, trailingBlank] {
            let previous = observation.sessions.count
            try click(point, in: window)
            try await waitUntil("the title's gap or trailing blank returns to its session", hosting: hosting) {
                observation.sessions.count == previous + 1
            }
            XCTAssertEqual(observation.sessions.last, available.id)
            XCTAssertEqual(observation.stats, 0)
            XCTAssertNil(store.focusedSessionID)
            XCTAssertEqual(store.statsTab, .tokens, "Returning to the agent must not alter the statistics selection")
        }

        try click(CGPoint(x: tokensFrame.midX, y: tokensFrame.midY), in: window)
        try await waitUntil("tokens open the selected session's usage", hosting: hosting) { observation.stats == 1 }
        XCTAssertEqual(store.focusedSessionID, available.id)
        XCTAssertEqual(store.statsTab, .sessions)
        XCTAssertEqual(observation.sessions, [available.id, available.id], "The token button never invokes native navigation")

        try click(CGPoint(x: disabledFrame.midX, y: disabledFrame.midY), in: window)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(observation.stats, 1)
        XCTAssertEqual(observation.sessions, [available.id, available.id])
        XCTAssertEqual(store.focusedSessionID, available.id, "A disabled title must not silently open usage")
        try click(CGPoint(x: disabledTokensFrame.midX, y: disabledTokensFrame.midY), in: window)
        try await waitUntil("a session without a destination still opens its own usage", hosting: hosting) { observation.stats == 2 }
        XCTAssertEqual(store.focusedSessionID, unavailable.id)
        XCTAssertEqual(store.statsTab, .sessions)
        XCTAssertEqual(observation.sessions, [available.id, available.id])
    }

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
                print("Native title candidates: \(rowTitleFrames(in: hosting)); token candidates: \(rowTokenFrames(in: hosting))")
                print(nativeViewHierarchy(in: hosting))
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

    @MainActor
    private func rowTitleFrames(in hosting: NSView) -> [CGRect] {
        nativeButtonFrames(in: hosting).filter { $0.height < 22 && $0.width > 180 && $0.maxX < hosting.bounds.maxX - 30 }
            .sorted { hosting.isFlipped ? $0.minY < $1.minY : $0.maxY > $1.maxY }
    }

    @MainActor
    private func rowTokenFrames(in hosting: NSView) -> [CGRect] {
        guard let title = rowTitleFrames(in: hosting).first else { return [] }
        let candidates = nativeButtonFrames(in: hosting).filter {
            $0.height < 22 && $0.width < 100 && $0.minX > title.maxX
        }
        guard let first = candidates.first(where: { abs($0.midY - title.midY) < 1 }) else { return [] }
        // Both token controls share the trailing column. Header text and footer icons may be equally small.
        return candidates.filter {
            abs($0.maxX - first.maxX) < 1
                && (hosting.isFlipped ? $0.minY >= title.minY : $0.maxY <= title.maxY)
        }.sorted { hosting.isFlipped ? $0.minY < $1.minY : $0.maxY > $1.maxY }
    }

    @MainActor
    private func nativeButtonFrames(in hosting: NSView) -> [CGRect] {
        var frames: [CGRect] = []
        func visit(_ view: NSView) {
            if view.bounds.width > 0, view.bounds.height > 0, !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: hosting)
                if !frames.contains(frame) { frames.append(frame) }
            }
            for child in view.subviews { visit(child) }
        }
        for child in hosting.subviews { visit(child) }
        return frames
    }

    @MainActor
    private func nativeViewHierarchy(in hosting: NSView) -> String {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            lines.append("\(String(repeating: "  ", count: depth))\(type(of: view)) "
                         + "bounds=\(view.bounds) frame=\(view.convert(view.bounds, to: hosting)) "
                         + "hidden=\(view.isHiddenOrHasHiddenAncestor) "
                         + "role=\(String(describing: view.accessibilityRole())) "
                         + "id=\(String(describing: view.accessibilityIdentifier()))")
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        visit(hosting, depth: 0)
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func click(_ screenPoint: CGPoint, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: screenPoint)
        var eventNumber = 0
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            eventNumber += 1
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: eventNumber, clickCount: 1,
                                            pressure: type == .leftMouseDown ? 1 : 0))
        }
        let moved = try event(.mouseMoved), down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        window.sendEvent(moved)
        // AppKit tracking can consume a queued release; SwiftUI's plain buttons also need it delivered to the window.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        window.sendEvent(up)
    }
}

private final class PanelActionFrameView: NSView {
    override var isFlipped: Bool { true }
}

/// The real HUD accepts the first mouse event even when its floating window is not active.
@MainActor
private final class PanelActionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class PanelActionObservation {
    var stats = 0
    var sessions: [String] = []
}

@MainActor
private final class PanelActionTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
