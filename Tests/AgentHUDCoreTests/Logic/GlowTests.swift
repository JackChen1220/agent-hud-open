import XCTest
@testable import AgentHUDCore

final class GlowGradientTests: XCTestCase {
    func testStopLocationsAreCentredPerAgent() {
        let stops = GlowGradient.stops(levels: [.ok, .warning, .ok, .critical])
        XCTAssertEqual(stops.map(\.location), [0.125, 0.375, 0.625, 0.875])
        XCTAssertEqual(stops.map(\.color.hexString), ["#3ddc84", "#ffd23f", "#3ddc84", "#ff453a"])
    }

    func testSingleAgentSitsInTheMiddle() {
        XCTAssertEqual(GlowGradient.stops(levels: [.ok]).map(\.location), [0.5])
    }

    func testEmptyLevelsFallBackToIdle() {
        XCTAssertEqual(GlowGradient.stops(levels: []), GlowGradient.idleStops)
    }

    func testCSSMatchesDesignFormat() {
        let css = GlowGradient.css(GlowGradient.stops(levels: [.ok, .critical]))
        XCTAssertEqual(css, "linear-gradient(90deg,#3ddc84 25.0%,#ff453a 75.0%)")
    }
}

final class GlowAppearanceTests: XCTestCase {
    func testActiveAgentsBreatheWithDefaults() {
        let a = GlowAppearance.resolve(levels: [.ok, .warning], paused: false, anyAgentActive: true, glow: GlowSettings())
        XCTAssertFalse(a.hidden)
        XCTAssertTrue(a.breathing)
        XCTAssertEqual(a.peakOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(a.troughOpacity, 0.36, accuracy: 0.001)
        XCTAssertEqual(a.breathSeconds, 3)
        XCTAssertEqual(a.stops.count, 2)
    }

    func testPausedIsGreyAndStill() {
        let a = GlowAppearance.resolve(levels: [.ok], paused: true, anyAgentActive: true, glow: GlowSettings())
        XCTAssertEqual(a.stops, GlowGradient.idleStops)
        XCTAssertFalse(a.breathing)
        XCTAssertEqual(a.peakOpacity, GlowAppearance.idleOpacity)
        XCTAssertFalse(a.hidden)
    }

    func testIdleKeepsColoursAndOnlySlowsDown() {
        let settings = Settings()
        let idle = GlowAppearance.resolve(levels: [.ok, .critical], paused: false, anyAgentActive: false, glow: settings.glow)
        let working = GlowAppearance.resolve(levels: [.ok, .critical], paused: false, anyAgentActive: true, glow: settings.glow)
        XCTAssertFalse(idle.hidden)
        XCTAssertTrue(idle.breathing, "resting still reads as alive; only the pace changes")
        XCTAssertEqual(idle.breathSeconds, settings.idleBreathSeconds)
        XCTAssertEqual(working.breathSeconds, settings.breathSeconds)
        XCTAssertGreaterThan(idle.breathSeconds, working.breathSeconds)
        XCTAssertEqual(idle.stops, GlowGradient.stops(levels: [.ok, .critical]), "a quiet stretch never greys the glow")
        XCTAssertEqual(idle.peakOpacity, 0.9, accuracy: 0.001)
    }

    func testNoDataIsGreyUntilTheFirstQuotaArrives() {
        let a = GlowAppearance.resolve(levels: [], paused: false, anyAgentActive: true, glow: GlowSettings())
        XCTAssertEqual(a.stops, GlowGradient.idleStops)
        XCTAssertFalse(a.hidden)
    }

    func testLegacyIdleKeysAreIgnored() throws {
        let json = #"{"idleBehavior":"hide","breatheOnlyWhenActive":false,"glowRange":4}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.glowRange, 4)
        let a = GlowAppearance.resolve(levels: [.ok], paused: false, anyAgentActive: false, glow: decoded.glow)
        XCTAssertFalse(a.hidden, "settings saved with the old idle options no longer hide or grey the glow")
    }
}

final class GlowGeometryTests: XCTestCase {
    func testAroundMatchesDesignFormula() {
        let g = GlowGeometry.compute(islandWidth: 380, islandHeight: 44, islandRadius: 22, range: 14, blur: 8)
        XCTAssertEqual(g.width, 408)
        XCTAssertEqual(g.height, 44 + 14 + 24)
        XCTAssertEqual(g.topOffset, -24)
        XCTAssertEqual(g.cornerRadius, 36)
        XCTAssertEqual(g.sideInset, 14)
    }
}

final class GlowGradientColorTests: XCTestCase {
    let stops = GlowGradient.stops(levels: [.ok, .critical])

    func testEndsClampToTheOuterColours() {
        XCTAssertEqual(GlowGradient.color(at: 0, stops: stops), StatusPalette.color(for: .ok))
        XCTAssertEqual(GlowGradient.color(at: 1, stops: stops), StatusPalette.color(for: .critical))
    }

    func testMidpointBlendsNeighbouringStops() {
        let mid = GlowGradient.color(at: 0.5, stops: stops)
        let ok = StatusPalette.color(for: .ok), critical = StatusPalette.color(for: .critical)
        XCTAssertEqual(mid.red, (ok.red + critical.red) / 2, accuracy: 0.001)
        XCTAssertEqual(mid.green, (ok.green + critical.green) / 2, accuracy: 0.001)
        XCTAssertEqual(mid.blue, (ok.blue + critical.blue) / 2, accuracy: 0.001)
    }

    func testSingleStopIsFlat() {
        XCTAssertEqual(GlowGradient.color(at: 0.9, stops: GlowGradient.stops(levels: [.warning])), StatusPalette.color(for: .warning))
        XCTAssertEqual(GlowGradient.color(at: 0.3, stops: []), StatusPalette.idle)
    }
}

final class GlowMatrixTests: XCTestCase {
    let settings = Settings().with { $0.glowStyle = .dots }
    let radius = 22.0
    var glow: GlowGeometry { settings.glow.geometry(islandWidth: 380, islandHeight: 44, islandRadius: radius) }
    var matrix: GlowMatrix { GlowMatrix.compute(glow: glow, islandRadius: radius, pitch: settings.glowGridPitch, core: settings.glowGridCore, fade: settings.glowGridFade) }

    func testGridGeometryReachesTheRowsItWasAskedFor() {
        let reach = GlowMatrix.reach(pitch: 10, core: 2, fade: 5)
        XCTAssertEqual(reach, 70, accuracy: 1e-9, "the field ends where the solid and fading rows run out")
        XCTAssertEqual(GlowMatrix.strength(cells: 2, core: 2, fade: 5), 1, "the core is at full strength throughout")
        XCTAssertEqual(GlowMatrix.strength(cells: 7, core: 2, fade: 5), GlowMatrix.cutoff / GlowMotion.maximumGain,
                       accuracy: 1e-9, "the fade lands exactly on the cutoff")
        // The fade leaves the core with no slope at all, so the two meet without a crease.
        let step = 0.001
        let slope = (GlowMatrix.strength(cells: 2 + step, core: 2, fade: 5) - 1) / step
        XCTAssertEqual(slope, 0, accuracy: 1e-3, "an exponential would leave the core at its steepest")
        XCTAssertEqual(glow.sideInset,
                       GlowMatrix.reach(pitch: settings.glowGridPitch, core: settings.glowGridCore,
                                        fade: settings.glowGridFade).rounded(.up))
        XCTAssertEqual(glow.blur, 0)
        XCTAssertEqual(glow.topOffset, 0, "grid styles have no blur margin above the screen edge")
        let blurred = Settings().glow.geometry(islandWidth: 380, islandHeight: 44, islandRadius: radius)
        XCTAssertEqual(blurred, GlowGeometry.compute(islandWidth: 380, islandHeight: 44, islandRadius: radius, range: 14, blur: 8))
    }

    func testCellsStayOutsideTheIslandAndBelowTheScreenEdge() {
        XCTAssertGreaterThan(matrix.cells.count, 100)
        for cell in matrix.cells {
            XCTAssertGreaterThanOrEqual(cell.y, 0, "rows above the screen edge are never drawn")
            XCTAssertLessThan(cell.y, glow.height)
            XCTAssertGreaterThanOrEqual(cell.distance, 0)
            XCTAssertEqual(cell.distance, GlowMatrix.distance(x: cell.x, y: cell.y, glow: glow, islandRadius: radius), accuracy: 1e-9)
            XCTAssertTrue((0...1).contains(cell.location))
        }
    }

    func testIntensityFollowsTheSolidThenFadingCurve() {
        for cell in matrix.cells {
            let expected = GlowMatrix.strength(cells: cell.distance / settings.glowGridPitch,
                                               core: settings.glowGridCore, fade: settings.glowGridFade)
            XCTAssertEqual(cell.intensity, expected, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(cell.intensity, GlowMatrix.cutoff / GlowMotion.maximumGain)
        }
    }

    func testFirstRowHugsTheRimAndFadesDownward() {
        let bottom = glow.height - glow.sideInset
        let cells = matrix.cells
        let middle = glow.width / 2
        let centerX = cells.map { $0.x }.min { (a: Double, b: Double) -> Bool in abs(a - middle) < abs(b - middle) } ?? 0
        let column = cells.filter { $0.x == centerX && $0.y > bottom }.sorted { $0.y < $1.y }
        XCTAssertEqual(column.first?.y ?? 0, bottom + 5, accuracy: 0.001, "the first row sits half a pitch below the island")
        XCTAssertEqual(column.first?.intensity ?? 0,
                       GlowMatrix.strength(cells: 0.5, core: settings.glowGridCore, fade: settings.glowGridFade),
                       accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(column.count, 5, "the glow runs as deep as the rows it was asked for")
        XCTAssertTrue(zip(column, column.dropFirst()).allSatisfy { $0.intensity > $1.intensity })
    }

    func testGridIsMirrorSymmetric() {
        let cells = matrix.cells
        for cell in cells {
            let mirror = cells.first { abs($0.x - (glow.width - cell.x)) < 0.001 && $0.y == cell.y }
            XCTAssertEqual(mirror?.intensity ?? -1, cell.intensity, accuracy: 0.0001)
        }
    }

    func testColumnsTileTheGlowWidth() {
        let firstRow = matrix.cells.filter { $0.row == matrix.cells.map(\.row).max() }.sorted { $0.x < $1.x }
        XCTAssertGreaterThan(firstRow.count, 30)
        for (left, right) in zip(firstRow, firstRow.dropFirst()) {
            XCTAssertEqual(left.x + left.width / 2, right.x - right.width / 2, accuracy: 1e-9, "cells meet without gaps or overlap")
        }
    }

    func testBrailleDotsSplitACellTwoByFour() throws {
        let cell = try XCTUnwrap(matrix.cells.first { $0.distance > 20 })
        let dots = matrix.brailleDots(of: cell, glow: glow, islandRadius: radius)
        XCTAssertEqual(dots.map(\.bit).sorted(), Array(0...7))
        for (bit, dot) in dots {
            let layout = try XCTUnwrap(GlowMatrix.brailleLayout.first { $0.bit == bit })
            XCTAssertEqual(dot.column, cell.column * 2 + layout.column)
            XCTAssertEqual(dot.row, cell.row * 4 + layout.row)
            XCTAssertEqual(dot.x, cell.x - cell.width / 2 + (Double(layout.column) + 0.5) * cell.width / 2, accuracy: 1e-9)
            XCTAssertEqual(dot.y, cell.y - 5 + (Double(layout.row) + 0.5) * 2.5, accuracy: 1e-9)
            XCTAssertEqual(dot.intensity,
                           GlowMatrix.strength(cells: dot.distance / settings.glowGridPitch,
                                               core: settings.glowGridCore, fade: settings.glowGridFade),
                           accuracy: 1e-9)
        }
        // Cells tucked into the island's rounded corners lose the dots that fall over it.
        let dotted = matrix.cells.map { matrix.brailleDots(of: $0, glow: glow, islandRadius: radius) }
        XCTAssertTrue(dotted.contains { $0.count < 8 })
        XCTAssertTrue(dotted.joined().allSatisfy { $0.dot.distance >= 0 })
    }

    func testBrailleCellsTwiceAsTallPutDotsOnASquareLattice() throws {
        let tall = GlowMatrix.compute(glow: glow, islandRadius: radius, pitch: 10, core: 0, fade: 5, rowPitch: 20)
        let bottom = glow.height - glow.sideInset
        let rows = Set(tall.cells.filter { $0.y > bottom }.map(\.y)).sorted()
        XCTAssertEqual(rows.first ?? 0, bottom + 10, accuracy: 1e-9)
        XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { abs($1 - $0 - 20) < 1e-9 }, "rows are two pitches apart")
        let cell = try XCTUnwrap(tall.cells.first { $0.distance > 20 && abs($0.width - 10) < 1e-9 })
        let dots = tall.brailleDots(of: cell, glow: glow, islandRadius: radius).map(\.dot)
        XCTAssertEqual(Set(dots.map { ($0.x * 1000).rounded() }).count, 2)
        let ys = Set(dots.map(\.y)).sorted()
        XCTAssertEqual(ys.count, 4)
        XCTAssertTrue(zip(ys, ys.dropFirst()).allSatisfy { abs($1 - $0 - 5) < 1e-9 }, "dots are half a pitch apart down the cell")
        XCTAssertEqual(abs(dots[3].x - dots[0].x), 5, accuracy: 1e-9, "and across it")
    }

    func testDitherThresholdsCoverTheBayerMatrix() {
        let thresholds = (0..<4).flatMap { row in (0..<4).map { GlowMotion.ditherThreshold(column: $0, row: row) } }
        XCTAssertEqual(Set(thresholds).count, 16)
        XCTAssertTrue(thresholds.allSatisfy { $0 > 0 && $0 < 1 })
        XCTAssertEqual(GlowMotion.ditherThreshold(column: 5, row: 6), GlowMotion.ditherThreshold(column: 1, row: 2))
    }

    func testDistanceAroundTheRoundedCorner() {
        let glow = GlowGeometry.compute(islandWidth: 380, islandHeight: 44, islandRadius: radius, range: 14, blur: 8)
        XCTAssertEqual(GlowMatrix.distance(x: glow.sideInset - 5, y: 30, glow: glow, islandRadius: radius), 5)
        XCTAssertEqual(GlowMatrix.distance(x: glow.width / 2, y: glow.height - glow.sideInset + 7, glow: glow, islandRadius: radius), 7)
        XCTAssertLessThan(GlowMatrix.distance(x: glow.width / 2, y: 40, glow: glow, islandRadius: radius), 0)
        // Diagonally off the bottom-left corner the distance is measured from the corner circle.
        let cornerX = glow.sideInset + radius, cornerY = glow.height - glow.sideInset - radius
        XCTAssertEqual(GlowMatrix.distance(x: cornerX - 30, y: cornerY + 40, glow: glow, islandRadius: radius), 50 - radius, accuracy: 0.001)
    }
}

final class GlowMotionTests: XCTestCase {
    let pitch = 10.0

    func cell(x: Double = 100, distance: Double = 20, location: Double = 0.3, column: Int = 4, row: Int = 7) -> GlowMatrix.Cell {
        GlowMatrix.Cell(column: column, row: row, x: x, y: 50, width: pitch, distance: distance, intensity: exp(-distance / 24), location: location)
    }

    func gain(_ effect: GlowEffect, _ cell: GlowMatrix.Cell, at time: Double) -> Double {
        GlowMotion.gain(effect, cell: cell, time: time, pitch: pitch, glowWidth: 400, breathAmplitude: 0.6)
    }

    func testBreatheStartsFullAndDipsByTheBreathDepth() {
        XCTAssertEqual(gain(.breathe, cell(), at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(gain(.breathe, cell(), at: 1.5), 0.4, accuracy: 1e-9, "the design's 40% trough at half the period")
        XCTAssertEqual(gain(.breathe, cell(), at: 3), 1, accuracy: 1e-9)
    }

    func testThePeriodScalesEveryEffectAndKeepsTheirProportions() {
        // One chosen period drives them all: each effect's own tuned cycle is stretched onto it, so a cycle
        // of any effect lands at the same wall-clock time.
        for effect in GlowEffect.allCases {
            let scaled = GlowMotion.time(effect, since: 8, period: 8)
            XCTAssertEqual(scaled, GlowMotion.basePeriod(effect), accuracy: 1e-9,
                           "one period of \(effect) must be one cycle of its own clock")
        }
        // Breathing returns to full at the period the user picked, not at the design's three seconds.
        XCTAssertEqual(gain(.breathe, cell(), at: GlowMotion.time(.breathe, since: 8, period: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(gain(.breathe, cell(), at: GlowMotion.time(.breathe, since: 4, period: 8)), 0.4, accuracy: 1e-9,
                       "half the chosen period is still the design's 40% trough")
    }

    func testScanBandSweepsLeftToRight() {
        // The band enters from a margin left of the glow and crosses x = 100 at this time.
        let margin = 80.0 / 14 * pitch
        let crossing = (100 + margin) / (400 + 2 * margin) * GlowMotion.scanPeriod
        XCTAssertEqual(gain(.scan, cell(x: 100), at: crossing), 1.2, accuracy: 1e-9)
        XCTAssertEqual(gain(.scan, cell(x: 390), at: crossing), 0.5, accuracy: 0.001)
        XCTAssertLessThan(gain(.scan, cell(x: 100), at: crossing + 0.4), 1.2)
        XCTAssertGreaterThan(gain(.scan, cell(x: 160), at: crossing + 0.4), gain(.scan, cell(x: 100), at: crossing + 0.4))
    }

    func testRippleTravelsOutward() {
        for time in stride(from: 0.0, through: 2, by: 0.25) {
            let near = gain(.ripple, cell(distance: 12), at: time)
            XCTAssertTrue((0.55...1).contains(near))
            // A crest three pitches out arrives one period later.
            XCTAssertEqual(gain(.ripple, cell(distance: 12 + 3 * pitch * 0.5), at: time + GlowMotion.ripplePeriod * 0.5), near, accuracy: 1e-9)
        }
    }

    func testShimmerFlickersAndFlashes() {
        let c = cell()
        XCTAssertEqual(gain(.shimmer, c, at: 0.01), gain(.shimmer, c, at: 0.12), accuracy: 1e-12, "values hold for an eighth of a second")
        let grid = (0..<40).flatMap { column in (0..<40).map { row in cell(column: column, row: row) } }
        let values = grid.map { gain(.shimmer, $0, at: 1.01) }
        XCTAssertTrue(values.allSatisfy { (0.5...0.8).contains($0) || $0 == GlowMotion.maximumGain })
        let flashing = Double(values.filter { $0 == GlowMotion.maximumGain }.count) / Double(values.count)
        XCTAssertEqual(flashing, 0.12, accuracy: 0.04, "about one cell in eight flashes")
        let steps = (0..<32).map { gain(.shimmer, c, at: Double($0) / 8 + 0.01) }
        XCTAssertGreaterThan(Set(steps.map { ($0 * 1000).rounded() }).count, 16, "cells twinkle rather than hold one value")
    }

    func testBootGrowsHoldsAndFades() {
        // Halfway through the growth the front is four pitches out.
        XCTAssertEqual(gain(.boot, cell(distance: 30), at: 1.1), 1)
        XCTAssertEqual(gain(.boot, cell(distance: 50), at: 1.1), 0)
        XCTAssertEqual(gain(.boot, cell(distance: 70), at: 3.0), 1)
        XCTAssertEqual(gain(.boot, cell(distance: 70), at: 4.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(gain(.boot, cell(distance: 30), at: 1.1 + GlowMotion.bootPeriod), 1, "the cycle repeats")
        XCTAssertEqual(GlowMotion.jitter(.boot, cell: cell(distance: 43), time: 1.1, pitch: pitch), 9, "the growing front scrambles")
        XCTAssertEqual(GlowMotion.jitter(.boot, cell: cell(distance: 20), time: 1.1, pitch: pitch), 0)
    }

    func testOnlyFlowMovesTheGradient() {
        let c = cell(location: 0.3)
        for effect in GlowEffect.allCases where effect != .flow {
            XCTAssertEqual(GlowMotion.location(effect, cell: c, time: 2.7), 0.3)
        }
        XCTAssertEqual(gain(.flow, c, at: 2.7), 1, "flow moves colour, not brightness")
        XCTAssertEqual(GlowMotion.location(.flow, cell: c, time: 0), 0.3, accuracy: 1e-9)
        XCTAssertEqual(GlowMotion.location(.flow, cell: c, time: 1.2), 0.7, accuracy: 1e-9)
        XCTAssertTrue(stride(from: 0.0, through: 12, by: 0.3).allSatisfy { (0...1).contains(GlowMotion.location(.flow, cell: c, time: $0)) })
    }

    func testFlowSheenGlidesAcrossTheNotch() {
        XCTAssertEqual(GlowMotion.sheen(.scan, location: 0.5, time: 3), 0, "only flow lightens colours")
        // The band centre enters from the left and crosses the middle half-way through the flow period.
        XCTAssertEqual(GlowMotion.sheen(.flow, location: 0.5, time: GlowMotion.flowPeriod / 2), 1, accuracy: 1e-9)
        XCTAssertEqual(GlowMotion.sheen(.flow, location: 0.1, time: GlowMotion.flowPeriod / 2), 0)
        let early = GlowMotion.sheen(.flow, location: 0.2, time: 1.5), later = GlowMotion.sheen(.flow, location: 0.2, time: 3.5)
        XCTAssertGreaterThan(early, later, "the band moves on toward the right")
        XCTAssertTrue(stride(from: 0.0, through: 1, by: 0.05).allSatisfy { (0...1).contains(GlowMotion.sheen(.flow, location: $0, time: 2.2)) })
        let green = StatusPalette.color(for: .ok)
        XCTAssertEqual(green.mixed(with: .white, amount: 0), green)
        XCTAssertEqual(green.mixed(with: .white, amount: 1), .white)
    }

    func testJitterStaysWithinItsRange() {
        for column in 0..<20 {
            for step in 0..<20 {
                let shift = GlowMotion.jitterShift(2, cell: cell(column: column), time: Double(step) / 8)
                XCTAssertTrue((-2...2).contains(shift))
            }
        }
        XCTAssertEqual(GlowMotion.jitterShift(0, cell: cell(), time: 1), 0)
        XCTAssertEqual(GlowMotion.jitter(.ripple, cell: cell(), time: 1, pitch: pitch), 0)
    }
}

final class GlowStyleSettingsTests: XCTestCase {
    func testDefaultsAndLegacyJSONKeepTheBlurredGlow() throws {
        let defaults = Settings()
        XCTAssertEqual(defaults.glowStyle, .blur)
        XCTAssertEqual(defaults.glowEffect, .breathe)
        XCTAssertEqual(defaults.glowGridPitch, 10)
        XCTAssertEqual(defaults.glowGridCore, 0)
        XCTAssertEqual(defaults.glowGridFade, 5)
        XCTAssertEqual(defaults.glowGridDensity, 1)
        // Settings written before the falloff was split carry one decay length, read as a fade.
        let oldSpread = try JSONDecoder().decode(Settings.self, from: Data(#"{"glowGridSpread":3}"#.utf8))
        XCTAssertEqual(oldSpread.glowGridCore, 0)
        XCTAssertEqual(oldSpread.glowGridFade, 6)
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"glowRange":12}"#.utf8))
        XCTAssertEqual(legacy.glowStyle, .blur)
        XCTAssertEqual(legacy.glowEffect, .breathe)
        XCTAssertEqual(legacy.glowGridPitch, 10)
    }

    func testGridOptionsRoundTripWithClamping() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"glowStyle":"dots","glowGridPitch":30,"glowGridSpread":0.2,"glowGridDensity":9,"glowEffect":"ripple"}"#.utf8))
        XCTAssertEqual(decoded.glowStyle, .dots)
        XCTAssertEqual(decoded.glowEffect, .ripple)
        XCTAssertEqual(decoded.glowGridPitch, Settings.glowGridPitchRange.upperBound)
        // The old decay length migrates to twice itself as a fade, and 0.4 rows is inside the new range.
        XCTAssertEqual(decoded.glowGridFade, 0.4, accuracy: 1e-9)
        XCTAssertEqual(decoded.glowGridDensity, Settings.glowGridDensityRange.upperBound)
        let encoded = try JSONEncoder().encode(decoded.with { $0.glowStyle = .ascii; $0.glowGridPitch = 6; $0.glowGridCore = 2; $0.glowGridFade = 3; $0.glowGridDensity = 1.3; $0.glowEffect = .boot })
        let reloaded = try JSONDecoder().decode(Settings.self, from: encoded)
        XCTAssertEqual(reloaded.glow.pattern(), GlowPattern(style: .ascii, pitch: 6, core: 2, fade: 3, density: 1.3, effect: .boot))
        XCTAssertEqual(reloaded.glow.geometry(islandWidth: 200, islandHeight: 32, islandRadius: 12),
                       reloaded.with { $0.glowGridDensity = 0.6 }.glow.geometry(islandWidth: 200, islandHeight: 32, islandRadius: 12),
                       "density fills cells without changing the grid or the glow's reach")
        XCTAssertEqual(reloaded.glow.pattern(scale: 0.5).pitch, 3)
    }

    func testUnknownValuesFallBackInsteadOfFailing() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"glowStyle":"plasma","glowEffect":"warp","glowBlur":3}"#.utf8))
        XCTAssertEqual(decoded.glowStyle, .blur)
        XCTAssertEqual(decoded.glowEffect, .breathe)
        XCTAssertEqual(decoded.glowBlur, 3)
    }
}
