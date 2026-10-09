import AppKit
import AgentHUDCore

/// A transparent grab surface over the HUD. Clicking, holding and dragging never draw a border.
/// This surface owns the mouse gesture.
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

    func show(frame: CGRect) {
        panel.setFrame(frame, display: false)
        surface.frame = CGRect(origin: .zero, size: frame.size)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
private final class HUDDragView: NSView {
    private var downAt: CGPoint?
    private(set) var isDragging = false
    var isPressed: Bool { downAt != nil }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        downAt = window.convertPoint(toScreen: event.locationInWindow)
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
        NSCursor.openHand.set()
        if moved { onEnd?() }
        onRelease?()
    }
}
