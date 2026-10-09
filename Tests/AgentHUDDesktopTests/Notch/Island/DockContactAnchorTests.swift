import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class DockContactAnchorTests: XCTestCase {
    @MainActor
    func testRenderedContactStaysOnEveryEdgeDuringOpeningAndClosing() async throws {
        _ = NSApplication.shared
        let (store, defaults, domain) = try makeStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        let screen = CGRect(x: -20000, y: -20000, width: 1200, height: 900)

        for edge in HUDEdge.allCases {
            let strip = NotchGeometry.stripRect(
                queue: edge.isHorizontal ? CGSize(width: 216, height: 32) : CGSize(width: 32, height: 216),
                frame: screen, menuBar: 32, placement: ScreenPlacement(mode: .logos, edge: edge))
            let geometry = NotchGeometry(screenFrame: screen, mode: .logos, edge: edge, hasNotch: false,
                                         rect: strip, cornerRadius: 10, backingScale: 2, menuBarHeight: 32)
            let closedFrame = geometry.islandFrame
            var closed = root(store: store, open: false, edge: edge, strip: strip.size)
            closed.presentationFrame = CGRect(origin: .zero, size: closedFrame.size)
            closed.animatesGeometry = false
            let controller = IslandWindowController(frame: closedFrame, rootView: closed)
            controller.show()
            defer { controller.panel.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(60))

            var opened = root(store: store, open: true, edge: edge, strip: strip.size)
            let coreHeight = max(80, controller.contentHeight(for: opened).rounded())
            let card = geometry.expandedFrame(size: CGSize(
                width: 540 + (edge.isHorizontal ? 32 : 0),
                height: coreHeight + (edge.isHorizontal ? 0 : 32)))
            let openCanvas = card.union(closedFrame)
            controller.setFrame(controller.panel.frame.union(openCanvas))
            opened.presentationFrame = localFrame(card, canvas: controller.panel.frame)
            opened.onGeometryCompletion = { [weak controller] in controller?.setFrame(openCanvas) }
            controller.setRootView(opened)

            var openingDepths: [CGFloat] = []
            for delay in [50, 150, 300] {
                try await Task.sleep(for: .milliseconds(delay))
                if let depth = try assertContact(controller, edge: edge, screen: screen, card: card,
                                                 phase: "opening after +\(delay)ms") {
                    openingDepths.append(depth)
                }
            }
            XCTAssertFalse(openingDepths.isEmpty, "\(edge): opening must produce actual nontransparent pixels")
            XCTAssertNotNil(try assertContact(controller, edge: edge, screen: screen, card: card,
                                              phase: "opened and settled"))
            let finalDepth = edge.isHorizontal ? card.height : card.width
            let observedIntermediate = openingDepths.dropLast().contains { $0 < finalDepth - 1 }
            XCTContext.runActivity(named: "\(edge): cached opening pixels") { activity in
                let attachment = XCTAttachment(string: "normal depths: \(openingDepths); intermediate size observed: \(observedIntermediate). cacheDisplay samples are hosting pixels; when already settled they do not establish compositor motion.")
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }

            closed.animatesGeometry = true
            closed.presentationFrame = localFrame(closedFrame, canvas: controller.panel.frame)
            closed.onGeometryCompletion = { [weak controller] in controller?.setFrame(closedFrame) }
            controller.setRootView(closed)
            for delay in [50, 150, 220, 100] {
                try await Task.sleep(for: .milliseconds(delay))
                // The bare dock may already be fully transparent. Every painted closing frame must
                // still touch its contact edge, including the sample just after native cleanup.
                _ = try assertContact(controller, edge: edge, screen: screen, card: card,
                                      phase: "closing after +\(delay)ms")
            }
            XCTAssertEqual(controller.panel.frame, closedFrame,
                           "\(edge): animation completion must shrink the native canvas")
        }
    }

    @MainActor
    func testRenderedShortRightCardKeepsItsContactAndAlongEdgeOffsetInALongCanvas() async throws {
        _ = NSApplication.shared
        let (store, defaults, domain) = try makeStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        let canvas = CGRect(x: -20000, y: -20000, width: 540, height: 400)
        let card = CGRect(x: 0, y: 200, width: 540, height: 120)
        var view = root(store: store, open: true, edge: .right, strip: CGSize(width: 32, height: 400))
        view.presentationSize = canvas.size
        view.presentationFrame = card
        view.animatesGeometry = false
        let controller = IslandWindowController(frame: canvas, rootView: view)
        controller.show()
        defer { controller.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(80))
        let bitmap = try capture(controller)
        let scale = canvas.height / CGFloat(bitmap.pixelsHigh)
        let occupied = (0..<bitmap.pixelsHigh).filter {
            (bitmap.colorAt(x: bitmap.pixelsWide / 2, y: $0)?.alphaComponent ?? 0) > 0.9
        }
        XCTAssertEqual((CGFloat(try XCTUnwrap(occupied.first)) + 0.5) * scale,
                       card.minY + IslandRootView.expandedTopRadius, accuracy: scale,
                       "The 60pt along-edge offset must place the card shoulder at y=216")
        XCTAssertEqual((CGFloat(try XCTUnwrap(occupied.last)) + 0.5) * scale,
                       card.maxY - IslandRootView.expandedTopRadius, accuracy: scale)
        let globalCard = CGRect(x: canvas.minX + card.minX, y: canvas.maxY - card.maxY,
                                width: card.width, height: card.height)
        XCTAssertNotNil(try assertContact(controller, edge: .right, screen: canvas, card: globalCard,
                                          phase: "short card in long canvas"))
    }

    @MainActor
    private func makeStore() throws -> (UsageStore, UserDefaults, String) {
        let domain = "app.agenthud.tests.dock-contact.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update {
            $0.showIslandQuota = false
            $0.showIslandTokens = false
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents,
            historyHours: UsageStore.historyHours, now: Date()))
        return (store, defaults, domain)
    }

    @MainActor
    private func root(store: UsageStore, open: Bool, edge: HUDEdge, strip: CGSize) -> IslandRootView {
        var view = IslandRootView(store: store, isOpen: open, collapsedSize: strip,
                                  collapsedTopRadius: IslandRootView.expandedTopRadius,
                                  collapsedBottomRadius: 10, lightBorder: false, onOpenStats: {})
        view.hidesSilhouette = true
        view.edge = edge
        // No LogoQueueConfig: the contact measurement contains only the black card and its footer.
        return view
    }

    private func localFrame(_ global: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: global.minX - canvas.minX, y: canvas.maxY - global.maxY,
               width: global.width, height: global.height)
    }

    @MainActor
    private func capture(_ controller: IslandWindowController) throws -> NSBitmapImageRep {
        let hosting = try XCTUnwrap(controller.panel.contentView)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// Measure a rendered centre row/column, then convert the edge pixel back to screen coordinates.
    /// A nil result is allowed only for a fully transparent bare dock during its collapse.
    @MainActor
    private func assertContact(_ controller: IslandWindowController, edge: HUDEdge, screen: CGRect,
                               card: CGRect, phase: String,
                               file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat? {
        let bitmap = try capture(controller)
        let canvas = controller.panel.frame
        let sx = canvas.width / CGFloat(bitmap.pixelsWide)
        let sy = canvas.height / CGFloat(bitmap.pixelsHigh)
        let x = min(bitmap.pixelsWide - 1, max(0, Int((card.midX - canvas.minX) / sx)))
        let y = min(bitmap.pixelsHigh - 1, max(0, Int((canvas.maxY - card.midY) / sy)))
        let count = edge.isHorizontal ? bitmap.pixelsHigh : bitmap.pixelsWide
        let painted = (0..<count).filter { index in
            let color = edge.isHorizontal ? bitmap.colorAt(x: x, y: index) : bitmap.colorAt(x: index, y: y)
            return (color?.alphaComponent ?? 0) > 0.02
        }
        guard let first = painted.first, let last = painted.last else {
            let hasPaint = (0..<bitmap.pixelsHigh).contains { row in
                (0..<bitmap.pixelsWide).contains { column in
                    (bitmap.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.02
                }
            }
            XCTAssertFalse(hasPaint, "\(edge), \(phase): a painted card must intersect its centre scanline",
                           file: file, line: line)
            return nil
        }
        let pixel = (edge == .top || edge == .left) ? first : last
        let coordinate = edge.isHorizontal
            ? canvas.maxY - (CGFloat(pixel) + 0.5) * sy
            : canvas.minX + (CGFloat(pixel) + 0.5) * sx
        let contact: CGFloat
        switch edge {
        case .top: contact = screen.maxY
        case .bottom: contact = screen.minY
        case .left: contact = screen.minX
        case .right: contact = screen.maxX
        }
        let pixelSize = edge.isHorizontal ? sy : sx
        XCTAssertEqual(coordinate, contact, accuracy: pixelSize + 0.001,
                       "\(edge), \(phase): the rendered black edge must stay within one pixel of contact",
                       file: file, line: line)
        return CGFloat(last - first + 1) * pixelSize
    }
}
