import SwiftUI
import AgentHUDCore

extension EnvironmentValues {
    /// Draws one fixed moment of the grid glow effects instead of animating them (snapshots).
    @Entry var glowFrozenTime: Double? = nil
}

/// Uses the desktop glow renderer for settings previews, onboarding and snapshots.
/// Soft breathing animates layer opacity using the current settings; grid effects play
/// through the same layer animator as the notch.
struct GlowPreview: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glowFrozenTime) private var frozenTime
    /// A preview in a window nobody is looking at still renders every frame; this stops it.
    @Environment(\.controlActiveState) private var activeState
    @State private var imageCache = GlowImageCache()
    @State private var frameCache = GlowFrameCache()
    let appearance: GlowAppearance
    /// The glow being previewed: the selected screen's, not necessarily the default one.
    let settings: GlowSettings
    let islandSize: CGSize
    let islandRadius: CGFloat
    /// Scale applied to range/blur so small previews keep the proportions of the real notch.
    var scale: CGFloat = 1
    var lightBorder = false
    /// Plays the grid effect even while no agent is running, so settings can show what each effect looks like.
    var previewsMotion = false
    /// Draws the island the glow radiates from. A logo queue has no silhouette — the field is its backdrop —
    /// so it asks for the glow alone.
    var drawsIsland = true

    var body: some View {
        let glow = settings.geometry(islandWidth: islandSize.width, islandHeight: islandSize.height,
                                     islandRadius: islandRadius, scale: scale)
        let pattern = settings.pattern(scale: scale)
        let key = GlowFrameRenderer.Key(glow: glow, islandRadius: islandRadius, stops: appearance.stops,
                                        scale: displayScale, pattern: pattern,
                                        islandSize: islandSize, outwardOnly: settings.outwardOnly)
        // Grid styles and every soft effect but breathing draw frame by frame; soft breathing pulses the bitmap.
        let framed = pattern.usesGrid || pattern.effect != .breathe
        let animates = framed && !appearance.hidden && !reduceMotion && frozenTime == nil
            && activeState != .inactive
            && (appearance.breathing || previewsMotion)
        // Soft bitmaps carry a blur margin on every side.
        let padding = pattern.usesGrid ? 0 : ceil(max(0, glow.blur) * 3)
        // Cache the resting bitmap so breathing only changes its layer's opacity.
        let still: GlowImage? = {
            guard !appearance.hidden, !animates else { return nil }
            if framed, let frozenTime {
                return frameCache.renderer(for: key).render(time: frozenTime, blend: 1, breathSeconds: settings.breathSeconds,
                                                            breathAmplitude: settings.breathAmplitude)
            }
            return imageCache.render(glow: glow, islandSize: islandSize, islandRadius: islandRadius,
                                     outwardOnly: settings.outwardOnly, stops: appearance.stops, scale: displayScale,
                                     pattern: pattern)
        }()
        // A soft pulse changes only layer opacity. Keeping its clock out of SwiftUI avoids rebuilding and
        // laying out the preview on every display refresh.
        let pulses = !animates && !appearance.hidden && !reduceMotion && appearance.breathing
            && frozenTime == nil && activeState != .inactive
        ZStack(alignment: .top) {
            if animates {
                GlowEffectView(key: key, breathSeconds: settings.breathSeconds, breathAmplitude: settings.breathAmplitude)
                    .frame(width: glow.width + padding * 2, height: glow.height + padding * 2)
                    .frame(width: glow.width, height: glow.height)
                    .opacity(appearance.peakOpacity)
                    .offset(y: glow.topOffset)
            } else if let still {
                GlowBitmapView(image: still.image, scale: displayScale, appearance: appearance, pulses: pulses)
                    .frame(width: still.size.width, height: still.size.height)
                    .frame(width: glow.width, height: glow.height)
                    .offset(y: glow.topOffset)
            }
            if drawsIsland {
                BottomRoundedRectangle(radius: islandRadius)
                    .fill(Color.black)
                    .overlay {
                        if lightBorder {
                            BottomRoundedRectangle(radius: islandRadius).stroke(Color.white.opacity(0.18), lineWidth: 1)
                        }
                    }
                    .frame(width: islandSize.width, height: islandSize.height)
            }
        }
    }

    /// Cosine breathing between peak and trough with period `breathSeconds`.
    static func opacity(_ appearance: GlowAppearance, at date: Date) -> Double {
        guard appearance.breathing, appearance.breathSeconds > 0 else { return appearance.peakOpacity }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: appearance.breathSeconds) / appearance.breathSeconds
        let wave = 0.5 - 0.5 * cos(phase * 2 * .pi)
        return appearance.peakOpacity - (appearance.peakOpacity - appearance.troughOpacity) * wave
    }
}

/// Plays a grid glow effect inside SwiftUI through the notch's layer animator, so a running preview costs no
/// SwiftUI updates or image conversions per frame.
struct GlowEffectView: NSViewRepresentable {
    let key: GlowFrameRenderer.Key
    let breathSeconds: Double
    let breathAmplitude: Double

    func makeNSView(context: Context) -> GlowEffectLayerView { GlowEffectLayerView() }

    func updateNSView(_ view: GlowEffectLayerView, context: Context) {
        view.play(key, breathSeconds: breathSeconds, breathAmplitude: breathAmplitude)
    }

    static func dismantleNSView(_ view: GlowEffectLayerView, coordinator: ()) {
        view.stop()
    }
}

/// Window attachment alone is not visibility: closed and minimized windows still own their views.
/// Both preview paths stop their animations while the window is off screen or covered.
class GlowPreviewLayerView: NSView {
    var isVisibleForAnimation: Bool {
        window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateVisibility()
        // Attachment precedes orderFront on a newly created window. Check once after that turn, even if
        // AppKit established the occlusion state before the observer was registered.
        Task { @MainActor [weak self] in self?.updateVisibility() }
    }

    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

    @objc private func visibilityChanged(_ notification: Notification) { updateVisibility() }

    func updateVisibility() {}
}

struct GlowBitmapView: NSViewRepresentable {
    let image: CGImage
    let scale: CGFloat
    let appearance: GlowAppearance
    let pulses: Bool

    func makeNSView(context: Context) -> GlowBitmapLayerView { GlowBitmapLayerView() }

    func updateNSView(_ view: GlowBitmapLayerView, context: Context) {
        view.update(image: image, scale: scale, appearance: appearance, pulses: pulses)
    }

    static func dismantleNSView(_ view: GlowBitmapLayerView, coordinator: ()) { view.stop() }
}

final class GlowBitmapLayerView: GlowPreviewLayerView {
    let bitmapLayer = CALayer()
    private var glowAppearance: GlowAppearance?
    private var pulses = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bitmapLayer.contentsGravity = .resize
        layer?.addSublayer(bitmapLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bitmapLayer.frame = bounds
        CATransaction.commit()
    }

    func update(image: CGImage, scale: CGFloat, appearance: GlowAppearance, pulses: Bool) {
        let changed = glowAppearance != appearance || self.pulses != pulses
        glowAppearance = appearance
        self.pulses = pulses
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bitmapLayer.contents = image
        bitmapLayer.contentsScale = scale
        bitmapLayer.opacity = Float(appearance.peakOpacity)
        CATransaction.commit()
        if changed { stop() }
        updateVisibility()
    }

    func stop() { bitmapLayer.removeAnimation(forKey: "breathe") }

    override func updateVisibility() {
        guard isVisibleForAnimation, pulses, let appearance = glowAppearance, appearance.breathSeconds > 0,
              appearance.peakOpacity != appearance.troughOpacity else { return stop() }
        guard bitmapLayer.animation(forKey: "breathe") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = appearance.peakOpacity
        animation.toValue = appearance.troughOpacity
        animation.duration = appearance.breathSeconds / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bitmapLayer.add(animation, forKey: "breathe")
    }
}

final class GlowEffectLayerView: GlowPreviewLayerView {
    private let effectLayer = CALayer()
    private let frames = GlowFrameCache()
    private lazy var animator = GlowAnimator(host: self, layer: effectLayer)
    private var request: (key: GlowFrameRenderer.Key, breathSeconds: Double, breathAmplitude: Double)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effectLayer.contentsGravity = .resize
        layer?.addSublayer(effectLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.frame = bounds
        CATransaction.commit()
    }

    var isAnimating: Bool { animator.isRunning }

    override func updateVisibility() { resume() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resume()
    }

    func play(_ key: GlowFrameRenderer.Key, breathSeconds: Double, breathAmplitude: Double) {
        request = (key, breathSeconds, breathAmplitude)
        resume()
    }

    func stop() {
        animator.stop()
        request = nil
    }

    /// Starts once the view is on screen, drawing in that screen's colour space and scale.
    private func resume() {
        guard isVisibleForAnimation, let request, let window else { return animator.stop() }
        var key = request.key
        key.colorSpace = window.screen?.colorSpace?.cgColorSpace
        effectLayer.contentsScale = window.backingScaleFactor
        animator.play(frames.renderer(for: key), breathSeconds: request.breathSeconds, breathAmplitude: request.breathAmplitude)
    }
}
