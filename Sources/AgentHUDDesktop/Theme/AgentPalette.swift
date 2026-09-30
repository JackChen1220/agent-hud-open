import AgentHUDCore

/// Per-agent colors used in the stats window (distinct from the status colors).
public enum AgentPalette {
    public static let colors: [RGBA] = [
        RGBA(hex: 0xc084fc), // Opus
        RGBA(hex: 0x60a5fa), // Sonnet
        RGBA(hex: 0x2dd4bf), // ChatGPT
        RGBA(hex: 0xfb923c), // Codex
        RGBA(hex: 0xf472b6),
        RGBA(hex: 0xa3e635),
    ]

    public static func color(index: Int) -> RGBA {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
