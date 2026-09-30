import Foundation

/// How one screen presents the HUD.
public enum HUDMode: String, Codable, Sendable, CaseIterable {
    /// The island: the notch itself, or a bar standing in for one on displays without.
    case notch
    /// A queue of the agents' own logos, parked on a screen edge, with the glow behind them as a backdrop.
    case logos
}

/// The screen edge a HUD is parked on. It runs along that edge and opens inward.
public enum HUDEdge: String, Codable, Sendable, CaseIterable {
    case top, right, bottom, left

    public var isHorizontal: Bool { self == .top || self == .bottom }

    /// Unit vector pointing into the screen from this edge.
    public var inward: (x: Double, y: Double) {
        switch self {
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        case .left: return (1, 0)
        case .right: return (-1, 0)
        }
    }
}

/// One screen's HUD. Everything here is per screen: two displays can run different modes, sit on
/// different edges and size their logos differently. The glow style is not — it is the HUD's material,
/// shared by every screen; what changes per screen is the shape it is drawn around.
public struct ScreenPlacement: Hashable, Codable, Sendable {
    /// Side of one mark in points. A share of the menu bar reads badly as a control, and the bar is not the
    /// same height on every Mac — near 38pt on a notched one against 24 elsewhere — so a multiple of it gave
    /// wildly different marks for the same setting. The top of the range fills a 24pt menu bar; past that the
    /// queue hangs below the bar and over the windows.
    public static let logoSizeRange: ClosedRange<Double> = 12...24
    /// Gap between logos, as a share of the logo's height. A gap wider than about half a mark reads as
    /// separate marks rather than one queue.
    public static let gapScaleRange: ClosedRange<Double> = 0.1...0.6
    public var mode: HUDMode
    public var edge: HUDEdge
    /// The queue's centre along its edge, as a fraction of that edge's length, so it survives a
    /// resolution change.
    public var offset: Double
    public var logoSize: Double
    public var gapScale: Double
    /// Draw the marks. Turning them off leaves the backdrop alone — it still spans what the marks would
    /// have occupied, so the field keeps its place and its width; only the logos stop being drawn.
    public var showsLogos: Bool

    public init(
        mode: HUDMode = .logos,
        edge: HUDEdge = .top,
        offset: Double = 0.5,
        logoSize: Double = 20,
        gapScale: Double = 0.4,
        showsLogos: Bool = true
    ) {
        self.mode = mode
        self.edge = edge
        self.offset = Self.clamp(offset, to: 0...1)
        self.logoSize = Self.clamp(logoSize, to: Self.logoSizeRange)
        self.gapScale = Self.clamp(gapScale, to: Self.gapScaleRange)
        self.showsLogos = showsLogos
    }

    /// A display's starting point: a notched screen keeps its island, anything else shows the queue.
    public static func `default`(hasNotch: Bool) -> ScreenPlacement {
        ScreenPlacement(mode: hasNotch ? .notch : .logos)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound))
    }

    private enum CodingKeys: String, CodingKey {
        case mode, edge, offset, logoSize, gapScale, showsLogos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenPlacement()
        self.init(
            mode: (try? c.decodeIfPresent(HUDMode.self, forKey: .mode)) ?? d.mode,
            edge: (try? c.decodeIfPresent(HUDEdge.self, forKey: .edge)) ?? d.edge,
            offset: try c.decodeIfPresent(Double.self, forKey: .offset) ?? d.offset,
            logoSize: try c.decodeIfPresent(Double.self, forKey: .logoSize) ?? d.logoSize,
            gapScale: try c.decodeIfPresent(Double.self, forKey: .gapScale) ?? d.gapScale,
            showsLogos: try c.decodeIfPresent(Bool.self, forKey: .showsLogos) ?? d.showsLogos
        )
    }
}
