import SwiftUI
import AgentHUDCore

struct GlowPane: View {
    let settings: SettingsStore
    let store: UsageStore
    let theme: Theme
    /// The selected screen's placement, so the preview shows the shape that screen actually wears.
    var placement: ScreenPlacement = .default(hasNotch: true)
    /// That screen's real measurements, so the preview is the machine's own shape rather than a stand-in.
    var metrics: ScreenMetrics = .fallback
    /// The display being edited. Every control here writes that screen's own glow.
    var screen: String = ""

    private var glow: GlowSettings { settings.settings.glow(on: screen) }

    /// Edits one field of the selected screen's glow, leaving the rest of it as stored.
    private func binding<Value>(_ field: WritableKeyPath<GlowSettings, Value>) -> Binding<Value> {
        Binding(
            get: { glow[keyPath: field] },
            set: { value in
                var next = glow
                next[keyPath: field] = value
                settings.update { $0.screenGlow[screen] = next }
            }
        )
    }

    /// The same, read and written as a percentage.
    private func percent(_ field: WritableKeyPath<GlowSettings, Double>) -> Binding<Double> {
        let base = binding(field)
        return Binding(get: { base.wrappedValue * 100 }, set: { base.wrappedValue = $0 / 100 })
    }

    private var title: String {
        placement.mode == .logos
            ? L10n.text("背景光晕", "Backdrop glow")
            : L10n.text("灵动岛光晕", "Notch glow")
    }

    var body: some View {
        let current = glow
        let grid = current.style != .blur
        SettingsSection(title: title, theme: theme) {
            SettingsPreview {
                Color.clear.frame(height: 112)
                    .overlay(alignment: .top) {
                        if placement.mode == .logos {
                            LogoQueuePreview(settings: settings, store: store, placement: placement,
                                             metrics: metrics, screen: screen)
                        } else {
                            GlowPreview(
                                appearance: store.glowAppearance(light: false, on: screen), settings: current,
                                islandSize: metrics.islandSize, islandRadius: metrics.islandRadius,
                                previewsMotion: true
                            )
                        }
                    }
            }
            SettingRow(label: L10n.text("光晕样式", "Glow style")) {
                SelectionMenu(title: L10n.text("光晕样式", "Glow style"),
                              options: GlowStyle.allCases.map { SegmentOption(value: $0, label: $0.label) },
                              selection: binding(\.style), theme: theme, width: 160)
            }
            SettingsDivider(theme: theme)
            SettingRow(label: L10n.text("动效", "Effect"),
                       subtitle: L10n.text("一直在动：工作时按工作周期，空闲时慢下来。", "Always in motion: the working period while an agent runs, slower when idle.")) {
                SelectionMenu(title: L10n.text("动效", "Effect"),
                              options: GlowEffect.allCases.map { SegmentOption(value: $0, label: $0.label) },
                              selection: binding(\.effect), theme: theme)
            }
            SettingsDivider(theme: theme)
            if grid {
                SliderRow(label: L10n.text("点距", "Grid pitch"), value: binding(\.gridPitch), range: GlowSettings.gridPitchRange, step: 1, format: { "\(Int($0)) pt" }, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("密度", "Density"), value: binding(\.gridDensity), range: GlowSettings.gridDensityRange, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" }, theme: theme)
                SettingsDivider(theme: theme)
                let rows: (Double) -> String = { String(format: L10n.text("%d 排", "%d rows"), Int($0.rounded())) }
                SliderRow(label: L10n.text("实心", "Solid"), value: binding(\.gridCore), range: GlowSettings.gridCoreRange, step: 1,
                          format: rows, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("渐隐", "Fade"), value: binding(\.gridFade), range: GlowSettings.gridFadeRange, step: 1,
                          format: rows, theme: theme)
                SettingsDivider(theme: theme)
            }
            SliderRow(label: L10n.text("光晕亮度", "Brightness"), value: percent(\.brightness), range: 20...100, step: 5, format: { "\(Int($0))%" }, theme: theme)
            if !grid {
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("光晕范围", "Glow range"), value: binding(\.range), range: GlowSettings.sizeRange, step: 1, format: { "\(Int($0)) px" }, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("羽化", "Feather"), value: binding(\.blur), range: GlowSettings.sizeRange, step: 1, format: { "\(Int($0)) px" }, theme: theme)
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("仅向外扩散", "Outward only"),
                    subtitle: L10n.text("贴近 HUD 的边缘更浓，向外逐渐变淡。", "Keep the rim defined and fade gently outward."),
                    isOn: binding(\.outwardOnly)
                )
            }
            let seconds: (Double) -> String = { String(format: L10n.text("%.1f 秒", "%.1f s"), $0) }
            // The period drives whichever effect is selected, not just breathing; only the depth is breathe's own.
            SettingsDivider(theme: theme)
            SliderRow(label: L10n.text("工作时周期", "Working period"), value: binding(\.breathSeconds), range: 1...12, step: 0.5, format: seconds, theme: theme)
            SettingsDivider(theme: theme)
            SliderRow(label: L10n.text("空闲时周期", "Idle period"), value: binding(\.idleBreathSeconds), range: 1...24, step: 0.5, format: seconds, theme: theme)
            if current.effect == .breathe {
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("呼吸幅度", "Breath depth"), value: percent(\.breathAmplitude), range: 0...100, step: 5, format: { "\(Int($0))%" }, theme: theme)
            }
            Text(caption(grid: grid, effect: current.effect))
                .font(.ui(11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func caption(grid: Bool, effect: GlowEffect) -> String {
        let density = grid ? L10n.text("密度决定点和字符占满格子的程度，调高后空隙更小，超过 100% 会互相重叠。实心是满强度的排数，渐隐是它之后淡出的排数。", "Density sets how much of each cell a mark fills; raise it for smaller gaps, and past 100% marks overlap. Solid is how many rows keep full strength; fade is how many it dies away over. ") : ""
        if !grid && effect == .breathe {
            return L10n.text("Agent 运行时按工作周期呼吸，空闲时按空闲周期放慢；只有暂停检测或还没有可显示的读数时才静止。",
                             "The glow breathes at the working period while an agent runs and slows to the idle period otherwise; it rests only while detection is paused or no agent has a reading to show.")
        }
        return density + L10n.text("上方预览会一直播放所选动效；HUD 上 Agent 运行时按工作周期播放，空闲时按空闲周期放慢。",
                                   "The preview always plays the selected effect; the HUD plays it at the working period while an agent runs and at the idle period otherwise.")
    }
}

private extension GlowStyle {
    var label: String {
        switch self {
        case .blur: L10n.text("柔光", "Soft")
        case .dots: L10n.text("点阵", "Dots")
        case .ascii: L10n.text("字符  .:-=+*#%@", "ASCII  .:-=+*#%@")
        case .blocks: L10n.text("色块  ░▒▓█", "Blocks  ░▒▓█")
        case .braille: L10n.text("盲文  ⠁⠃⠇⡇⣿", "Braille  ⠁⠃⠇⡇⣿")
        case .binary: L10n.text("二进制  0 1", "Binary  0 1")
        }
    }
}

private extension GlowEffect {
    var label: String {
        switch self {
        case .breathe: L10n.text("呼吸", "Breathe")
        case .flow: L10n.text("流光", "Flow")
        case .scan: L10n.text("扫描", "Scan")
        case .ripple: L10n.text("涟漪", "Ripple")
        case .shimmer: L10n.text("闪烁", "Shimmer")
        case .boot: L10n.text("启动", "Boot")
        }
    }
}

/// One display's real measurements, so a preview shows that machine's shape instead of a generic one.
struct ScreenMetrics: Equatable {
    var menuBar: CGFloat
    /// The physical notch, when the display has one.
    var notch: CGSize?

    static let fallback = ScreenMetrics(menuBar: 24, notch: nil)

    @MainActor
    init(screen: NSScreen?) {
        menuBar = screen.map(ScreenIdentity.menuBarHeight(of:)) ?? 24
        notch = screen.flatMap(ScreenIdentity.notchSize(of:))
    }

    init(menuBar: CGFloat, notch: CGSize?) {
        self.menuBar = menuBar
        self.notch = notch
    }

    /// What the notch preview draws: the real notch, or the bar that stands in for one.
    var islandSize: CGSize { notch ?? CGSize(width: NotchGeometry.fallbackWidth, height: menuBar) }
    var islandRadius: CGFloat { notch == nil ? NotchGeometry.fallbackCornerRadius : NotchGeometry.notchCornerRadius }
}

/// A horizontal sample of the Dynamic Dock's marks and backdrop, independent of the selected screen edge.
/// The curtain uses the same flat lip as the real HUD, clipped back to the marks' run.
struct LogoQueuePreview: View {
    let settings: SettingsStore
    let store: UsageStore
    let placement: ScreenPlacement
    let metrics: ScreenMetrics
    var screen: String = ""
    /// Overrides what the queue shows. Only the snapshot runner uses it, to lay out every bundled mark.
    var marks: [LogoQueueItem]?

    private var samplePlacement: ScreenPlacement {
        var sample = placement
        sample.edge = .top
        return sample
    }

    var body: some View {
        let items = marks ?? LogoQueueItem.queue(rows: store.queueVendors)
        let config = LogoQueueConfig(items: items, placement: samplePlacement, settings: settings.settings)
        let strip = max(metrics.menuBar, config.logo)
        let margin = GlowWindowController.logoEdgeMargin(stripThickness: strip)
        // The lip is run past the marks by the same amount the real backdrop uses, so the preview's field
        // falls as steeply as the one on screen instead of by a number of its own.
        let overhang = GlowWindowController.backdropOverhang(settings.settings.glow(on: screen))
        GeometryReader { proxy in
            // The marks' run plus the same margin the real backdrop reaches past them, faded over exactly
            // that distance so the ends die away instead of being cut.
            let width = max(1, min(proxy.size.width, config.size.width + margin * 2))
            let stop = margin / width
            ZStack(alignment: .top) {
                GlowPreview(
                    appearance: store.glowAppearance(light: false, on: screen),
                    settings: settings.settings.glow(on: screen),
                    islandSize: CGSize(width: width + overhang * 2, height: 2), islandRadius: 0, previewsMotion: true
                )
                .frame(width: width, alignment: .center)
                .clipped()
                .mask(alignment: .top) {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: stop),
                        .init(color: .black, location: 1 - stop),
                        .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                }
                if placement.showsLogos {
                    LogoQueueView(config: config, light: false, previewsMotion: true)
                        .frame(width: width, height: strip)
                }
            }
            .frame(width: proxy.size.width, alignment: .center)
        }
    }
}
