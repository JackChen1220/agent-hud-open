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
            let rect = stripRect(queue: queue, frame: frame, menuBar: menuBar, placement: placement)
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
                          placement: ScreenPlacement) -> CGRect {
        // The run is the marks themselves: the backdrop is clipped to this rect, and anything added here
        // would show up as backdrop reaching past the last mark. Whole points, because the spacing is a
        // fraction of the logo and a window on a half point puts every mark on a blurred pixel boundary.
        let long = (placement.edge.isHorizontal ? queue.width : queue.height).rounded()
        let thick = max(menuBar, placement.edge.isHorizontal ? queue.height : queue.width)
        switch placement.edge {
        case .top, .bottom:
            // The notch is not avoided: a queue centred on the screen reads as centred, and sliding it off
            // to one side to clear the notch costs more than the marks the notch covers.
            let width = min(long, frame.width)
            let x = min(frame.maxX - width, max(frame.minX, frame.minX + (frame.width - width) * placement.offset))
            let y = placement.edge == .top ? frame.maxY - thick : frame.minY
            return CGRect(x: x, y: y, width: width, height: thick)
        case .left, .right:
            let height = min(long, frame.height)
            // Offset runs the way the edge is read: top to bottom.
            let y = min(frame.maxY - height, max(frame.minY, frame.maxY - height - (frame.height - height) * placement.offset))
            let x = placement.edge == .left ? frame.minX : frame.maxX - thick
            return CGRect(x: x, y: y, width: thick, height: height)
        }
    }

    /// Parks the queue at the edge nearest the pointer, keeping the originally grabbed point under it.
    /// `grabFraction` runs left to right on horizontal edges and top to bottom on vertical ones. The offset
    /// uses the same available travel as `stripRect`, including the queue's own length. `queue` is measured
    /// in the existing placement's orientation; its run stays the same when the queue turns onto a side.
    static func dragPlacement(at point: CGPoint, screenFrame: CGRect, queue: CGSize,
                              placement: ScreenPlacement, grabFraction: CGFloat = 0.5) -> ScreenPlacement {
        func distance(to edge: HUDEdge) -> CGFloat {
            switch edge {
            case .top: return abs(screenFrame.maxY - point.y)
            case .bottom: return abs(point.y - screenFrame.minY)
            case .left: return abs(point.x - screenFrame.minX)
            case .right: return abs(screenFrame.maxX - point.x)
            }
        }
        // Starting from the current edge keeps an exact diagonal tie stable while dragging.
        let edge = HUDEdge.allCases.reduce(placement.edge) { nearest, candidate in
            distance(to: candidate) < distance(to: nearest) ? candidate : nearest
        }
        let run = (placement.edge.isHorizontal ? queue.width : queue.height).rounded()
        let length = edge.isHorizontal ? screenFrame.width : screenFrame.height
        let measuredRun = min(run, length)
        let travel = length - measuredRun
        let readingCoordinate = edge.isHorizontal ? point.x - screenFrame.minX : screenFrame.maxY - point.y
        let origin = readingCoordinate - measuredRun * grabFraction
        var result = placement
        result.mode = .logos
        result.edge = edge
        result.offset = travel > 0 ? Double(min(1, max(0, origin / travel))) : 0.5
        return result
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
        let width = min(size.width, screenFrame.width)
        let height = min(size.height, screenFrame.height)
        let x = min(screenFrame.maxX - width, max(screenFrame.minX, centerX - width / 2))
        let y = min(screenFrame.maxY - height, max(screenFrame.minY, rect.midY - height / 2))
        switch edge {
        case .top:
            return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
        case .bottom:
            return CGRect(x: x, y: screenFrame.minY, width: width, height: height)
        case .left:
            return CGRect(x: screenFrame.minX, y: y, width: width, height: height)
        case .right:
            return CGRect(x: screenFrame.maxX - width, y: y, width: width, height: height)
        }
    }
}
