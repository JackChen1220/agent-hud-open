import AgentHUDCore

/// Status colors from the design tokens. Dark values are the defaults; light values are the macOS system tints.
public enum StatusPalette {
    public static let ok = RGBA(hex: 0x3ddc84)
    public static let warning = RGBA(hex: 0xffd23f)
    public static let critical = RGBA(hex: 0xff453a)
    public static let okLight = RGBA(hex: 0x30d158)
    public static let warningLight = RGBA(hex: 0xffcc00)
    public static let warningTextLight = RGBA(hex: 0xc7a100)
    public static let criticalLight = RGBA(hex: 0xff3b30)
    /// Paused / idle glow.
    public static let idle = RGBA(hex: 0x9a9aa0)

    public static func color(for level: StatusLevel, light: Bool = false) -> RGBA {
        switch (level, light) {
        case (.ok, false): return ok
        case (.warning, false): return warning
        case (.critical, false): return critical
        case (.ok, true): return okLight
        case (.warning, true): return warningLight
        case (.critical, true): return criticalLight
        }
    }

    /// Text on light surfaces needs a darker yellow to stay legible.
    public static func textColor(for level: StatusLevel, light: Bool = false) -> RGBA {
        if light && level == .warning { return warningTextLight }
        return color(for: level, light: light)
    }
}
