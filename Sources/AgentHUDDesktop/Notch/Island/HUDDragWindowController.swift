import AppKit
import AgentHUDCore

/// A transparent grab surface over the HUD. Clicking, holding and dragging never draw a border.
/// A press picks the HUD up after travel or hold; a shorter press remains a click.
@MainActor
final class HUDDragWindowController {
    let panel: OverlayPanel
    private let surface = HUDDragView()

    var onPress: (() -> Void)? { didSet { surface.onPress = onPress } }
    var onRelease: (() -> Void)? { didSet { surface.onRelease = onRelease } }
    var onBegin: ((CGPoint) -> Void)? { didSet { surface.onBegin = onBegin } }
    var onDrag: ((CGPoint) -> Void)? { didSet { surface.onDrag = onDrag } }
    var onEnd: (() -> Void)? { didSet { surface.onEnd = onEnd } }
    /// A press let go before it became a pick-up: a plain click on the HUD.
    var onClick: (() -> Void)? { didSet { surface.onClick = onClick } }
    var isDragging: Bool { surface.isDragging }
    var isPressed: Bool { surface.isPressed }
    /// The press has become a pick-up, by travel or by holding.
    var isArmed: Bool { surface.isArmed }
    /// The cursor the surface asks for: the arrow at rest, a closed hand while the HUD is picked up.
    var cursor: NSCursor { surface.cursor }

    init(holdDelay: TimeInterval = 0.3) {
        surface.holdDelay = holdDelay
        panel = OverlayPanel(frame: .zero,
                             level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3),
                             acceptsMouse: true)
        panel.title = "Move Agent HUD"
        panel.contentView = surface
        surface.autoresizingMask = [.width, .height]
        surface.setAccessibilityLabel(L10n.text("拖动 HUD", "Move HUD"))
    }

    func show(frame: CGRect) {
        panel.setFrame(frame, display: false)
        surface.frame = CGRect(origin: .zero, size: frame.size)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

}

@MainActor
private final class HUDDragView: NSView {
    /// How far a press has to travel before it moves the HUD rather than clicking it.
    static let travel: CGFloat = 6

    private var downAt: CGPoint?
    private var holdTimer: Timer?
    private(set) var isDragging = false
    private(set) var isArmed = false
    var isPressed: Bool { downAt != nil }
    var holdDelay: TimeInterval = 0.3
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The surface moves with the HUD, which rebuilds its cursor rects under the pointer on every step; the
    /// rect has to carry the dragging cursor itself or the arrow comes straight back. At rest the pointer is left
    /// as the app underneath has it: showing a hand there would mean taking that app's keyboard on every hover.
    var cursor: NSCursor { isArmed ? .closedHand : .arrow }
    override func resetCursorRects() { if isArmed { addCursorRect(bounds, cursor: cursor) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        downAt = window.convertPoint(toScreen: event.locationInWindow)
        onPress?()
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// The press is now a pick-up; any further movement moves the HUD.
    private func arm() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard isPressed, !isArmed else { return }
        isArmed = true
        // macOS takes a cursor only from the key window, and this panel is never key in an app that is never
        // active. It is key for as long as the HUD is held, without activating the app, and hands the keys back
        // when it is let go.
        (window as? OverlayPanel)?.takeKeyboard()
        window?.invalidateCursorRects(for: self)
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if !isDragging {
            guard isArmed || hypot(point.x - downAt.x, point.y - downAt.y) >= Self.travel else { return }
            arm()
            isDragging = true
            onBegin?(downAt)
        }
        onDrag?(point)
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        let moved = isDragging, clicked = downAt != nil && !isArmed
        if isArmed { (window as? OverlayPanel)?.releaseKeyboard() }
        downAt = nil
        isDragging = false
        isArmed = false
        window?.invalidateCursorRects(for: self)
        cursor.set()
        if moved { onEnd?() }
        onRelease?()
        if clicked { onClick?() }
    }
}
