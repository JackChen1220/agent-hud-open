import AgentHUDCore

/// How a glow's settings lay out its grid and its rect around an island.
public extension GlowSettings {
    /// Grid options with the pitch scaled like range and feather for small previews.
    func pattern(scale: Double = 1) -> GlowPattern {
        GlowPattern(style: style, pitch: gridPitch * scale, core: gridCore, fade: gridFade,
                    density: gridDensity, effect: effect)
    }

    /// The glow rect around an island. The blurred style uses range and feather; the grid styles size the
    /// rect to the farthest dot, with no blur margin above the screen edge.
    func geometry(islandWidth: Double, islandHeight: Double, islandRadius: Double, scale: Double = 1) -> GlowGeometry {
        guard style != .blur else {
            return GlowGeometry.compute(islandWidth: islandWidth, islandHeight: islandHeight, islandRadius: islandRadius,
                                        range: range * scale, blur: blur * scale)
        }
        let reach = GlowMatrix.reach(pitch: gridPitch * scale, core: gridCore, fade: gridFade)
        return GlowGeometry.compute(islandWidth: islandWidth, islandHeight: islandHeight, islandRadius: islandRadius,
                                    range: reach.rounded(.up), blur: 0)
    }
}
