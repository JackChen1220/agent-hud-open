import AgentHUDCore
import Foundation

/// Geometry of the glow layer relative to the island it wraps.
///
/// From the design: width = island + 2·range, height = island + range + 3·blur,
/// top = −3·blur (the part above the screen edge is clipped, so the top edge reads as solid), radius = island + range.
public struct GlowGeometry: Hashable, Sendable {
    public let width: Double
    public let height: Double
    /// Negative offset of the glow's top edge relative to the island's top edge.
    public let topOffset: Double
    public let cornerRadius: Double
    public let blur: Double
    /// Inset of the island inside the glow on the left, right and bottom (== range).
    public let sideInset: Double

    public init(width: Double, height: Double, topOffset: Double, cornerRadius: Double, blur: Double, sideInset: Double) {
        self.width = width
        self.height = height
        self.topOffset = topOffset
        self.cornerRadius = cornerRadius
        self.blur = blur
        self.sideInset = sideInset
    }

    public static func compute(
        islandWidth: Double,
        islandHeight: Double,
        islandRadius: Double,
        range: Double,
        blur: Double
    ) -> GlowGeometry {
        GlowGeometry(
            width: islandWidth + range * 2,
            height: islandHeight + range + blur * 3,
            topOffset: -blur * 3,
            cornerRadius: islandRadius + range,
            blur: blur,
            sideInset: range
        )
    }

    /// The same glow shrunk to what still fits in `limit` points of screen. The island's own height is fixed,
    /// so a panel tall enough to fill the screen gives the glow whatever is left and no more — which is what
    /// lets the range and feather settings run past what a full-height panel could otherwise afford.
    public func fitted(within limit: Double) -> GlowGeometry {
        let demand = sideInset + blur * 3
        guard height > limit, demand > 0 else { return self }
        let islandHeight = height - demand
        let scale = max(0, min(1, (limit - islandHeight) / demand))
        return .compute(islandWidth: width - sideInset * 2, islandHeight: islandHeight,
                        islandRadius: max(0, cornerRadius - sideInset),
                        range: sideInset * scale, blur: blur * scale)
    }
}
