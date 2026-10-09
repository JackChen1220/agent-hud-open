import AgentHUDCore

@MainActor
public extension UsageStore {
    /// - screen: which display's glow to resolve; nothing asks for the default one.
    func glowAppearance(light: Bool, on screen: String? = nil) -> GlowAppearance {
        let appearance = GlowAppearance.resolve(
            levels: levels,
            paused: isPaused || !isAccessAllowed,
            anyAgentActive: hasLiveSession,
            glow: settings.settings.glow(on: screen),
            light: light
        )
        guard glowHidden else { return appearance }
        return GlowAppearance(
            stops: appearance.stops, peakOpacity: appearance.peakOpacity, troughOpacity: appearance.troughOpacity,
            breathing: appearance.breathing, breathSeconds: appearance.breathSeconds, hidden: true
        )
    }
}
