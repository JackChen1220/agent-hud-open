import AppKit
import SwiftUI
import AgentHUDCore

/// Per-screen HUD placement: pick a display, then pick how it presents the HUD. Every display keeps its
/// own setting, so a laptop can hold its island while the monitor beside it runs Dynamic mode — and a
/// display with no notch stops pretending to have one.
struct ScreensPane: View {
    let settings: SettingsStore
    /// Where the Simple preview's figures come from; without it the preview shows sample ones.
    var store: UsageStore? = nil
    let theme: Theme

    @Binding var selected: String
    @State private var screens: [Screen] = ScreensPane.attached()

    struct Screen: Identifiable, Hashable {
        let key: String
        let name: String
        let hasNotch: Bool
        var id: String { key }
    }

    private var current: Screen? {
        screens.first { $0.key == selected } ?? screens.first
    }

    private var placement: ScreenPlacement {
        guard let current else { return .default(hasNotch: false) }
        return settings.settings.placement(on: current.key, hasNotch: current.hasNotch)
    }

    /// Edits one field of the selected screen's placement, leaving the rest as stored.
    private func binding<Value>(_ field: WritableKeyPath<ScreenPlacement, Value>) -> Binding<Value> {
        Binding(
            get: { placement[keyPath: field] },
            set: { value in
                guard let key = current?.key else { return }
                var next = placement
                next[keyPath: field] = value
                settings.update { $0.screens[key] = next }
            }
        )
    }

    /// Choosing a docked mode on a display with a notch: a short strip at top centre would sit behind the
    /// hardware, so one that has never been moved starts where Reset Position puts it.
    private var modeBinding: Binding<HUDMode> {
        Binding(
            get: { placement.mode },
            set: { mode in
                guard let current else { return }
                var next = placement
                if next.mode == .notch, mode == .simple, current.hasNotch, next.edge == .top, next.offset == 0.5 {
                    next.offset = 0
                }
                next.mode = mode
                settings.update { $0.screens[current.key] = next }
            }
        )
    }

    /// The panel as this screen's settings draw it, laid along the top edge whichever edge it is parked on.
    private var previewMeter: SimpleMeterConfig {
        var sample = placement
        sample.edge = .top
        var items = store.map {
            SimpleMeterItem.items(rows: $0.rows, balances: SimpleMeterItem.balances($0),
                                  working: $0.queueVendors.filter(\.isWorking).map(\.vendor))
        } ?? []
        if items.isEmpty { items = SimpleMeterItem.samples }
        // The preview shows what the bot switch does even while nothing is running.
        if sample.simpleBots, !items.contains(where: \.isWorking) { items[0].isWorking = true }
        return SimpleMeterConfig(items: items, placement: sample)
    }

    var body: some View {
        SettingsSection(title: L10n.text("屏幕", "Screens"),
                        subtitle: L10n.text("每块屏幕单独设置。", "Set each display on its own."), theme: theme) {
            if screens.count > 1 {
                SettingRow(label: L10n.text("显示器", "Display")) {
                    SelectionMenu(title: L10n.text("显示器", "Display"),
                                  options: screens.map { SegmentOption(value: $0.key, label: $0.name) },
                                  selection: $selected, theme: theme, width: 200)
                }
                SettingsDivider(theme: theme)
            }
            SettingRow(label: L10n.text("HUD 形态", "HUD"), subtitle: subtitle) {
                SegmentedPills(options: [
                    SegmentOption(value: HUDMode.notch, label: L10n.text("刘海", "Notch")),
                    SegmentOption(value: HUDMode.simple, label: L10n.text("简约", "Simple")),
                    SegmentOption(value: HUDMode.logos, label: L10n.text("动态", "Dynamic")),
                ], selection: modeBinding, theme: theme)
            }
            Text(L10n.text("直接拖动可见的 HUD。拖动刘海会切换为「动态」。",
                           "Drag the visible HUD directly. Dragging the notch switches to Dynamic."))
                .font(.ui(11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
            SettingsDivider(theme: theme)
            SettingRow(label: L10n.text("位置", "Position"),
                       subtitle: L10n.text("回到这块屏幕的顶部安全位置。", "Return to a reachable position at the top of this display.")) {
                Button(L10n.text("重置位置", "Reset Position"), action: resetPosition)
                    .controlSize(.small)
                    .accessibilityIdentifier("hud-reset-position")
                    .disabled(current == nil)
            }
            if placement.mode.isDocked {
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("按 agent 分开", "Separate agents"),
                    subtitle: L10n.text("悬停某个标志只展开该 agent 的面板；请求和提醒从发出它的 agent 的标志旁展开，其他标志保持不动。",
                                        "Hovering a mark opens that agent's own panel. Requests and reminders open beside the mark of the agent that sent them, and the other marks stay."),
                    isOn: binding(\.separatesAgents)
                )
            }
            if placement.mode == .logos {
                let size = placement.logoSize
                let points: (Double) -> String = { String(format: L10n.text("%.0f pt", "%.0f pt"), $0) }
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("Logo 大小", "Logo size"), value: binding(\.logoSize),
                          range: ScreenPlacement.logoSizeRange, step: 1, format: points, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("Logo 离屏幕边缘", "Logo edge distance"), value: binding(\.logoEdgeDistance),
                          range: ScreenPlacement.logoEdgeDistanceRange, step: 1, format: points, theme: theme)
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("Logo 间距", "Logo spacing"), value: binding(\.gapScale),
                          range: ScreenPlacement.gapScaleRange, step: 0.05,
                          format: { points($0 * size) }, theme: theme)
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("显示 Logo", "Show logos"),
                    subtitle: L10n.text("关掉只留背景；背景仍占着这些 Logo 的位置和宽度。",
                                        "Off leaves the backdrop alone, still where the logos would have been."),
                    isOn: binding(\.showsLogos)
                )
            }
            if placement.mode == .simple {
                let preview = previewMeter
                SettingsDivider(theme: theme)
                SettingsPreview {
                    Color.clear.frame(height: 84)
                        .overlay {
                            SimpleMeterView(config: preview)
                                .frame(width: preview.stripSize.width, height: preview.stripSize.height)
                        }
                }
                SliderRow(label: L10n.text("大小", "Size"), value: binding(\.simpleSize),
                          range: ScreenPlacement.simpleSizeRange, step: 1,
                          format: { String(format: "%.0f pt", $0) }, theme: theme)
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("显示圆环", "Show rings"),
                    subtitle: L10n.text("每个 agent 用得最多的额度窗口，画成套在标志外的圆环。",
                                        "Each agent's most used quota window, as a ring round its mark."),
                    isOn: binding(\.showsRings)
                )
                if placement.showsRings {
                    SettingsDivider(theme: theme)
                    SliderRow(label: L10n.text("圆环粗细", "Ring thickness"), value: binding(\.ringWidth),
                              range: ScreenPlacement.ringWidthRange, step: 0.5,
                              format: { String(format: "%.1f pt", $0) }, theme: theme)
                }
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("显示数字", "Show numbers"),
                    subtitle: L10n.text("在标志旁写出已用百分比。", "The percentage used, beside the mark."),
                    isOn: binding(\.showsNumbers)
                )
                SettingsDivider(theme: theme)
                SettingsToggleRow(
                    label: L10n.text("Bot 动画", "Bot animation"),
                    subtitle: L10n.text("工作中的 agent，标志变成它的 Bot；空闲时偶尔变成 Bot 活动几秒。",
                                        "A working agent's mark becomes its bot. Idle marks become bots for a few seconds now and then."),
                    isOn: binding(\.simpleBots)
                )
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
    }

    private var subtitle: String {
        guard let current else { return "" }
        if placement.mode == .simple {
            return L10n.text("贴着屏幕边缘的悬浮面板，没有背景光晕。", "A floating panel on a screen edge, with no glow behind it.")
        }
        if placement.mode == .logos {
            return L10n.text("贴着屏幕边缘停靠，向屏幕内展开。", "Dock on a screen edge and open inward.")
        }
        return current.hasNotch
            ? L10n.text("围绕这块屏幕的刘海显示。", "Use this display's physical notch.")
            : L10n.text("这块屏没有刘海，刘海形态会画一条替代的黑条。",
                        "No notch here — the notch shape draws a stand-in bar instead.")
    }

    private func resetPosition() {
        guard let current else { return }
        var next = placement
        next.edge = .top
        // Dynamic queues remain centred below the notch; Simple stays clear of the hardware.
        next.offset = current.hasNotch && next.mode == .simple ? 0 : 0.5
        settings.update { $0.screens[current.key] = next }
    }

    private func refresh() {
        ScreenIdentity.forgetKeys()
        screens = Self.attached()
        if !screens.contains(where: { $0.key == selected }) {
            selected = screens.first?.key ?? ""
        }
    }

    static func attached() -> [Screen] {
        NSScreen.screens.map {
            Screen(key: ScreenIdentity.key(for: $0), name: ScreenIdentity.name(for: $0),
                   hasNotch: ScreenIdentity.hasNotch($0))
        }
    }
}
