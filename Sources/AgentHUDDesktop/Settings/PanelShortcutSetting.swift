import SwiftUI
import Carbon.HIToolbox
import AgentHUDCore

struct PanelShortcutSetting: View {
    let settings: SettingsStore
    @State private var monitor: Any?
    @State private var recording = false
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(label: L10n.text("展开 / 收起", "Expand / collapse"),
                       subtitle: L10n.text("在鼠标所在屏幕打开；再次按下收起。", "Open on the pointer's display; press again to collapse.")) {
                Toggle("", isOn: Binding(get: { settings.settings.panelShortcut.enabled }, set: { enabled in
                    endRecording(); settings.update { $0.panelShortcut.enabled = enabled }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Button(recording ? L10n.text("按下组合键…", "Press shortcut…") : settings.settings.panelShortcut.label) { beginRecording() }
                    .disabled(!settings.settings.panelShortcut.enabled).frame(minWidth: 110)
                Button(L10n.text("恢复默认", "Reset")) { endRecording(); settings.update { $0.panelShortcut = PanelShortcut() } }
            }
            if let error = HotKeyCenter.shared.panelShortcutError ?? hint {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }.onDisappear { endRecording() }
    }

    private func beginRecording() {
        endRecording(); recording = true
        hint = L10n.text("包含 Command 或 Control；Esc 取消。", "Include Command or Control; Esc cancels.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { endRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control),
                  let character = event.charactersIgnoringModifiers?.uppercased(), character.count == 1,
                  character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
            var mask: UInt32 = 0
            var label = ""
            for (flag, carbon, symbol): (NSEvent.ModifierFlags, Int, String) in [
                (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
            ] where flags.contains(flag) { mask |= UInt32(carbon); label += symbol }
            settings.update { $0.panelShortcut.keyCode = UInt32(event.keyCode); $0.panelShortcut.modifiers = mask; $0.panelShortcut.label = label + character }
            endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; hint = nil
    }
}
