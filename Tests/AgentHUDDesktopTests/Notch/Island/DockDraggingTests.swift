import AppKit
import QuartzCore
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class DockDraggingTests: XCTestCase {
    @MainActor
    func testNativeGrabRevealsBoundsAndBeginsOnlyAfterTheMovementThreshold() throws {
        _ = NSApplication.shared
        let drag = HUDDragWindowController()
        drag.show(frame: CGRect(x: 200, y: 200, width: 240, height: 32), outlined: false)
        defer { drag.hide() }
        let view = try XCTUnwrap(drag.panel.contentView)
        let outline = try XCTUnwrap(outline(in: drag.panel))
        var presses = 0
        var releases = 0
        var ends = 0
        var starts: [CGPoint] = []
        var movements: [CGPoint] = []
        drag.onPress = { presses += 1 }
        drag.onRelease = { releases += 1 }
        drag.onBegin = { starts.append($0) }
        drag.onDrag = { movements.append($0) }
        drag.onEnd = { ends += 1 }
        let down = CGPoint(x: 15, y: 16)
        let initialScreenPoint = drag.panel.convertPoint(toScreen: down)
        XCTAssertEqual(outline.opacity, 0)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, in: drag.panel))
        XCTAssertEqual(presses, 1)
        XCTAssertTrue(drag.isPressed)
        XCTAssertFalse(drag.isDragging)
        XCTAssertEqual(outline.opacity, 1, "Pressing visible logos must immediately reveal their dashed bounds")
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 17, y: 16), in: drag.panel))
        XCTAssertFalse(drag.isDragging, "Two points of hand motion remain an ordinary press")
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(movements.isEmpty)
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 19, y: 16), in: drag.panel))
        XCTAssertTrue(drag.isDragging)
        XCTAssertEqual(starts, [initialScreenPoint], "Beginning a drag must keep the original grabbed point")
        XCTAssertEqual(movements, [drag.panel.convertPoint(toScreen: CGPoint(x: 19, y: 16))])
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 23, y: 16), in: drag.panel))
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(movements.count, 2)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 23, y: 16), in: drag.panel))
        XCTAssertFalse(drag.isPressed)
        XCTAssertFalse(drag.isDragging)
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(outline.opacity, 0, "Dropping restores the transparent grab surface")

        // A plain click also clears the bounds, without committing a drag or changing its mode.
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, in: drag.panel))
        XCTAssertEqual(outline.opacity, 1)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: down, in: drag.panel))
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 2)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ends, 1, "A click that never crosses the threshold must not commit a drag")
        XCTAssertFalse(drag.isPressed)
        XCTAssertEqual(outline.opacity, 0)
    }

    @MainActor
    func testVisibleLogosProvideATransparentGrabSurfaceWithoutCommand() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.free-drag.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0.screens[key] = ScreenPlacement(mode: .logos, edge: .top, showsLogos: true) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents,
            historyHours: UsageStore.historyHours, now: Date()))
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
        defer { hud.close() }
        hud.updateMoveHint(commandDown: false)
        let surface = try XCTUnwrap(visibleMoveSurface())
        assertFrame(surface.frame, equals: ScreenHUD.dragSurfaceFrame(for: hud.geometry),
                    "The transparent surface includes padding at both ends of the queue")
        XCTAssertFalse(surface.ignoresMouseEvents, "Visible logos must be directly draggable without Command")
        XCTAssertFalse(surface.isOpaque)
        XCTAssertEqual(surface.backgroundColor?.alphaComponent ?? 1, 0, accuracy: 0.001)
        let outline = try XCTUnwrap(outline(in: surface))
        XCTAssertEqual(outline.opacity, 0, "An idle grab surface must preserve the bare-logo appearance")

        hud.updateMoveHint(commandDown: true)
        XCTAssertTrue(surface.isVisible)
        XCTAssertEqual(outline.opacity, 1, "Command reveals the otherwise transparent bounds")
        hud.updateMoveHint(commandDown: false)
        XCTAssertTrue(surface.isVisible, "Visible logos remain draggable after releasing Command")
        XCTAssertEqual(outline.opacity, 0)
    }

    @MainActor
    func testNonCentreGrabStaysUnderThePointerAndPersistsOnlyOnceOnDrop() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        for edge in HUDEdge.allCases {
            let domain = "app.agenthud.tests.grab-offset.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
            let original = ScreenPlacement(mode: .logos, edge: edge, offset: 0.4)
            settings.update { $0.screens[key] = original }
            let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
            store.replace(report: DemoUsageProvider.report(agents: settings.agents,
                historyHours: UsageStore.historyHours, now: Date()))
            let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
            defer { hud.close() }
            let initial = hud.geometry.rect
            let grab = edge.isHorizontal
                ? CGPoint(x: initial.minX + 5, y: initial.midY)
                : CGPoint(x: initial.midX, y: initial.minY + 5)
            let previousOnChange = settings.onChange
            var writes = 0
            settings.onChange = { change in
                previousOnChange?(change)
                if case .settings = change { writes += 1 }
            }

            hud.beginMoving(at: grab)
            hud.move(to: grab)
            assertFrame(hud.geometry.rect, equals: initial, "\(edge): a non-centre press must not snap the queue to its centre")
            for distance in [CGFloat(37), 74] {
                let delta = edge.isHorizontal ? CGPoint(x: distance, y: 0) : CGPoint(x: 0, y: distance)
                hud.move(to: CGPoint(x: grab.x + delta.x, y: grab.y + delta.y))
                XCTAssertEqual(hud.geometry.edge, edge)
                assertFrame(hud.geometry.rect, equals: initial.offsetBy(dx: delta.x, dy: delta.y),
                            "\(edge): the original grabbed point must track the pointer")
                XCTAssertEqual(settings.settings.screens[key], original)
                XCTAssertEqual(writes, 0, "Previewing a drag must not persist intermediate positions")
            }
            hud.finishMoving()
            XCTAssertEqual(writes, 1, "Dropping commits exactly one settings change")
            let stored = try XCTUnwrap(settings.settings.screens[key])
            XCTAssertEqual(stored.edge, edge)
            XCTAssertNotEqual(stored.offset, original.offset)
            XCTAssertEqual(SettingsStore(defaults: defaults).settings.screens[key], stored)
            hud.finishMoving()
            XCTAssertEqual(writes, 1, "A second finish without a drag must not persist again")
        }
    }

    @MainActor
    func testOpeningAShortSidePanelKeepsTheWholeLogoQueueOnItsCanvas() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.dock-canvas.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.everyAgent)
        settings.update {
            $0.screens[key] = ScreenPlacement(mode: .logos, edge: .right)
            $0.showIslandQuota = false
            $0.showIslandTokens = false
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
        defer { hud.close() }
        XCTAssertGreaterThan(hud.geometry.rect.height, 120)
        hud.forceOpen()
        XCTAssertTrue(hud.island.panel.frame.insetBy(dx: -1, dy: -1).contains(hud.geometry.rect),
                      "A short usage card must not clip the longer queue when it opens")
        XCTAssertTrue(screen.frame.insetBy(dx: -1, dy: -1).contains(hud.island.panel.frame))
    }

    @MainActor
    func testHiddenLogosHaveAMoveSurfaceThatFollowsThePreviewAndDisappearsAfterDropping() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.dock-drag.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let original = ScreenPlacement(mode: .logos, edge: .bottom, offset: 0.25, showsLogos: false)
        settings.update { $0.screens[key] = original }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
        defer { hud.close() }
        XCTAssertTrue(hud.island.panel.ignoresMouseEvents)
        hud.updateMoveHint(commandDown: false)
        XCTAssertNil(visibleMoveSurface(), "Hidden logos expose no grab panel until Command reveals their bounds")
        hud.updateMoveHint(commandDown: true)
        let surface = try XCTUnwrap(visibleMoveSurface())
        assertFrame(surface.frame, equals: ScreenHUD.dragSurfaceFrame(for: hud.geometry),
                    "Command reveals the padded hidden-logo target")
        XCTAssertEqual(try XCTUnwrap(outline(in: surface)).opacity, 1)
        hud.beginMoving()
        hud.updateMoveHint(commandDown: false)
        XCTAssertTrue(surface.isVisible, "Releasing Command during a drag must retain its grab surface")
        XCTAssertEqual(try XCTUnwrap(outline(in: surface)).opacity, 1,
                       "The active drag must keep showing its dashed bounds")
        hud.move(to: CGPoint(x: screen.frame.maxX, y: screen.frame.midY))
        XCTAssertEqual(hud.geometry.edge, .right)
        assertFrame(surface.frame, equals: ScreenHUD.dragSurfaceFrame(for: hud.geometry),
                    "The padded dashed bounds follow the drag preview, allowing AppKit's frame rounding")
        XCTAssertEqual(settings.settings.screens[key], original, "Mouse movements must not persist intermediate positions")
        hud.finishMoving()
        hud.updateMoveHint(commandDown: false)
        XCTAssertFalse(surface.isVisible, "Dropping and releasing Command must restore click-through")
        XCTAssertTrue(hud.island.panel.ignoresMouseEvents)
        let stored = try XCTUnwrap(settings.settings.screens[key])
        XCTAssertEqual(stored.edge, .right)
        XCTAssertFalse(stored.showsLogos)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.screens[key], stored)
    }

    @MainActor
    func testEmptyDockKeepsItsEdgeAndCanMoveOutOfNotchMode() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.empty-dock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        settings.update { $0.screens[key] = ScreenPlacement(mode: .logos, edge: .left, offset: 0.7) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
        defer { hud.close() }
        XCTAssertEqual(hud.geometry.mode, .logos)
        XCTAssertEqual(hud.geometry.edge, .left)
        XCTAssertGreaterThan(hud.geometry.rect.height, 0)
        settings.update { $0.screens[key]?.mode = .notch }
        hud.apply(animated: false)
        XCTAssertEqual(hud.geometry.mode, .notch)
        hud.updateMoveHint(commandDown: false)
        let surface = try XCTUnwrap(visibleMoveSurface())
        let view = try XCTUnwrap(surface.contentView)
        let press = CGPoint(x: 15, y: 7)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: press, in: surface))
        XCTAssertEqual(hud.geometry.mode, .notch, "A press reveals bounds without converting Notch to Dock")
        XCTAssertEqual(settings.settings.screens[key]?.mode, .notch)
        XCTAssertEqual(try XCTUnwrap(outline(in: surface)).opacity, 1)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: press, in: surface))
        XCTAssertEqual(hud.geometry.mode, .notch, "A click below the drag threshold must retain Notch mode")
        XCTAssertEqual(try XCTUnwrap(outline(in: surface)).opacity, 0)
        hud.beginMoving()
        hud.move(to: CGPoint(x: screen.frame.midX, y: screen.frame.minY))
        hud.finishMoving()
        XCTAssertEqual(hud.geometry.mode, .logos)
        XCTAssertEqual(settings.settings.screens[key]?.edge, .bottom)
    }

    @MainActor
    func testDragSurfacePadsTheQueueEndsAndClipsAtEveryScreenCorner() {
        let screen = CGRect(x: -1600, y: -200, width: 1600, height: 900)
        for edge in HUDEdge.allCases {
            for offset in [0.0, 0.5, 1.0] {
                let queue = edge.isHorizontal ? CGSize(width: 216, height: 20) : CGSize(width: 20, height: 216)
                let placement = ScreenPlacement(edge: edge, offset: offset)
                let rect = NotchGeometry.stripRect(queue: queue, frame: screen, menuBar: 32, placement: placement)
                let geometry = NotchGeometry(screenFrame: screen, mode: .logos, edge: edge, hasNotch: false,
                                             rect: rect, cornerRadius: 10, backingScale: 2, menuBarHeight: 32)
                let surface = ScreenHUD.dragSurfaceFrame(for: geometry)
                XCTAssertTrue(screen.contains(surface), "\(edge), offset \(offset): target stays on screen")
                XCTAssertTrue(surface.contains(rect), "Padding keeps all original marks inside the target")
                if edge.isHorizontal {
                    XCTAssertEqual(rect.minX - surface.minX, offset == 0 ? 0 : 8)
                    XCTAssertEqual(surface.maxX - rect.maxX, offset == 1 ? 0 : 8)
                    XCTAssertEqual(surface.minY, rect.minY)
                    XCTAssertEqual(surface.height, rect.height)
                } else {
                    XCTAssertEqual(surface.maxY - rect.maxY, offset == 0 ? 0 : 8)
                    XCTAssertEqual(rect.minY - surface.minY, offset == 1 ? 0 : 8)
                    XCTAssertEqual(surface.minX, rect.minX)
                    XCTAssertEqual(surface.width, rect.width)
                }
            }
        }
    }

    @MainActor
    func testNotchDragSurfaceKeepsItsReachableAreaBelowTheHardware() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let rect = CGRect(x: 700, y: screen.maxY - 38, width: 200, height: 38)
        let geometry = NotchGeometry(screenFrame: screen, mode: .notch, edge: .top, hasNotch: true,
                                     rect: rect, cornerRadius: 12, backingScale: 2, menuBarHeight: 38)
        let surface = ScreenHUD.dragSurfaceFrame(for: geometry)
        XCTAssertEqual(surface.minY, rect.minY - 14)
        XCTAssertEqual(surface.maxY, screen.maxY)
        XCTAssertEqual(surface.minX, rect.minX - 8)
        XCTAssertEqual(surface.maxX, rect.maxX + 8)
        XCTAssertTrue(screen.contains(surface))
    }

    @MainActor
    private func visibleMoveSurface() -> NSWindow? {
        NSApp.windows.first { $0.title == "Move Agent HUD" && $0.isVisible }
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    @MainActor
    private func outline(in window: NSWindow) -> CAShapeLayer? {
        window.contentView?.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, message, file: file, line: line)
    }
}
