import AgentHUDCore
import Foundation

/// Options for the dot and ASCII glow styles.
public struct GlowPattern: Hashable, Sendable {
    public var style: GlowStyle
    /// Grid spacing in points.
    public var pitch: Double
    /// Rows held at full strength before the glow starts to fade.
    public var core: Double
    /// Rows the glow fades over, from full strength down to the cutoff.
    public var fade: Double
    /// How much of its cell each mark fills; 1 is the design's proportion.
    public var density: Double
    public var effect: GlowEffect

    public init(style: GlowStyle = .blur, pitch: Double = 10, core: Double = 0, fade: Double = 7,
                density: Double = 1, effect: GlowEffect = .breathe) {
        self.style = style
        self.pitch = pitch
        self.core = core
        self.fade = fade
        self.density = density
        self.effect = effect
    }

    public var usesGrid: Bool { style != .blur }

}

/// The glow sampled on a square grid, following the ASCII HUD bar design: every cell's resting intensity is
/// full over the core rows and then fading, measured from the island's outline. Pure geometry; the desktop renderer
/// decides how each cell is drawn. Coordinates are points from the glow rect's top-left corner.
public struct GlowMatrix: Hashable, Sendable {
    public struct Cell: Hashable, Sendable {
        public init(column: Int, row: Int, x: Double, y: Double, width: Double, distance: Double, intensity: Double, location: Double) {
            self.column = column
            self.row = row
            self.x = x
            self.y = y
            self.width = width
            self.distance = distance
            self.intensity = intensity
            self.location = location
        }

        public let column: Int
        public let row: Int
        public let x: Double
        public let y: Double
        /// Width of the cell's column; the columns under the island stretch slightly to fit it.
        public let width: Double
        /// Distance from the island's outline in points.
        public let distance: Double
        /// 0…1 resting strength of the glow at this cell.
        public let intensity: Double
        /// 0…1 across the glow's width; where this cell samples the colour gradient.
        public let location: Double
    }

    public let cells: [Cell]
    public let pitch: Double
    /// Spacing between rows; equal to the pitch except for Braille, whose cells are twice as tall as wide.
    public let rowPitch: Double
    public let core: Double
    public let fade: Double

    public init(cells: [Cell], pitch: Double, core: Double, fade: Double, rowPitch: Double? = nil) {
        self.cells = cells
        self.pitch = pitch
        self.rowPitch = rowPitch ?? pitch
        self.core = core
        self.fade = fade
    }

    /// Marks fainter than this are not drawn.
    public static let cutoff = 0.06

    /// Farthest distance a mark can appear at. The fade lands exactly on the cutoff, so the field ends
    /// where the rows the user asked for run out.
    public static func reach(pitch: Double, core: Double, fade: Double) -> Double {
        (max(0, core) + max(0, fade)) * pitch
    }

    /// Resting strength at `cells` cells from the island's outline: full over the core, then fading over the
    /// rest. The fade is Gaussian rather than exponential so it leaves the core with no slope at all — an
    /// exponential starts dropping at its steepest, which shows as a crease where the two meet — and so it
    /// reaches the cutoff exactly as the fade's last row is drawn.
    public static func strength(cells: Double, core: Double, fade: Double) -> Double {
        let core = max(0, core), fade = max(0.01, fade)
        guard cells > core else { return 1 }
        let t = (cells - core) / fade
        guard t <= 1 else { return 0 }
        return exp(-log(GlowMotion.maximumGain / cutoff) * t * t)
    }

    /// Columns beside the island start half a pitch from its sides and the row below it half a pitch from its
    /// bottom edge, so the first ring sits tangent to the rim. Cells over the island, above the screen edge or
    /// too faint for any effect to reveal are skipped.
    public static func compute(glow: GlowGeometry, islandRadius: Double, pitch: Double, core: Double, fade: Double,
                               rowPitch: Double? = nil) -> GlowMatrix {
        let pitch = max(0.5, pitch)
        let rowPitch = max(0.5, rowPitch ?? pitch)
        let faintest = cutoff / GlowMotion.maximumGain
        let left = glow.sideInset
        let right = glow.width - glow.sideInset
        let bottom = glow.height - glow.sideInset
        let top = -glow.topOffset

        var columns: [(x: Double, width: Double)] = []
        var x = left - pitch / 2
        while x > 0 { columns.append((x, pitch)); x -= pitch }
        let middle = max(1, ((right - left) / pitch).rounded())
        let middlePitch = (right - left) / middle
        for index in 0..<Int(middle) { columns.append((left + (Double(index) + 0.5) * middlePitch, middlePitch)) }
        x = right + pitch / 2
        while x < glow.width { columns.append((x, pitch)); x += pitch }
        columns.sort { $0.x < $1.x }

        var ys: [Double] = []
        var y = bottom + rowPitch / 2
        while y < glow.height { ys.append(y); y += rowPitch }
        y = bottom - rowPitch / 2
        while y >= top { ys.append(y); y -= rowPitch }

        var cells: [Cell] = []
        for (row, y) in ys.sorted().enumerated() {
            for (column, place) in columns.enumerated() {
                let distance = distance(x: place.x, y: y, glow: glow, islandRadius: islandRadius)
                guard distance >= 0 else { continue }
                let intensity = strength(cells: distance / pitch, core: core, fade: fade)
                guard intensity >= faintest else { continue }
                cells.append(Cell(column: column, row: row, x: place.x, y: y, width: place.width, distance: distance,
                                  intensity: intensity, location: place.x / glow.width))
            }
        }
        return GlowMatrix(cells: cells, pitch: pitch, core: core, fade: fade, rowPitch: rowPitch)
    }

    /// Dot positions of a Braille character as (column, row, Unicode bit).
    public static let brailleLayout: [(column: Int, row: Int, bit: Int)] = [
        (0, 0, 0), (0, 1, 1), (0, 2, 2), (1, 0, 3), (1, 1, 4), (1, 2, 5), (0, 3, 6), (1, 3, 7),
    ]

    /// The eight dots of a cell drawn as a Braille character, 2 across and 4 down, each sampled on its own as
    /// in the design. With rows twice the pitch the dots fall on a square lattice of half the pitch. Dots over the
    /// island are left out; grid indices are per dot for dithering and noise.
    public func brailleDots(of cell: Cell, glow: GlowGeometry, islandRadius: Double) -> [(bit: Int, dot: Cell)] {
        return Self.brailleLayout.compactMap { layout in
            let x = cell.x - cell.width / 2 + (Double(layout.column) + 0.5) * cell.width / 2
            let y = cell.y - rowPitch / 2 + (Double(layout.row) + 0.5) * rowPitch / 4
            let distance = Self.distance(x: x, y: y, glow: glow, islandRadius: islandRadius)
            guard distance >= 0 else { return nil }
            let dot = Cell(column: cell.column * 2 + layout.column, row: cell.row * 4 + layout.row, x: x, y: y,
                           width: cell.width / 2, distance: distance,
                           intensity: Self.strength(cells: distance / pitch, core: core, fade: fade),
                           location: x / glow.width)
            return (layout.bit, dot)
        }
    }

    /// Signed distance from a point to the island's outline (bottom corners rounded, top edge off screen).
    /// Negative inside the island.
    public static func distance(x: Double, y: Double, glow: GlowGeometry, islandRadius: Double) -> Double {
        let left = glow.sideInset
        let right = glow.width - glow.sideInset
        let bottom = glow.height - glow.sideInset
        let islandHeight = bottom + glow.topOffset
        let radius = max(0, min(islandRadius, min(right - left, islandHeight) / 2))
        let cornerY = bottom - radius
        if y <= cornerY {
            if x < left { return left - x }
            if x > right { return x - right }
            return -min(x - left, right - x)
        }
        let cornerX = min(max(x, left + radius), right - radius)
        return ((x - cornerX) * (x - cornerX) + (y - cornerY) * (y - cornerY)).squareRoot() - radius
    }
}
