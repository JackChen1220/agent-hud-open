import AppKit
import SwiftUI

/// Island details must track the mouse even while another app has keyboard focus.
struct IslandHoverPopover<Content: View>: NSViewRepresentable {
    let content: Content
    var enabled = true
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> IslandHoverAnchorView<Content> {
        IslandHoverAnchorView(content: content)
    }

    func updateNSView(_ view: IslandHoverAnchorView<Content>, context: Context) {
        view.onHover = { isHovered = $0 }
        view.update(content: content, enabled: enabled, isHovered: isHovered)
    }

    static func dismantleNSView(_ view: IslandHoverAnchorView<Content>, coordinator: ()) {
        view.dismiss()
    }
}

final class IslandHoverAnchorView<Content: View>: NSView {
    var onHover: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?
    private var pointerLocation: CGPoint?
    private var content: Content
    /// Most rows are never hovered, so the panel and its hosting view wait for the first show.
    private var popup: (panel: OverlayPanel, details: NSHostingView<Content>)?

    init(content: Content) {
        self.content = content
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        trackPointer(event)
        onHover(true)
    }

    override func mouseMoved(with event: NSEvent) { trackPointer(event) }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        onHover(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            pointerLocation = nil
            dismiss()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func update(content: Content, enabled: Bool, isHovered: Bool) {
        self.content = content
        popup?.details.rootView = content
        guard isHovered, enabled, let window, let pointerLocation else {
            dismiss()
            return
        }
        let popup = self.popup ?? makePopup()
        position(popup.panel, in: window, at: pointerLocation, size: popup.details.fittingSize)
        if popup.panel.parent !== window { window.addChildWindow(popup.panel, ordered: .above) }
        popup.panel.orderFrontRegardless()
    }

    private func makePopup() -> (panel: OverlayPanel, details: NSHostingView<Content>) {
        let details = NSHostingView(rootView: content)
        let panel = OverlayPanel(frame: .zero, level: .popUpMenu, acceptsMouse: false)
        panel.title = "Island hover details"
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = details
        popup = (panel, details)
        return (panel, details)
    }

    private func trackPointer(_ event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        pointerLocation = point
        if let panel = popup?.panel, panel.isVisible { position(panel, in: window, at: point, size: panel.frame.size) }
    }

    private func position(_ panel: NSPanel, in window: NSWindow, at point: CGPoint, size: CGSize) {
        var origin = CGPoint(x: point.x + 10, y: point.y - size.height - 12)
        if let screen = window.screen {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            if origin.y < visible.minY { origin.y = point.y + 12 }
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func dismiss() {
        guard let panel = popup?.panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
