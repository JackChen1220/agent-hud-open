import SwiftUI
import QuartzCore
import AgentHUDCore

/// The surface, its glow and the canvas cleanup share one finite transition.
enum IslandAnimation {
    static let duration: TimeInterval = 0.4
    static let curve = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    static var mediaCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }

    static func attachmentAlignment(for edge: HUDEdge) -> Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Content enters from its parked edge while the silhouette grows into the screen.
    static func entryOffset(for edge: HUDEdge) -> CGSize {
        switch edge {
        case .top: return CGSize(width: 0, height: -5)
        case .bottom: return CGSize(width: 0, height: 5)
        case .left: return CGSize(width: -5, height: 0)
        case .right: return CGSize(width: 5, height: 0)
        }
    }
}
