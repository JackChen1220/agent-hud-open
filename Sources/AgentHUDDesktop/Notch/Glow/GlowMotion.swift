import AgentHUDCore
import Foundation

/// Motion effects for the dot and ASCII glow styles, ported from the ASCII HUD bar design. An effect scales each
/// cell's resting intensity by a gain; flow also moves where cells sample the colour gradient, and shimmer and
/// boot scramble ASCII density levels. Time is seconds since the effect started; lengths scale with the pitch
/// (the design used a 14 px grid).
public enum GlowMotion {
    /// The highest gain any effect applies (scan's bright band).
    public static let maximumGain = 1.2

    /// Seconds one cycle takes at the design's tuning. The user picks one period and every effect scales to
    /// it, so each keeps the proportion it was tuned with instead of needing a slider of its own.
    public static let breathePeriod = 3.0
    public static let scanPeriod = 2.6
    public static let ripplePeriod = 1.8
    public static let flowPeriod = 6.0
    public static let bootPeriod = 4.4
    /// Shimmer has no cycle of its own; this is the clock its eight-times-a-second twinkle scales against.
    public static let shimmerPeriod = 3.0

    public static func basePeriod(_ effect: GlowEffect) -> Double {
        switch effect {
        case .breathe: return breathePeriod
        case .flow: return flowPeriod
        case .scan: return scanPeriod
        case .ripple: return ripplePeriod
        case .shimmer: return shimmerPeriod
        case .boot: return bootPeriod
        }
    }

    /// Effect time for a user-chosen period. Stretching the clock slows every effect down together —
    /// shimmer's twinkle and boot's sweep included — and the effects keep their relative pace.
    public static func time(_ effect: GlowEffect, since seconds: Double, period: Double) -> Double {
        seconds * basePeriod(effect) / max(0.25, period)
    }

    /// - t: effect time from `time(_:since:period:)`, already scaled to the user's period.
    public static func gain(_ effect: GlowEffect, cell: GlowMatrix.Cell, time t: Double, pitch: Double,
                            glowWidth: Double, breathAmplitude: Double) -> Double {
        switch effect {
        case .breathe:
            let depth = min(1, max(0, breathAmplitude))
            // Starts at full size so the effect eases out of the resting frame.
            return 1 - depth * (0.5 - 0.5 * cos(2 * .pi * t / breathePeriod))
        case .flow:
            return 1
        case .scan:
            let margin = 80.0 / 14 * pitch
            let center = fraction(t / scanPeriod) * (glowWidth + 2 * margin) - margin
            let offset = (cell.x - center) / (40.0 / 14 * pitch)
            return 0.5 + 0.7 * exp(-offset * offset)
        case .ripple:
            return 0.55 + 0.45 * (0.5 + 0.5 * sin(2 * .pi * (cell.distance / (3 * pitch) - t / ripplePeriod)))
        case .shimmer:
            // Cells flicker between half and four fifths of their brightness, and about one in eight flashes to
            // the brightest level, changing eight times a second.
            let step = (t * 8).rounded(.down)
            return noise(cell, step: step + 53) < 0.12 ? maximumGain : 0.5 + 0.3 * noise(cell, step: step)
        case .boot:
            let phase = bootPhase(t)
            if phase < 2.2 { return cell.distance < bootFront(phase, pitch: pitch) ? 1 : 0 }
            if phase < 3.6 { return 1 }
            return 1 - (phase - 3.6) / 0.8
        }
    }

    /// How far flow lightens a cell toward white: a soft band glides along the notch once per flow period, so the
    /// effect still moves when every agent shares one status colour. 0 outside the band, 1 at its centre.
    public static func sheen(_ effect: GlowEffect, location: Double, time t: Double) -> Double {
        guard effect == .flow else { return 0 }
        let center = fraction(t / flowPeriod) * 1.5 - 0.25
        let offset = (location - center) / 0.25
        guard abs(offset) < 1 else { return 0 }
        let wave = cos(offset * .pi / 2)
        return wave * wave
    }

    /// Where a cell samples the colour gradient. Only flow moves it, bouncing the gradient along the notch.
    public static func location(_ effect: GlowEffect, cell: GlowMatrix.Cell, time t: Double) -> Double {
        guard effect == .flow else { return cell.location }
        return triangle(cell.location * 0.5 + t / flowPeriod)
    }

    /// How many ASCII density levels a cell may jump: shimmer's occasional twinkle and boot's scrambled front.
    public static func jitter(_ effect: GlowEffect, cell: GlowMatrix.Cell, time t: Double, pitch: Double) -> Int {
        switch effect {
        case .shimmer:
            return noise(cell, step: (t * 8).rounded(.down) + 101) < 0.1 ? 2 : 0
        case .boot:
            let phase = bootPhase(t)
            return phase < 2.2 && abs(cell.distance - bootFront(phase, pitch: pitch)) < 0.8 * pitch ? 9 : 0
        case .breathe, .flow, .scan, .ripple:
            return 0
        }
    }

    /// A level shift within ±`jitter`, held for one eighth of a second.
    public static func jitterShift(_ jitter: Int, cell: GlowMatrix.Cell, time t: Double) -> Int {
        guard jitter > 0 else { return 0 }
        let pick = noise(cell, step: (t * 8).rounded(.down) + 7) * Double(2 * jitter + 1)
        return min(2 * jitter, Int(pick.rounded(.down))) - jitter
    }

    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    /// Ordered-dither threshold from a 4 × 4 Bayer matrix; a mark is on where 0.1 + 0.9 · value exceeds it.
    public static func ditherThreshold(column: Int, row: Int) -> Double {
        (bayer[(row & 3) * 4 + (column & 3)] + 0.5) / 16
    }

    /// Deterministic 0…1 noise for one cell and time step.
    public static func noise(_ cell: GlowMatrix.Cell, step: Double) -> Double {
        fraction(sin(Double(cell.column) * 12.9898 + Double(cell.row) * 78.233 + step * 37.719) * 43758.5453)
    }

    static func bootPhase(_ t: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: bootPeriod)
        return phase < 0 ? phase + bootPeriod : phase
    }

    static func bootFront(_ phase: Double, pitch: Double) -> Double { phase / 2.2 * 8 * pitch }

    static func fraction(_ value: Double) -> Double { value - value.rounded(.down) }

    static func triangle(_ value: Double) -> Double { 1 - abs(2 * fraction(value) - 1) }
}
