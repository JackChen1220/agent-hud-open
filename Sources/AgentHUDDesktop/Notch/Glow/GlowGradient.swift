import AgentHUDCore
import Foundation

public struct GradientStop: Hashable, Sendable {
    public let color: RGBA
    /// 0…1 along the horizontal axis.
    public let location: Double

    public init(color: RGBA, location: Double) {
        self.color = color
        self.location = location
    }
}

/// What the notch glow should look like right now.
public struct GlowAppearance: Hashable, Sendable {
    public let stops: [GradientStop]
    /// Peak opacity (brightness). Breathing dips below this.
    public let peakOpacity: Double
    /// Lowest opacity reached while breathing.
    public let troughOpacity: Double
    public let breathing: Bool
    public let breathSeconds: Double
    public let hidden: Bool

    public init(stops: [GradientStop], peakOpacity: Double, troughOpacity: Double, breathing: Bool, breathSeconds: Double, hidden: Bool) {
        self.stops = stops
        self.peakOpacity = peakOpacity
        self.troughOpacity = troughOpacity
        self.breathing = breathing
        self.breathSeconds = breathSeconds
        self.hidden = hidden
    }

    /// The same glow with drawing suppressed, for surfaces that have no silhouette to rim.
    public func suppressed() -> GlowAppearance {
        GlowAppearance(stops: stops, peakOpacity: peakOpacity, troughOpacity: troughOpacity,
                       breathing: breathing, breathSeconds: breathSeconds, hidden: true)
    }

    public static let idleOpacity = 0.35

    public static func idle(hidden: Bool = false) -> GlowAppearance {
        GlowAppearance(stops: GlowGradient.idleStops, peakOpacity: idleOpacity, troughOpacity: idleOpacity, breathing: false, breathSeconds: 3, hidden: hidden)
    }

    /// Resolves the glow from live status. The colours always follow the quota; activity only decides
    /// how fast the effect runs, so a quiet stretch never makes the glow fade or vanish.
    /// - paused: detection paused by the user → grey, still.
    /// - anyAgentActive: at least one agent has a running session → the working period; otherwise the
    ///   idle period, which is longer. The HUD keeps moving either way, so resting still reads as alive.
    public static func resolve(
        levels: [StatusLevel],
        paused: Bool,
        anyAgentActive: Bool,
        glow: GlowSettings,
        light: Bool = false
    ) -> GlowAppearance {
        if paused { return .idle() }
        if levels.isEmpty { return .idle() }
        // Always in motion: working breathes fast, resting breathes slowly.
        let period = anyAgentActive ? glow.breathSeconds : glow.idleBreathSeconds
        let peak = min(1, max(0, glow.brightness))
        let trough = peak * (1 - min(1, max(0, glow.breathAmplitude)))
        return GlowAppearance(
            stops: GlowGradient.stops(levels: levels, light: light),
            peakOpacity: peak,
            troughOpacity: trough,
            breathing: true,
            breathSeconds: max(0.5, period),
            hidden: false
        )
    }
}

public enum GlowGradient {
    public static let idleStops = [
        GradientStop(color: StatusPalette.idle, location: 0),
        GradientStop(color: StatusPalette.idle, location: 1),
    ]

    /// Stop i of n sits at (i + 0.5) / n so neighbouring colors blend naturally; the ends clamp to the outer colors.
    public static func stops(levels: [StatusLevel], light: Bool = false) -> [GradientStop] {
        let n = levels.count
        guard n > 0 else { return idleStops }
        return levels.enumerated().map { index, level in
            GradientStop(color: StatusPalette.color(for: level, light: light), location: (Double(index) + 0.5) / Double(n))
        }
    }

    /// Colour at `location` (0…1) along the stops, clamped to the outer colours like the drawn gradient.
    public static func color(at location: Double, stops: [GradientStop]) -> RGBA {
        guard let first = stops.first, let last = stops.last else { return StatusPalette.idle }
        if stops.count == 1 || location <= first.location { return first.color }
        if location >= last.location { return last.color }
        for (previous, next) in zip(stops, stops.dropFirst()) where location <= next.location {
            let span = next.location - previous.location
            let t = span > 0 ? (location - previous.location) / span : 1
            return RGBA(
                red: previous.color.red + (next.color.red - previous.color.red) * t,
                green: previous.color.green + (next.color.green - previous.color.green) * t,
                blue: previous.color.blue + (next.color.blue - previous.color.blue) * t,
                alpha: previous.color.alpha + (next.color.alpha - previous.color.alpha) * t
            )
        }
        return last.color
    }

    /// CSS-equivalent string, handy for debugging and tests.
    public static func css(_ stops: [GradientStop]) -> String {
        "linear-gradient(90deg," + stops.map { "\($0.color.hexString) \(String(format: "%.1f", $0.location * 100))%" }.joined(separator: ",") + ")"
    }
}
