import AppKit
import SwiftUI
import AgentHUDCore

/// Per-screen HUD placement: pick a display, then pick how it presents the HUD. Every display keeps its
/// own setting, so a laptop can hold its island while the monitor beside it runs the Dynamic Dock — and a
/// display with no notch stops pretending to have one.
struct ScreensPane: View {
    let settings: SettingsStore
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
                    SegmentOption(value: HUDMode.logos, label: L10n.text("动态 Dock", "Dynamic Dock")),
                ], selection: binding(\.mode), theme: theme)
            }
            Text(L10n.text("直接拖动可见的 HUD。拖动刘海会切换为动态 Dock。",
                           "Drag the visible HUD directly. Dragging the notch switches to Dynamic Dock."))
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
            if placement.mode == .logos {
                let size = placement.logoSize
                let points: (Double) -> String = { String(format: L10n.text("%.0f pt", "%.0f pt"), $0) }
                SettingsDivider(theme: theme)
                SliderRow(label: L10n.text("Logo 大小", "Logo size"), value: binding(\.logoSize),
                          range: ScreenPlacement.logoSizeRange, step: 1, format: points, theme: theme)
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
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
    }

    private var subtitle: String {
        guard let current else { return "" }
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
        // Centered queues clear the physical notch without changing their horizontal alignment.
        next.offset = 0.5
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
