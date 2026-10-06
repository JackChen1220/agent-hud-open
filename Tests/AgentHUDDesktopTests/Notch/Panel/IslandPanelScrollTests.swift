import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class IslandPanelScrollTests: XCTestCase {
    @MainActor
    func testLongNotchPanelScrollsWithinItsShortCardOnATallerAnimationCanvas() async throws {
        try await checkPanel(edge: nil)
    }

    @MainActor
    func testLongDockPanelScrollsAboveItsFooterOnEveryEdge() async throws {
        for edge in HUDEdge.allCases {
            try await checkPanel(edge: edge)
        }
    }

    @MainActor
    private func checkPanel(edge: HUDEdge?) async throws {
        _ = NSApplication.shared
        let fixture = try IslandPanelScrollFixture(edge: edge)
        defer { fixture.close() }
        let hosting = try XCTUnwrap(fixture.controller.panel.contentView)
        fixture.controller.show()
        let label = edge.map { "\($0) dock" } ?? "notch"
        try await waitUntil("\(label) lays out its complete root, quota rows, token models and inline completion",
                            hosting: hosting) {
            guard let scroll = self.firstScrollView(in: hosting), let document = scroll.documentView,
                  let marker = self.footerMarker(in: hosting) else { return false }
            return fixture.observation.height > fixture.cardFrame.height + 200
                && document.bounds.height > 0 && scroll.contentView.bounds.height > 0 && marker.bounds.height > 0
        }
        let scroll = try XCTUnwrap(firstScrollView(in: hosting))
        let document = try XCTUnwrap(scroll.documentView)
        let marker = try XCTUnwrap(footerMarker(in: hosting))
        let viewportBefore = topLeftRect(scroll.contentView.convert(scroll.contentView.bounds, to: hosting), in: hosting)
        let footerBefore = topLeftRect(marker.convert(marker.bounds, to: hosting), in: hosting)
        let card = fixture.cardFrame

        XCTAssertGreaterThan(fixture.canvas.height, card.height + 200)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height + 200,
                             "\(label): the complete root must offer a genuinely overflowing viewport")
        XCTAssertGreaterThan(viewportBefore.height, 80, "\(label): the viewport must retain usable space")
        XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(viewportBefore),
                      "\(label): viewport \(viewportBefore) must stay inside short card \(card), not use the full canvas")
        XCTAssertNil(marker.enclosingScrollView, "\(label): footer controls must be outside the scrolling content")
        XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(footerBefore),
                      "\(label): footer \(footerBefore) must be inside the card \(card)")
        XCTAssertGreaterThanOrEqual(footerBefore.minY, viewportBefore.maxY - 1,
                                   "\(label): the scrolling viewport must end above the footer")
        let visibleFooter = marker.visibleRect.intersection(marker.bounds)
        XCTAssertEqual(visibleFooter.height, marker.bounds.height, accuracy: 1,
                       "\(label): the footer must remain fully visible in the native hierarchy")
        XCTAssertEqual(visibleFooter.width, marker.bounds.width, accuracy: 1)
        XCTAssertTrue(hosting.bounds.contains(marker.convert(marker.bounds, to: hosting)),
                      "\(label): the complete footer must remain inside the native animation canvas")
        try assertFooterIsPainted(marker, in: hosting, label: label)

        let previousOffset = scroll.contentView.bounds.origin.y
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil("\(label) scrolls to its last content row", hosting: hosting) {
            abs(scroll.contentView.bounds.origin.y - bottom) < 1
        }
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, previousOffset,
                          "\(label): scrolling must move the actual NSScrollView document")
        let footerAfter = topLeftRect(marker.convert(marker.bounds, to: hosting), in: hosting)
        let viewportAfter = topLeftRect(scroll.contentView.convert(scroll.contentView.bounds, to: hosting), in: hosting)
        XCTAssertEqual(footerAfter.minX, footerBefore.minX, accuracy: 1)
        XCTAssertEqual(footerAfter.minY, footerBefore.minY, accuracy: 1, "\(label): scrolling must not move the footer")
        XCTAssertEqual(footerAfter.width, footerBefore.width, accuracy: 1)
        XCTAssertEqual(footerAfter.height, footerBefore.height, accuracy: 1)
        XCTAssertEqual(viewportAfter.minY, viewportBefore.minY, accuracy: 1)
        XCTAssertEqual(viewportAfter.height, viewportBefore.height, accuracy: 1)
        try assertFooterIsPainted(marker, in: hosting, label: label)
    }

    @MainActor
    private func assertFooterIsPainted(_ marker: IslandPanelFooterProbeView, in hosting: NSView, label: String) throws {
        let footer = topLeftRect(marker.convert(marker.bounds, to: hosting), in: hosting)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let x = Int((footer.midX - hosting.bounds.minX) * CGFloat(bitmap.pixelsWide) / hosting.bounds.width)
        let y = Int(footer.midY * CGFloat(bitmap.pixelsHigh) / hosting.bounds.height)
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh else {
            XCTFail("\(label): the footer centre lies outside the rendered animation canvas")
            return
        }
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8, "\(label): the card's mask must leave the footer visible")
        XCTAssertGreaterThan(color.blueComponent, 0.8, "\(label): the footer probe must be painted")
        XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.25,
                             "\(label): the footer probe must remain visibly magenta after colour conversion")
        XCTAssertGreaterThan(color.blueComponent - color.greenComponent, 0.25)
        XCTAssertGreaterThan(color.alphaComponent, 0.8)
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
                throw IslandPanelScrollTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }

    @MainActor
    private func topLeftRect(_ rect: CGRect, in hosting: NSView) -> CGRect {
        hosting.isFlipped ? rect : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY,
                                         width: rect.width, height: rect.height)
    }

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    @MainActor
    private func footerMarker(in view: NSView) -> IslandPanelFooterProbeView? {
        if let marker = view as? IslandPanelFooterProbeView { return marker }
        return view.subviews.lazy.compactMap { self.footerMarker(in: $0) }.first
    }
}

@MainActor
private final class IslandPanelScrollFixture {
    let domain = "app.agenthud.tests.root-scroll.\(UUID().uuidString)"
    let defaults: UserDefaults
    let controller: IslandWindowController
    let canvas: CGSize
    let cardFrame: CGRect
    let observation: IslandPanelScrollObservation

    init(edge: HUDEdge?) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let observedHeight = IslandPanelScrollObservation()
        observation = observedHeight
        let agents = (0..<24).map {
            AgentDescriptor(id: "scroll-quota-\($0)", vendor: "Claude", model: "Quota \($0)", source: "Test", enabled: true)
        }
        let consumers = (0..<26).map {
            AgentDescriptor(id: "scroll-model-\($0)", vendor: $0.isMultiple(of: 2) ? "Claude" : "Codex",
                            model: "Model \($0)", source: "Test", enabled: true)
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update {
            $0.showIslandQuota = true
            $0.showIslandTokens = true
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        store.replace(report: UsageReport(generatedAt: now, snapshots: agents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600),
                          windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: [], discoveredAgents: agents, consumers: consumers, usage: consumers.flatMap { consumer in
            (0..<24).map { hour in
                UsageBucket(start: now.addingTimeInterval(-Double(hour + 1) * 3600), agentId: consumer.id,
                            tokensIn: 10000, tokensOut: 1000)
            }
        }))
        let width = IslandController.expandedWidth + ((edge?.isHorizontal ?? true) ? 2 * NotchGeometry.expandedTopRadius : 0)
        canvas = CGSize(width: width, height: 760)
        let y: CGFloat
        switch edge {
        case .bottom: y = canvas.height - 420
        case .left, .right: y = 210
        default: y = 0
        }
        cardFrame = CGRect(x: 0, y: y, width: width, height: 420)
        let strip: CGRect
        switch edge {
        case .bottom: strip = CGRect(x: 100, y: canvas.height - 32, width: 280, height: 32)
        case .left: strip = CGRect(x: 0, y: 0, width: 32, height: canvas.height)
        case .right: strip = CGRect(x: width - 32, y: 0, width: 32, height: canvas.height)
        default: strip = CGRect(x: 100, y: 0, width: 280, height: 32)
        }
        let completion = SessionCompletion(sessionID: "scroll-completion", vendor: "Claude", turnID: "finished-turn",
            task: "A completed task keeps its inline reminder above the quota and token sections",
            model: "Model 0", startedAt: now.addingTimeInterval(-180), completedAt: now)
        var root = IslandRootView(store: store, isOpen: true,
            collapsedSize: edge == nil ? CGSize(width: 216, height: 32) : strip.size,
            collapsedTopRadius: 8, collapsedBottomRadius: 12, lightBorder: false, onOpenStats: {},
            additionalHUDControls: { AnyView(IslandPanelFooterProbe().frame(width: 16, height: 28)) },
            alert: .completion(completion))
        root.presentationSize = canvas
        root.presentationFrame = cardFrame
        root.animatesGeometry = false
        root.onContentHeight = { observedHeight.height = $0 }
        if let edge {
            root.hidesSilhouette = true
            root.edge = edge
            root.logoQueueFrame = strip
            root.logoQueue = LogoQueueConfig(items: (0..<20).map { _ in
                LogoQueueItem(vendor: "Claude", isWorking: false)
            }, placement: ScreenPlacement(mode: .logos, edge: edge, logoSize: 24), settings: settings.settings)
        }
        controller = IslandWindowController(
            frame: CGRect(x: -20000, y: -20000, width: canvas.width, height: canvas.height), rootView: root)
    }

    func close() {
        controller.panel.orderOut(nil)
        defaults.removePersistentDomain(forName: domain)
    }
}

@MainActor
private final class IslandPanelScrollObservation {
    var height: CGFloat = 0
}

private struct IslandPanelScrollTimeout: Error {}

private struct IslandPanelFooterProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> IslandPanelFooterProbeView { IslandPanelFooterProbeView() }
    func updateNSView(_ view: IslandPanelFooterProbeView, context: Context) {}
}

private final class IslandPanelFooterProbeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        bounds.fill()
    }
}
