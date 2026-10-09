import SwiftUI
import AgentHUDCore

/// One mark in the queue. The queue shows one mark per vendor, not per agent: two Claude windows are
/// one Claude, and the mark bobs when any of them is working.
struct LogoQueueItem: Identifiable, Equatable {
    let vendor: String
    /// Any agent of this vendor has a running session: the mark bobs at the working period, not the idle one.
    let isWorking: Bool
    var id: String { vendor }

    /// Collapses agents onto the mark they are drawn with, keeping the order they were watched in. Two
    /// Claude windows are one Claude; so are Codex and ChatGPT, which share OpenAI's artwork — a second
    /// identical mark would take a place in the row and tell a glance nothing. Either of them running bobs
    /// the mark they share.
    @MainActor
    static func queue(rows: [(vendor: String, isWorking: Bool)]) -> [LogoQueueItem] {
        var order: [String] = []
        var vendors: [String: String] = [:]
        var working: [String: Bool] = [:]
        for row in rows {
            let key = AgentArtwork.markKey(row.vendor)
            if vendors[key] == nil {
                order.append(key)
                vendors[key] = row.vendor
            }
            working[key] = (working[key] ?? false) || row.isWorking
        }
        return order.map { LogoQueueItem(vendor: vendors[$0] ?? $0, isWorking: working[$0] ?? false) }
    }
}

/// A queue resolved for one screen: what to draw, how big, and how fast.
struct LogoQueueConfig: Equatable {
    var items: [LogoQueueItem]
    var edge: HUDEdge
    /// Side of one mark, in points.
    var logo: CGFloat
    var gap: CGFloat
    var workingSeconds: Double

    init(items: [LogoQueueItem], placement: ScreenPlacement, settings: AgentHUDCore.Settings) {
        self.items = items
        edge = placement.edge
        logo = placement.logoSize
        gap = logo * placement.gapScale
        workingSeconds = settings.breathSeconds
    }

    /// What the marks occupy.
    var size: CGSize {
        guard !items.isEmpty else { return .zero }
        let run = logo * CGFloat(items.count) + gap * CGFloat(items.count - 1)
        return edge.isHorizontal ? CGSize(width: run, height: logo) : CGSize(width: logo, height: run)
    }
}

/// The collapsed HUD on a screen in logo mode: every watched agent's own mark. Only the ones with work
/// running bob, so motion means exactly one thing and a glance finds the busy agent without reading
/// anything. The marks keep their own artwork at full strength; status colour is carried by the glow behind
/// them, not by the logos.
///
/// The marks are plain layers holding baked bitmaps, animated by Core Animation. Driving the bob from
/// SwiftUI instead re-evaluates every mark on the main thread each frame, which on a full queue costs more
/// than the glow it sits on.
struct LogoQueueView: NSViewRepresentable {
    let config: LogoQueueConfig
    let light: Bool
    /// Bobs every mark at full strength whether its agent is working or not, so a preview shows the motion
    /// instead of whatever the agents happen to be doing while the settings are open.
    var previewsMotion = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> LogoQueueLayerView { LogoQueueLayerView() }

    func updateNSView(_ view: LogoQueueLayerView, context: Context) {
        view.apply(config: config, light: light, scale: displayScale, animates: !reduceMotion,
                   previewsMotion: previewsMotion)
    }
}

/// Lays the marks out along the edge and gives each one a repeating offset animation.
final class LogoQueueLayerView: NSView {
    /// How far a mark travels, as a share of its side, and the stagger that turns a row of bobs into a wave.
    private static let travel: CGFloat = 0.14
    private static let stagger = 0.13

    private var marks: [CALayer] = []
    /// How far the baked outline overflows a mark, in points, so the layout leaves room for exactly that.
    private var bleed: CGFloat = 1
    private var applied: (config: LogoQueueConfig, light: Bool, scale: CGFloat, animates: Bool, previews: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let applied else { return }
        position(config: applied.config)
    }

    /// The marks are laid out against the view's own bounds, so a size change has to reach them even when
    /// AppKit does not consider the bounds themselves changed.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let applied { position(config: applied.config) }
    }

    func apply(config: LogoQueueConfig, light: Bool, scale: CGFloat, animates: Bool, previewsMotion: Bool = false) {
        if let applied, applied.config == config, applied.light == light, applied.scale == scale,
           applied.animates == animates, applied.previews == previewsMotion { return }
        let rebuild = applied?.config.items.map(\.id) != config.items.map(\.id)
            || applied?.light != light || applied?.scale != scale
            || applied?.config.logo != config.logo
        applied = (config, light, scale, animates, previewsMotion)
        if rebuild { build(config: config, light: light, scale: scale) }
        position(config: config)
        animate(config: config, animates: animates, previewsMotion: previewsMotion)
    }

    private func build(config: LogoQueueConfig, light: Bool, scale: CGFloat) {
        marks.forEach { $0.removeFromSuperlayer() }
        let side = Int((config.logo * scale).rounded())
        // One device pixel at any size: a hairline reads as the mark's own edge, anything thicker as a
        // border drawn around it.
        let outline = 1
        bleed = CGFloat(outline) / max(1, scale)
        // The queue sits on the wallpaper: the dark artwork variant is the one that reads there.
        marks = config.items.map { item in
            let mark = CALayer()
            mark.contentsScale = scale
            mark.contentsGravity = .resizeAspect
            mark.contents = LogoImages.image(LogoImages.Key(vendor: item.vendor, side: side,
                                                            outline: outline, light: false))
            layer?.addSublayer(mark)
            return mark
        }
    }

    private func position(config: LogoQueueConfig) {
        // The baked outline overflows the mark on every edge, so each layer is grown by exactly that and the
        // extra is centred away; the spacing the user set still applies to the marks themselves.
        let step = config.logo + config.gap
        // The view is given the window's width, which is wider than the run; the queue sits in the middle
        // of it, as the notch does.
        let run = config.edge.isHorizontal ? config.size.width : config.size.height
        let lead = max(0, ((config.edge.isHorizontal ? bounds.width : bounds.height) - run) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, mark) in marks.enumerated() {
            let along = lead + CGFloat(index) * step
            let origin = config.edge.isHorizontal
                ? CGPoint(x: along, y: (bounds.height - config.logo) / 2)
                : CGPoint(x: (bounds.width - config.logo) / 2, y: along)
            mark.frame = CGRect(x: origin.x - bleed, y: origin.y - bleed,
                                width: config.logo + bleed * 2, height: config.logo + bleed * 2)
        }
        CATransaction.commit()
    }

    /// The bob is a translation, not a move to a second point: an absolute animation on `position` outlives
    /// every relayout — it keeps driving the presentation from the coordinates it was built with, so a mark
    /// sits where the old size put it however often the layout is redone.
    private func animate(config: LogoQueueConfig, animates: Bool, previewsMotion: Bool) {
        let travel = config.logo * Self.travel
        let axis = config.edge.inward
        let vertical = axis.y != 0
        var bobbing = 0
        for (index, mark) in marks.enumerated() {
            mark.removeAnimation(forKey: "bob")
            let working = previewsMotion || (index < config.items.count && config.items[index].isWorking)
            guard animates, working else { continue }
            let period = max(0.25, config.workingSeconds)
            let animation = CABasicAnimation(keyPath: vertical ? "transform.translation.y" : "transform.translation.x")
            animation.fromValue = 0
            animation.toValue = travel * CGFloat(vertical ? axis.y : axis.x)
            animation.duration = period / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A negative time offset starts each mark further into the cycle than the one before it. Counted
            // over the bobbing marks alone, so the wave has no gaps where a resting agent sits.
            animation.timeOffset = -Double(bobbing) * Self.stagger
            bobbing += 1
            animation.isRemovedOnCompletion = false
            mark.add(animation, forKey: "bob")
        }
    }
}
