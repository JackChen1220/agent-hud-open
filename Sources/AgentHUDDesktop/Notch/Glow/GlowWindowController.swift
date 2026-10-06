import AppKit
import QuartzCore
import AgentHUDCore

/// Click-through window that hosts the glow bitmap and the expanded panel's drop shadow.
/// The canvas spans the display height and stays fixed during expansion; only the layers inside move.
@MainActor
final class GlowWindowController {
    let panel: OverlayPanel
    private let host = NSView()
    /// Render every material in the existing top-edge coordinate space, then turn the canvas toward the
    /// chosen edge. This keeps the soft bitmap, grid shaders, alerts and shadow on one orientation.
    private let materialCanvas = CALayer()
    let glowLayer = CALayer()
    let shadowLayer = CALayer()
    private let alertLayer = CALayer()
    /// Fades the backdrop out at the ends. Clipping it to the queue's width leaves a cut edge; a queue has
    /// no silhouette to justify one, so the field dies away instead.
    private let edgeFade = CAGradientLayer()
    private var lastAlertID: String?
    private var softKey: SoftKey?
    private var glowPadding: CGFloat = 0
    private var shadowKey: ShadowKey?
    private var shadowPadding: CGFloat = 0
    private var breathKey: BreathKey?
    private var restingKey: GlowFrameRenderer.Key?
    /// The soft glow's resting bitmap, restored when a frame-by-frame effect stops.
    private var softStill: CGImage?
    private var frameRenderer: GlowFrameRenderer?
    private lazy var animator = GlowAnimator(host: host, layer: glowLayer)
    var isAnimating: Bool { animator.isRunning }

    static let panelWidth: CGFloat = 1000

    /// Inputs of the soft glow bitmap.
    fileprivate struct SoftKey: Hashable {
        let glow: GlowGeometry
        let islandSize: CGSize
        let islandRadius: CGFloat
        let outwardOnly: Bool
        let stops: [GradientStop]
        let scale: CGFloat
    }

    fileprivate struct ShadowKey: Hashable {
        let size: CGSize
        let radius: CGFloat
        let scale: CGFloat
    }

    private struct BreathKey: Hashable {
        let pulses: Bool
        let peakOpacity: Double
        let troughOpacity: Double
        let breathSeconds: Double
    }

    /// Materials for one pending opening. The hover owner retains these until the panel opens or the pointer leaves.
    struct PreparedImages {
        fileprivate let softKey: SoftKey
        let soft: GlowImage?
        fileprivate let shadowKey: ShadowKey
        let shadow: GlowImage?
        let renderer: GlowFrameRenderer?
        let resting: GlowImage?
    }

    init(geometry: NotchGeometry) {
        panel = OverlayPanel(frame: Self.panelFrame(for: geometry), level: .statusBar, acceptsMouse: false)
        panel.setAccessibilityElement(false)
        panel.setAccessibilityHidden(true)
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        panel.contentView = host
        host.layer?.addSublayer(materialCanvas)
        for layer in [shadowLayer, glowLayer, alertLayer] {
            layer.contentsGravity = .resize
            layer.contentsScale = geometry.backingScale
            layer.anchorPoint = .zero
            materialCanvas.addSublayer(layer)
        }
        shadowLayer.opacity = 0
        alertLayer.opacity = 0
    }

    /// How far the backdrop reaches past the last mark, and the distance it fades over. Taken by thickness
    /// rather than geometry so the settings preview sizes its own backdrop from the same rule.
    static func logoEdgeMargin(stripThickness: CGFloat) -> CGFloat {
        max(12, stripThickness * 0.6)
    }

    static func logoEdgeMargin(for geometry: NotchGeometry) -> CGFloat {
        logoEdgeMargin(stripThickness: geometry.edge.isHorizontal ? geometry.rect.height : geometry.rect.width)
    }

    /// How far the backdrop's lip is run past the queue on each side, so that every cell's nearest point on
    /// it is straight above and the field falls vertically instead of curling in at the ends. The settings
    /// preview builds its own lip from this rule rather than a number of its own.
    static func backdropOverhang(_ glow: GlowSettings) -> CGFloat {
        glow.range + glow.blur * 3 + NotchGeometry.fallbackWidth
    }

    static func panelFrame(for geometry: NotchGeometry) -> CGRect {
        // A logo queue's panel spans the screen, because the island it holds does not stay the width of the
        // marks: an event widens it by a wing on each side, and the open panel is wider still. What keeps
        // the backdrop to the marks' own column is the fade below, which applies only while it is a backdrop.
        guard geometry.mode != .logos else { return geometry.screenFrame }
        return CGRect(
            x: geometry.centerX - panelWidth / 2,
            y: geometry.screenFrame.minY,
            width: panelWidth,
            height: geometry.screenFrame.height
        )
    }

    /// Keeps a backdrop to `column`, dying away over `margin` on each side. Passing no column removes the
    /// mask: an island that has grown — for an event, or because the panel opened — wants its whole rim,
    /// not the slice of it that fits the marks' column.
    private func updateEdgeFade(column: CGRect?, margin: CGFloat, panel: CGRect, edge: HUDEdge) {
        let horizontal = edge.isHorizontal
        let length = horizontal ? panel.width : panel.height
        guard let column, length > 0 else {
            if host.layer?.mask != nil { host.layer?.mask = nil }
            return
        }
        let bounds = CGRect(origin: .zero, size: panel.size)
        let start = horizontal ? panel.minX : panel.minY
        let lower = horizontal ? column.minX : column.minY
        let upper = horizontal ? column.maxX : column.maxY
        func stop(_ coordinate: CGFloat) -> NSNumber {
            NSNumber(value: Double(min(1, max(0, (coordinate - start) / length))))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = bounds
        edgeFade.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        edgeFade.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        edgeFade.colors = [
            CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0),
        ]
        edgeFade.locations = [stop(lower - margin), stop(lower), stop(upper), stop(upper + margin)]
        if host.layer?.mask !== edgeFade { host.layer?.mask = edgeFade }
        CATransaction.commit()
    }

    /// The island expressed with its parked edge at the top. For vertical queues, increasing x follows
    /// the marks from top to bottom, preserving agent colours in the same order as their logos.
    nonisolated static func canonicalIslandFrame(_ island: CGRect, panel: CGRect, edge: HUDEdge) -> CGRect {
        let local = island.offsetBy(dx: -panel.minX, dy: -panel.minY)
        switch edge {
        case .top: return local
        case .bottom:
            return CGRect(x: local.minX, y: panel.height - local.maxY, width: local.width, height: local.height)
        case .left:
            return CGRect(x: panel.height - local.maxY, y: panel.width - local.maxX,
                          width: local.height, height: local.width)
        case .right:
            return CGRect(x: panel.height - local.maxY, y: local.minX,
                          width: local.height, height: local.width)
        }
    }

    private func orientCanvas(in frame: CGRect, edge: HUDEdge) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        materialCanvas.bounds = CGRect(origin: .zero, size: edge.isHorizontal
            ? frame.size : CGSize(width: frame.height, height: frame.width))
        materialCanvas.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let transform: CGAffineTransform
        switch edge {
        case .top: transform = .identity
        case .bottom: transform = CGAffineTransform(scaleX: 1, y: -1)
        case .left: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        }
        materialCanvas.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// Prepares the open panel while its hover delay runs, leaving the collapsed HUD and its animation untouched.
    func prepare(
        geometry: NotchGeometry,
        island: CGRect,
        islandRadius: CGFloat,
        glow: GlowGeometry,
        outwardOnly: Bool,
        appearance: GlowAppearance,
        pattern: GlowPattern = GlowPattern(),
        drawsGlow: Bool = true
    ) -> PreparedImages {
        let local = Self.canonicalIslandFrame(island, panel: Self.panelFrame(for: geometry), edge: geometry.edge)
        let scale = geometry.backingScale
        let softKey = SoftKey(glow: glow, islandSize: local.size, islandRadius: islandRadius,
                              outwardOnly: outwardOnly, stops: appearance.stops, scale: scale)
        let shadowKey = ShadowKey(size: local.size, radius: islandRadius, scale: scale)
        let visible = !appearance.hidden
        let soft = visible && drawsGlow && !pattern.usesGrid
            ? GlowRenderer.render(glow: glow, islandSize: local.size, islandRadius: islandRadius,
                                  outwardOnly: outwardOnly, stops: appearance.stops, scale: scale)
            : nil
        let shadow = visible
            ? GlowRenderer.renderShadow(width: local.width, height: local.height, cornerRadius: islandRadius, scale: scale)
            : nil
        let renderer: GlowFrameRenderer?
        if visible && drawsGlow && (pattern.usesGrid || pattern.effect != .breathe) {
            renderer = GlowFrameRenderer(.init(glow: glow, islandRadius: islandRadius, stops: appearance.stops,
                scale: scale, pattern: pattern, colorSpace: panel.screen?.colorSpace?.cgColorSpace,
                islandSize: pattern.usesGrid ? .zero : local.size, outwardOnly: pattern.usesGrid ? true : outwardOnly))
        } else {
            renderer = nil
        }
        let motion = Self.playsMotion(pattern: pattern, appearance: appearance,
                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let resting = pattern.usesGrid && !motion
            ? renderer?.render(time: 0, blend: 0, breathSeconds: 0, breathAmplitude: 0)
            : nil
        return PreparedImages(softKey: softKey, soft: soft, shadowKey: shadowKey, shadow: shadow,
                              renderer: renderer, resting: resting)
    }

    /// - island: the island's current frame in screen coordinates.
    func update(
        geometry: NotchGeometry,
        island: CGRect,
        islandRadius: CGFloat,
        glow: GlowGeometry,
        outwardOnly: Bool,
        appearance: GlowAppearance,
        animated: Bool,
        alert: IslandAlert? = nil,
        quotaVendors: [String] = [],
        pattern: GlowPattern = GlowPattern(),
        /// The marks' own column, when the glow is a logo queue's backdrop rather than a rim around a shape.
        backdrop: CGRect? = nil,
        /// A logo queue's glow is a backdrop behind its marks, never a rim: once the panel has grown there
        /// is no backdrop left to draw, so the field stops rather than following the new shape around. The
        /// panel keeps its shadow, which lives here too.
        drawsGlow: Bool = true,
        prepared: PreparedImages? = nil
    ) {
        let frame = Self.panelFrame(for: geometry)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // The host has not been resized to the new panel frame yet; the fade is measured against it directly.
        updateEdgeFade(column: backdrop, margin: Self.logoEdgeMargin(for: geometry), panel: frame, edge: geometry.edge)
        orientCanvas(in: frame, edge: geometry.edge)
        glowLayer.contentsScale = geometry.backingScale
        shadowLayer.contentsScale = geometry.backingScale

        if appearance.hidden {
            animator.stop()
            softKey = nil
            restingKey = nil
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible { panel.orderFrontRegardless() }

        // Bitmaps and shader geometry retain their top-edge convention, including on a vertical dock.
        let local = Self.canonicalIslandFrame(island, panel: frame, edge: geometry.edge)
        let glowTop = local.maxY - glow.topOffset
        let glowRect = CGRect(x: local.minX - glow.sideInset, y: glowTop - glow.height, width: glow.width, height: glow.height)

        if drawsGlow {
            let motion = Self.playsMotion(pattern: pattern, appearance: appearance,
                                          reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            if pattern.usesGrid {
                updateGridImage(glow: glow, islandRadius: islandRadius, stops: appearance.stops, scale: geometry.backingScale,
                                pattern: pattern, appearance: appearance, motion: motion, prepared: prepared)
            } else {
                restingKey = nil
                updateSoftImage(glow: glow, islandSize: local.size, islandRadius: islandRadius, outwardOnly: outwardOnly,
                                stops: appearance.stops, scale: geometry.backingScale, pattern: pattern, appearance: appearance,
                                motion: motion, prepared: prepared)
            }
        } else {
            animator.stop()
            softKey = nil
            restingKey = nil
            glowLayer.contents = nil
        }
        updateShadowImage(island: local, radius: islandRadius, scale: geometry.backingScale, prepared: prepared)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(IslandAnimation.duration)
            CATransaction.setAnimationTimingFunction(IslandAnimation.mediaCurve)
        } else {
            CATransaction.setDisableActions(true)
        }
        glowLayer.frame = glowRect.insetBy(dx: -glowPadding, dy: -glowPadding)
        alertLayer.frame = glowLayer.frame
        shadowLayer.frame = local.offsetBy(dx: 0, dy: -8).insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowLayer.opacity = 1
        CATransaction.commit()

        // A running grid effect carries the breathing itself; otherwise the whole layer pulses.
        applyBreathing(appearance, pulsesOpacity: !animator.isRunning)
        // The alert's colour is carried by the glow, so it goes wherever the glow does.
        guard drawsGlow else {
            lastAlertID = nil
            alertLayer.opacity = 0
            return
        }
        applyAlert(alert, vendors: quotaVendors, glow: glow, islandSize: local.size, radius: islandRadius,
                   outwardOnly: outwardOnly, scale: geometry.backingScale, pattern: pattern)
    }

    /// Effects play frame by frame while an agent is running, collapsed or expanded alike; Reduce Motion keeps the
    /// resting frame. The soft glow's breathing stays a Core Animation opacity pulse.
    nonisolated static func playsMotion(pattern: GlowPattern, appearance: GlowAppearance, reduceMotion: Bool) -> Bool {
        (pattern.usesGrid || pattern.effect != .breathe) && appearance.breathing && !appearance.hidden && !reduceMotion
    }

    /// How deep the appearance breathes, as the fraction of brightness it loses at the trough.
    private static func breathDepth(_ appearance: GlowAppearance) -> Double {
        appearance.peakOpacity > 0 ? 1 - appearance.troughOpacity / appearance.peakOpacity : 0
    }

    /// The blurred bitmap stretches through its nine-slice centre while the island animates; a grid of dots
    /// would distort, so those bitmaps stay at native size, pinned to the screen edge, and the animating frame
    /// reveals or hides rows instead.
    private func configure(_ layer: CALayer, for style: GlowStyle, image: GlowImage, side: CGFloat, bottom: CGFloat) {
        if style == .blur {
            layer.contentsGravity = .resize
            layer.masksToBounds = false
            layer.contentsCenter = contentsCenter(for: image, side: side, bottom: bottom)
        } else {
            layer.contentsGravity = .top
            layer.masksToBounds = true
            layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    private func applyAlert(_ alert: IslandAlert?, vendors: [String], glow: GlowGeometry, islandSize: CGSize,
                            radius: CGFloat, outwardOnly: Bool, scale: CGFloat, pattern: GlowPattern) {
        guard lastAlertID != alert?.id else { return }
        lastAlertID = alert?.id
        alertLayer.removeAllAnimations()
        guard let alert else { return }
        let color = alert.accent
        let clear = color.withAlpha(0)
        let matches = vendors.indices.filter { vendors[$0] == alert.vendor }
        let stops: [GradientStop]
        if let first = matches.first, let last = matches.last {
            let count = Double(vendors.count)
            let left = Double(first) / count, right = Double(last + 1) / count
            let feather = 0.15 / count
            stops = [GradientStop(color: clear, location: max(0, left - feather)),
                     GradientStop(color: color, location: left + feather),
                     GradientStop(color: color, location: right - feather),
                     GradientStop(color: clear, location: min(1, right + feather))]
        } else {
            stops = [GradientStop(color: color, location: 0), GradientStop(color: color, location: 1)]
        }
        guard let rendered = GlowFrameRenderer.resting(.init(glow: glow, islandRadius: radius, stops: stops, scale: scale,
                                                             pattern: pattern, islandSize: islandSize,
                                                             outwardOnly: outwardOnly)) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alertLayer.contents = rendered.image
        alertLayer.contentsScale = scale
        configure(alertLayer, for: pattern.style, image: rendered, side: glow.sideInset + radius, bottom: glow.sideInset + radius)
        CATransaction.commit()
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pulse.values = [0, 0.12, 0]
            pulse.keyTimes = [0, 0.3, 1]
        } else if alert.isWarning {
            pulse.values = [0, 0.22, 0.05, 0.22, 0]
            pulse.keyTimes = [0, 0.2, 0.45, 0.65, 1]
        } else {
            pulse.values = [0, 0.22, 0.15, 0]
            pulse.keyTimes = [0, 0.25, 0.65, 1]
        }
        pulse.duration = 1.8
        pulse.calculationMode = .linear
        alertLayer.add(pulse, forKey: "quota-event")
    }

    private func renderer(for key: GlowFrameRenderer.Key, prepared: PreparedImages?) -> GlowFrameRenderer {
        if let frameRenderer, frameRenderer.key == key { return frameRenderer }
        let renderer = prepared?.renderer.flatMap { $0.key == key ? $0 : nil } ?? GlowFrameRenderer(key)
        frameRenderer = renderer
        return renderer
    }

    private func updateGridImage(glow: GlowGeometry, islandRadius: CGFloat, stops: [GradientStop], scale: CGFloat,
                                 pattern: GlowPattern, appearance: GlowAppearance, motion: Bool, prepared: PreparedImages?) {
        let renderer = renderer(for: .init(glow: glow, islandRadius: islandRadius, stops: stops, scale: scale, pattern: pattern,
                                           colorSpace: panel.screen?.colorSpace?.cgColorSpace), prepared: prepared)
        let resting = prepared?.renderer?.key == renderer.key ? prepared?.resting : nil
        softKey = nil
        glowPadding = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contentsGravity = .top
        glowLayer.masksToBounds = true
        glowLayer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
        if motion {
            restingKey = nil
            animator.play(renderer, breathSeconds: appearance.breathSeconds, breathAmplitude: Self.breathDepth(appearance))
        } else if animator.isRunning && !appearance.hidden {
            // The last agent went idle: ease back into the resting frame.
            animator.settle(renderer) { [weak self] in self?.showResting(renderer, image: resting) }
        } else {
            animator.stop()
            showResting(renderer, image: resting)
        }
    }

    /// The soft glow keeps its nine-slice bitmap. Effects other than breathing swap in frames of the same size and
    /// layout, and hand the resting bitmap back when they stop.
    private func updateSoftImage(glow: GlowGeometry, islandSize: CGSize, islandRadius: CGFloat, outwardOnly: Bool, stops: [GradientStop],
                                 scale: CGFloat, pattern: GlowPattern, appearance: GlowAppearance, motion: Bool,
                                 prepared: PreparedImages?) {
        updateGlowImage(glow: glow, islandSize: islandSize, islandRadius: islandRadius, outwardOnly: outwardOnly,
                        stops: stops, scale: scale, prepared: prepared)
        guard pattern.effect != .breathe else { return stopSoftMotion() }
        let renderer = renderer(for: .init(glow: glow, islandRadius: islandRadius, stops: stops, scale: scale, pattern: pattern,
                                           colorSpace: panel.screen?.colorSpace?.cgColorSpace,
                                           islandSize: islandSize, outwardOnly: outwardOnly), prepared: prepared)
        if motion {
            animator.play(renderer, breathSeconds: appearance.breathSeconds, breathAmplitude: Self.breathDepth(appearance))
        } else if animator.isRunning && !appearance.hidden {
            animator.settle(renderer) { [weak self] in self?.restoreSoftStill() }
        } else {
            stopSoftMotion()
        }
    }

    /// Takes the glow off screen for good, with its display link: the display went away with the HUD.
    func close() {
        animator.stop()
        panel.orderOut(nil)
    }

    private func stopSoftMotion() {
        guard animator.isRunning else { return }
        animator.stop()
        restoreSoftStill()
    }

    private func restoreSoftStill() {
        guard let softStill else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = softStill
        CATransaction.commit()
    }

    private func showResting(_ renderer: GlowFrameRenderer, image: GlowImage? = nil) {
        guard restingKey != renderer.key,
              let rendered = image ?? renderer.render(time: 0, blend: 0, breathSeconds: 0, breathAmplitude: 0) else { return }
        restingKey = renderer.key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = rendered.image
        CATransaction.commit()
    }

    private func updateGlowImage(glow: GlowGeometry, islandSize: CGSize, islandRadius: CGFloat, outwardOnly: Bool,
                                 stops: [GradientStop], scale: CGFloat, prepared: PreparedImages?) {
        let key = SoftKey(glow: glow, islandSize: islandSize, islandRadius: islandRadius, outwardOnly: outwardOnly, stops: stops, scale: scale)
        guard key != softKey else { return }
        guard let rendered = (prepared?.softKey == key ? prepared?.soft : nil) ?? GlowRenderer.render(
            glow: glow, islandSize: islandSize, islandRadius: islandRadius, outwardOnly: outwardOnly, stops: stops, scale: scale
        ) else { return }
        softKey = key
        glowPadding = rendered.padding
        softStill = rendered.image
        CATransaction.begin()
        // A contents crossfade has its own timing and stretches the old contour into the new one.
        // Only animate the frame; keep the feather and rounded edge at their native point size.
        CATransaction.setDisableActions(true)
        glowLayer.contents = rendered.image
        configure(glowLayer, for: .blur, image: rendered, side: glow.sideInset + islandRadius, bottom: glow.sideInset + islandRadius)
        CATransaction.commit()
    }

    private func updateShadowImage(island: CGRect, radius: CGFloat, scale: CGFloat, prepared: PreparedImages?) {
        let key = ShadowKey(size: island.size, radius: radius, scale: scale)
        guard key != shadowKey else { return }
        guard let rendered = (prepared?.shadowKey == key ? prepared?.shadow : nil)
            ?? GlowRenderer.renderShadow(width: island.width, height: island.height, cornerRadius: radius, scale: scale) else { return }
        shadowKey = key
        shadowPadding = rendered.padding
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.contents = rendered.image
        shadowLayer.contentsCenter = contentsCenter(for: rendered, side: radius, bottom: radius)
        CATransaction.commit()
    }

    private func contentsCenter(for image: GlowImage, side: CGFloat, bottom: CGFloat) -> CGRect {
        let left = min(image.padding + side, (image.size.width - 1) / 2)
        let top = image.padding
        let lower = min(image.padding + bottom, image.size.height - top - 1)
        return CGRect(x: left / image.size.width, y: top / image.size.height,
                      width: (image.size.width - left * 2) / image.size.width,
                      height: (image.size.height - top - lower) / image.size.height)
    }

    private func applyBreathing(_ appearance: GlowAppearance, pulsesOpacity: Bool) {
        let pulses = appearance.breathing && pulsesOpacity
        let key = BreathKey(pulses: pulses, peakOpacity: appearance.peakOpacity, troughOpacity: appearance.troughOpacity,
                            breathSeconds: appearance.breathSeconds)
        guard key != breathKey else { return }
        breathKey = key
        glowLayer.removeAnimation(forKey: "breathe")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        glowLayer.opacity = Float(appearance.peakOpacity)
        CATransaction.commit()
        guard pulses else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = appearance.peakOpacity
        animation.toValue = appearance.troughOpacity
        animation.duration = appearance.breathSeconds / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(animation, forKey: "breathe")
    }
}
