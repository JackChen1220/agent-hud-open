import AppKit
import AgentHUDCore

/// Where the HUD sits on one screen, in global screen coordinates.
///
/// In notch mode the collapsed rect is the physical notch, or a bar standing in for one on a display
/// without. In logo mode it is the queue's strip, parked along an edge at the placement's offset.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let mode: HUDMode
    let edge: HUDEdge
    let hasNotch: Bool
    /// The collapsed HUD's rect.
    let rect: CGRect
    /// Convex radius of the corners that face into the screen.
    let cornerRadius: CGFloat
    let backingScale: CGFloat
    /// The screen's menu bar height, which every logo-mode size is derived from.
    let menuBarHeight: CGFloat

    static let fallbackWidth: CGFloat = 200
    static let notchCornerRadius: CGFloat = 12
    static let fallbackCornerRadius: CGFloat = 10
    static let logoCornerRadius: CGFloat = 10
    /// Concave flare where the island meets the screen edge, collapsed / expanded.
    static let collapsedTopRadius: CGFloat = 8
    static let expandedTopRadius: CGFloat = 16

    /// - screen: the display this HUD belongs to. Each screen is measured on its own — its own notch, its
    ///   own menu bar, its own scale — because two displays can be in different modes at once.
    /// - placement: how that screen presents the HUD.
    /// - queue: the measured size of the logo queue's marks, when the placement asks for one.
    static func detect(screen: NSScreen?, placement: ScreenPlacement, queue: CGSize? = nil) -> NotchGeometry {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBar = screen.map { max(22, $0.frame.maxY - $0.visibleFrame.maxY) } ?? 24
        let scale = screen?.backingScaleFactor ?? 2
        let notch = screen.flatMap { $0.safeAreaInsets.top > 0 ? notchRect(of: $0) : nil }

        if placement.mode == .logos, let queue {
            let rect = stripRect(queue: queue, frame: frame, menuBar: menuBar, placement: placement, notch: notch)
            return NotchGeometry(screenFrame: frame, mode: .logos, edge: placement.edge, hasNotch: notch != nil,
                                 rect: rect, cornerRadius: logoCornerRadius, backingScale: scale, menuBarHeight: menuBar)
        }
        if let notch {
            return NotchGeometry(screenFrame: frame, mode: .notch, edge: .top, hasNotch: true, rect: notch,
                                 cornerRadius: notchCornerRadius, backingScale: scale, menuBarHeight: menuBar)
        }
        let rect = CGRect(x: frame.midX - fallbackWidth / 2, y: frame.maxY - menuBar, width: fallbackWidth, height: menuBar)
        return NotchGeometry(screenFrame: frame, mode: .notch, edge: .top, hasNotch: false, rect: rect,
                             cornerRadius: fallbackCornerRadius, backingScale: scale, menuBarHeight: menuBar)
    }

    private static func notchRect(of screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let height = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.maxX ?? (frame.midX - fallbackWidth / 2)
        let right = screen.auxiliaryTopRightArea?.minX ?? (frame.midX + fallbackWidth / 2)
        return CGRect(x: left, y: frame.maxY - height, width: max(1, right - left), height: height)
    }

    /// Where the queue sits, centred on `placement.offset` along its edge and kept on screen. Nothing is drawn
    /// here — the marks stand on their own — so the rect only has to hold them and catch the pointer; the
    /// padding is hover slack, not a visible strip.
    static func stripRect(queue: CGSize, frame: CGRect, menuBar: CGFloat,
                          placement: ScreenPlacement, notch: CGRect? = nil) -> CGRect {
        // The run is the marks themselves: the backdrop is clipped to this rect, and anything added here
        // would show up as backdrop reaching past the last mark. Whole points, because the spacing is a
        // fraction of the logo and a window on a half point puts every mark on a blurred pixel boundary.
        let long = (placement.edge.isHorizontal ? queue.width : queue.height).rounded()
        let thick = max(menuBar, placement.edge.isHorizontal ? queue.height : queue.width)
        switch placement.edge {
        case .top, .bottom:
            let width = min(long, frame.width)
            let x = min(frame.maxX - width, max(frame.minX, frame.minX + (frame.width - width) * placement.offset))
            // Keep a centred queue centred. If it crosses the physical notch, put its strip directly
            // below it; moving the queue sideways makes a short row look off-centre on the display.
            let y: CGFloat
            if placement.edge == .bottom {
                y = frame.minY
            } else if let notch, x < notch.maxX, x + width > notch.minX {
                y = max(frame.minY, notch.minY - thick)
            } else {
                y = frame.maxY - thick
            }
            return CGRect(x: x, y: y, width: width, height: thick)
        case .left, .right:
            let height = min(long, frame.height)
            // Offset runs the way the edge is read: top to bottom.
            let y = min(frame.maxY - height, max(frame.minY, frame.maxY - height - (frame.height - height) * placement.offset))
            let x = placement.edge == .left ? frame.minX : frame.maxX - thick
            return CGRect(x: x, y: y, width: thick, height: height)
        }
    }

    var centerX: CGFloat { rect.midX }
    var top: CGFloat { screenFrame.maxY }

    /// Collapsed window: the HUD plus the flares where it meets the screen edge.
    ///
    /// A logo queue needs slack for the outline its marks carry, but only away from the edge it is parked on:
    /// the window's edge-side boundary has to match the expanded panel's, or the marks shift by the slack
    /// every time the panel opens and closes. Past the screen's edge there is nothing to show anyway.
    var islandFrame: CGRect {
        let slack = Self.collapsedTopRadius
        guard mode != .logos else {
            let grown = rect.insetBy(dx: -slack, dy: -slack)
            switch edge {
            case .top: return CGRect(x: grown.minX, y: grown.minY, width: grown.width, height: grown.height - slack)
            case .bottom: return CGRect(x: grown.minX, y: rect.minY, width: grown.width, height: grown.height - slack)
            case .left: return CGRect(x: rect.minX, y: grown.minY, width: grown.width - slack, height: grown.height)
            case .right: return CGRect(x: grown.minX, y: grown.minY, width: grown.width - slack, height: grown.height)
            }
        }
        return edge.isHorizontal ? rect.insetBy(dx: -slack, dy: 0) : rect.insetBy(dx: 0, dy: -slack)
    }

    /// Core of the expanded panel: anchored to the same edge, centred on the collapsed rect, growing inward.
    func expandedFrame(size: CGSize) -> CGRect {
        switch edge {
        case .top:
            return CGRect(x: centerX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
        case .bottom:
            return CGRect(x: centerX - size.width / 2, y: screenFrame.minY, width: size.width, height: size.height)
        case .left:
            return CGRect(x: screenFrame.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        case .right:
            return CGRect(x: screenFrame.maxX - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        }
    }
}
