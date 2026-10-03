import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class PreviewLifecycleTests: XCTestCase {
    @MainActor
    func testDisplayLinkRateFollowsIdlePeriodAndSharedDrawingBudget() {
        XCTAssertEqual(GlowAnimator.requestedFrameRate(breathSeconds: 3, frameCost: 0, activeGlows: 1), 24)
        XCTAssertEqual(GlowAnimator.requestedFrameRate(breathSeconds: 24, frameCost: 0, activeGlows: 1), 8)
        let single = GlowAnimator.requestedFrameRate(breathSeconds: 3, frameCost: 0.01, activeGlows: 1)
        let multiple = GlowAnimator.requestedFrameRate(breathSeconds: 3, frameCost: 0.01, activeGlows: 2)
        XCTAssertEqual(single, 8)
        XCTAssertEqual(multiple, 4)
        XCTAssertGreaterThanOrEqual(GlowAnimator.requestedFrameRate(breathSeconds: 3, frameCost: 1, activeGlows: 3), 1)
    }

    @MainActor
    func testSoftPreviewKeepsOneBitmapAndStopsWhenItsWindowCloses() {
        let appearance = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: true, glow: GlowSettings())
        let view = GlowBitmapLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        let key = rendererKey(style: .blur)
        guard let image = GlowFrameRenderer.resting(key)?.image else { return XCTFail("The preview bitmap must render") }
        view.update(image: image, scale: 2, appearance: appearance, pulses: true)
        XCTAssertNil(view.bitmapLayer.animation(forKey: "breathe"), "A detached preview has no animation clock")
        let window = makeWindow(view)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        XCTAssertNotNil(view.bitmapLayer.animation(forKey: "breathe"))
        XCTAssertTrue(view.bitmapLayer.contents as AnyObject? === image, "Breathing reuses the resting bitmap")

        // A data refresh must not start the pulse over. Mark the installed animation's start to detect replacement.
        guard let animation = view.bitmapLayer.animation(forKey: "breathe")?.copy() as? CAAnimation else {
            return XCTFail("The pulse must be installed")
        }
        animation.beginTime = CACurrentMediaTime() - 1
        view.bitmapLayer.add(animation, forKey: "breathe")
        view.update(image: image, scale: 2, appearance: appearance, pulses: true)
        XCTAssertEqual(view.bitmapLayer.animation(forKey: "breathe")?.beginTime, animation.beginTime)

        window.setCovered(true)
        XCTAssertNil(view.bitmapLayer.animation(forKey: "breathe"), "A covered preview stops even though the window stays open")
        window.setCovered(false)
        XCTAssertNotNil(view.bitmapLayer.animation(forKey: "breathe"))

        window.orderOut(nil)
        XCTAssertNil(view.bitmapLayer.animation(forKey: "breathe"), "A closed window still owns its preview, but must stop pulsing")
        window.orderFrontRegardless()
        XCTAssertNotNil(view.bitmapLayer.animation(forKey: "breathe"), "Showing the window resumes the pulse")
        view.update(image: image, scale: 2, appearance: appearance, pulses: false)
        XCTAssertNil(view.bitmapLayer.animation(forKey: "breathe"), "Reduce Motion and frozen snapshots stay still")
    }

    @MainActor
    func testGridPreviewStopsWhenHiddenClosedOrDetachedAndResumesWhenShown() {
        let view = GlowEffectLayerView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        view.play(rendererKey(style: .dots), breathSeconds: 3, breathAmplitude: 0.6)
        XCTAssertFalse(view.isAnimating)
        let window = makeWindow(view)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        XCTAssertTrue(view.isAnimating)
        view.isHidden = true
        XCTAssertFalse(view.isAnimating)
        view.isHidden = false
        XCTAssertTrue(view.isAnimating)
        window.orderOut(nil)
        XCTAssertFalse(view.isAnimating)
        window.orderFrontRegardless()
        XCTAssertTrue(view.isAnimating)
        window.contentView = nil
        XCTAssertFalse(view.isAnimating)
    }

    @MainActor
    private func makeWindow(_ view: NSView) -> PreviewVisibilityWindow {
        _ = NSApplication.shared
        let window = PreviewVisibilityWindow(contentRect: CGRect(x: -20000, y: -20000, width: 260, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        return window
    }

    private func rendererKey(style: GlowStyle) -> GlowFrameRenderer.Key {
        let settings = GlowSettings()
        let island = CGSize(width: 240, height: 30)
        return .init(glow: settings.geometry(islandWidth: island.width, islandHeight: island.height, islandRadius: 13),
                     islandRadius: 13, stops: GlowGradient.stops(levels: [.ok]), scale: 2,
                     pattern: GlowPattern(style: style), islandSize: island, outwardOnly: true)
    }
}

/// The display server may mark every XCTest window occluded. Supply its visibility notifications explicitly
/// while exercising real view attachment, hiding and window ordering, without depending on the user's desktop.
@MainActor
private final class PreviewVisibilityWindow: NSWindow {
    private var covered = false
    override var occlusionState: NSWindow.OcclusionState { isVisible && !covered ? [.visible] : [] }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        notifyVisibility()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        notifyVisibility()
    }

    func setCovered(_ covered: Bool) {
        self.covered = covered
        notifyVisibility()
    }

    private func notifyVisibility() {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
