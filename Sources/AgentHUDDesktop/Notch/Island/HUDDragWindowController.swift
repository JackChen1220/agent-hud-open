import AppKit
import AgentHUDCore
import QuartzCore

/// A grab surface over the visible HUD. Its bounds appear only when grabbed or Command is held;
/// Command also exposes the target when the logos are hidden. This surface owns the mouse gesture.
@MainActor
final class HUDDragWindowController {
    let panel: OverlayPanel
    private let surface = HUDDragView()

    var onPress: (() -> Void)? { didSet { surface.onPress = onPress } }
    var onRelease: (() -> Void)? { didSet { surface.onRelease = onRelease } }
    var onBegin: ((CGPoint) -> Void)? { didSet { surface.onBegin = onBegin } }
    var onDrag: ((CGPoint) -> Void)? { didSet { surface.onDrag = onDrag } }
    var onEnd: (() -> Void)? { didSet { surface.onEnd = onEnd } }
    var isDragging: Bool { surface.isDragging }
    var isPressed: Bool { surface.isPressed }

    init() {
        panel = OverlayPanel(frame: .zero,
                             level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3),
                             acceptsMouse: true)
        panel.title = "Move Agent HUD"
        panel.contentView = surface
        surface.autoresizingMask = [.width, .height]
        surface.setAccessibilityLabel(L10n.text("拖动 HUD", "Move HUD"))
    }

    func show(frame: CGRect, outlined: Bool = true) {
        panel.setFrame(frame, display: false)
        surface.frame = CGRect(origin: .zero, size: frame.size)
        surface.isOutlined = outlined
        surface.updateOutline()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
private final class HUDDragView: NSView {
    private let outline = CAShapeLayer()
    private var downAt: CGPoint?
    private(set) var isDragging = false
    var isPressed: Bool { downAt != nil }
    var isOutlined = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = CGColor(gray: 1, alpha: 0.025)
        outline.strokeColor = CGColor(gray: 1, alpha: 0.9)
        outline.lineWidth = 1.25
        outline.lineDashPattern = [4, 3]
        outline.shadowColor = CGColor(gray: 0, alpha: 1)
        outline.shadowOpacity = 0.8
        outline.shadowRadius = 2
        outline.shadowOffset = .zero
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateOutline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.opacity = isOutlined || isPressed ? 1 : 0
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 7, cornerHeight: 7, transform: nil)
        CATransaction.commit()
    }

    override func layout() { super.layout(); updateOutline() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        downAt = window.convertPoint(toScreen: event.locationInWindow)
        updateOutline()
        onPress?()
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if !isDragging {
            guard hypot(point.x - downAt.x, point.y - downAt.y) >= 3 else { return }
            isDragging = true
            onBegin?(downAt)
        }
        onDrag?(point)
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
        let moved = isDragging
        isDragging = false
        updateOutline()
        NSCursor.openHand.set()
        if moved { onEnd?() }
        onRelease?()
    }
}
