import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class GlowPreparationTests: XCTestCase {
    @MainActor
    func testMatchingPreparationInstallsThePreparedSoftGlowAndShadow() throws {
        _ = NSApplication.shared
        let geometry = geometry()
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.close() }
        let island = geometry.expandedFrame(size: CGSize(width: 240, height: 120))
        let settings = GlowSettings()
        let glow = settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 26)
        let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle())
        let soft = try XCTUnwrap(prepared.soft)
        let shadow = try XCTUnwrap(prepared.shadow)

        controller.update(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle(), animated: false, prepared: prepared)
        XCTAssertTrue(controller.glowLayer.contents as AnyObject? === soft.image)
        XCTAssertTrue(controller.shadowLayer.contents as AnyObject? === shadow.image)

        controller.update(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle(), animated: false)
        XCTAssertTrue(controller.glowLayer.contents as AnyObject? === soft.image,
                      "An ordinary refresh must retain the material installed at opening")
        XCTAssertTrue(controller.shadowLayer.contents as AnyObject? === shadow.image)
    }

    @MainActor
    func testPreparationLeavesTheCollapsedWindowLayersAndAnimationUntouched() throws {
        _ = NSApplication.shared
        let geometry = geometry()
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.close() }
        var settings = GlowSettings()
        settings.style = .dots
        settings.effect = .ripple
        let pattern = settings.pattern()
        let glow = settings.geometry(islandWidth: geometry.rect.width, islandHeight: geometry.rect.height, islandRadius: 12)
        controller.update(geometry: geometry, island: geometry.rect, islandRadius: 12, glow: glow,
            outwardOnly: true, appearance: .idle(), animated: false, pattern: pattern)
        let active = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: true, glow: settings)
        controller.update(geometry: geometry, island: geometry.rect, islandRadius: 12, glow: glow,
            outwardOnly: true, appearance: active, animated: false, pattern: pattern)
        let soft = try XCTUnwrap(controller.glowLayer.contents) as! CGImage
        let shadow = try XCTUnwrap(controller.shadowLayer.contents) as! CGImage
        let windowFrame = controller.panel.frame
        let visible = controller.panel.isVisible
        let glowFrame = controller.glowLayer.frame
        let shadowFrame = controller.shadowLayer.frame
        let opacity = controller.glowLayer.opacity
        let animationKeys = controller.glowLayer.animationKeys()
        let animating = controller.isAnimating
        let island = geometry.expandedFrame(size: CGSize(width: 240, height: 120))
        let expandedGlow = settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 26)

        let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: expandedGlow,
            outwardOnly: true, appearance: active, pattern: pattern)
        XCTAssertNotNil(prepared.renderer)
        XCTAssertEqual(controller.panel.frame, windowFrame)
        XCTAssertEqual(controller.panel.isVisible, visible)
        XCTAssertEqual(controller.glowLayer.frame, glowFrame)
        XCTAssertEqual(controller.shadowLayer.frame, shadowFrame)
        XCTAssertEqual(controller.glowLayer.opacity, opacity)
        XCTAssertEqual(controller.glowLayer.animationKeys(), animationKeys)
        XCTAssertEqual(controller.isAnimating, animating)
        XCTAssertTrue(controller.glowLayer.contents as AnyObject? === soft)
        XCTAssertTrue(controller.shadowLayer.contents as AnyObject? === shadow)
    }

    @MainActor
    func testChangedColoursRejectPreparedGlowAndRetainMatchingShadow() throws {
        _ = NSApplication.shared
        let geometry = geometry()
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.close() }
        let island = geometry.expandedFrame(size: CGSize(width: 240, height: 120))
        let settings = GlowSettings()
        let glow = settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 26)
        let green = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: true, glow: settings)
        let red = GlowAppearance.resolve(levels: [.critical], paused: false, anyAgentActive: true, glow: settings)
        let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: green)
        let soft = try XCTUnwrap(prepared.soft)
        let shadow = try XCTUnwrap(prepared.shadow)

        controller.update(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: red, animated: false, prepared: prepared)
        let actual = try XCTUnwrap(controller.glowLayer.contents) as! CGImage
        let expected = try XCTUnwrap(GlowRenderer.render(glow: glow, islandSize: island.size, islandRadius: 26,
            outwardOnly: true, stops: red.stops, scale: geometry.backingScale))
        XCTAssertFalse(actual === soft.image)
        XCTAssertEqual(try pixels(actual), try pixels(expected.image), "Opening must use the current quota colours")
        XCTAssertTrue(controller.shadowLayer.contents as AnyObject? === shadow.image)
    }

    @MainActor
    func testChangedSizeRejectsBothPreparedImages() throws {
        _ = NSApplication.shared
        let geometry = geometry()
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.close() }
        let island = geometry.expandedFrame(size: CGSize(width: 240, height: 120))
        let settings = GlowSettings()
        let glow = settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 26)
        let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle())
        let taller = geometry.expandedFrame(size: CGSize(width: 240, height: 150))
        let tallerGlow = settings.geometry(islandWidth: taller.width, islandHeight: taller.height, islandRadius: 26)

        controller.update(geometry: geometry, island: taller, islandRadius: 26, glow: tallerGlow,
            outwardOnly: true, appearance: .idle(), animated: false, prepared: prepared)
        let soft = try XCTUnwrap(controller.glowLayer.contents) as! CGImage
        let shadow = try XCTUnwrap(controller.shadowLayer.contents) as! CGImage
        XCTAssertFalse(soft === (try XCTUnwrap(prepared.soft)).image)
        XCTAssertFalse(shadow === (try XCTUnwrap(prepared.shadow)).image)
        XCTAssertEqual(shadow.height, Int((taller.height + 90) * geometry.backingScale))
    }

    @MainActor
    func testGridPreparationReusesTheRestingImageAndRejectsChangedPattern() throws {
        _ = NSApplication.shared
        let geometry = geometry()
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.close() }
        let island = geometry.expandedFrame(size: CGSize(width: 240, height: 120))
        var settings = GlowSettings()
        settings.style = .dots
        let glow = settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 26)
        let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle(), pattern: settings.pattern())
        let resting = try XCTUnwrap(prepared.resting)
        XCTAssertNotNil(prepared.renderer)

        controller.update(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle(), animated: false, pattern: settings.pattern(), prepared: prepared)
        XCTAssertTrue(controller.glowLayer.contents as AnyObject? === resting.image)
        settings.gridDensity = 1.5
        controller.update(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: .idle(), animated: false, pattern: settings.pattern(), prepared: prepared)
        XCTAssertFalse(controller.glowLayer.contents as AnyObject? === resting.image)
    }

    @MainActor
    func testSoftEffectPreparationKeepsItsSetupWithoutStartingAnAnimation() throws {
        _ = NSApplication.shared
        let geometry = geometry()
        let controller = GlowWindowController(geometry: geometry)
        defer { controller.close() }
        let island = geometry.expandedFrame(size: CGSize(width: 240, height: 120))
        var settings = GlowSettings()
        settings.effect = .flow
        let glow = settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 26)
        let active = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: true, glow: settings)
        let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: glow,
            outwardOnly: true, appearance: active, pattern: settings.pattern())
        let renderer = try XCTUnwrap(prepared.renderer)
        let first = try XCTUnwrap(renderer.render(time: 0, blend: 0, breathSeconds: 3, breathAmplitude: 0.6))
        let later = try XCTUnwrap(renderer.render(time: 1, blend: 0, breathSeconds: 3, breathAmplitude: 0.6))
        XCTAssertTrue(first.image === later.image, "The dynamic renderer retains its prepared resting bitmap")
        XCTAssertFalse(controller.isAnimating)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertNil(controller.glowLayer.contents)
        XCTAssertNil(controller.shadowLayer.contents)
    }

    @MainActor
    func testFourEdgeDockPreparationUsesTheSameCanonicalCoreAsOpening() throws {
        _ = NSApplication.shared
        for edge in HUDEdge.allCases {
            let geometry = geometry(edge: edge, mode: .logos)
            let controller = GlowWindowController(geometry: geometry)
            defer { controller.close() }
            let flare = NotchGeometry.expandedTopRadius
            let horizontal = edge.isHorizontal
            let card = geometry.expandedFrame(size: CGSize(width: 240 + (horizontal ? flare * 2 : 0),
                                                           height: 120 + (horizontal ? 0 : flare * 2)))
            let island = card.insetBy(dx: horizontal ? flare : 0, dy: horizontal ? 0 : flare)
            let local = GlowWindowController.canonicalIslandFrame(island,
                panel: GlowWindowController.panelFrame(for: geometry), edge: edge)
            XCTAssertEqual(island.size, CGSize(width: 240, height: 120), "\(edge): materials use the card core")
            XCTAssertEqual(local.size, horizontal ? island.size : CGSize(width: island.height, height: island.width))
            let settings = GlowSettings()
            let glow = settings.geometry(islandWidth: local.width, islandHeight: local.height, islandRadius: 26)
            let prepared = controller.prepare(geometry: geometry, island: island, islandRadius: 26, glow: glow,
                outwardOnly: true, appearance: .idle())

            controller.update(geometry: geometry, island: island, islandRadius: 26, glow: glow,
                outwardOnly: true, appearance: .idle(), animated: true, prepared: prepared)
            let shadow = try XCTUnwrap(prepared.shadow)
            XCTAssertEqual(shadow.image.width, Int((local.width + 90) * geometry.backingScale))
            XCTAssertEqual(shadow.image.height, Int((local.height + 90) * geometry.backingScale))
            XCTAssertTrue(controller.shadowLayer.contents as AnyObject? === shadow.image,
                          "\(edge): opening reuses the prepared shadow bitmap")
            XCTAssertTrue(controller.glowLayer.contents as AnyObject? === (try XCTUnwrap(prepared.soft)).image)
        }
    }

    private func geometry(edge: HUDEdge = .top, mode: HUDMode? = nil) -> NotchGeometry {
        let screen = CGRect(x: -20000, y: -20000, width: 1000, height: 800)
        let queue = edge.isHorizontal ? CGSize(width: 200, height: 24) : CGSize(width: 24, height: 200)
        let rect = NotchGeometry.stripRect(queue: queue, frame: screen, menuBar: 24,
                                          placement: ScreenPlacement(edge: edge))
        return NotchGeometry(screenFrame: screen, mode: mode ?? (edge == .top ? .notch : .logos), edge: edge, hasNotch: false,
            rect: rect,
            cornerRadius: 12, backingScale: 2, menuBarHeight: 24)
    }

    private func pixels(_ image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data) as Data
    }
}
