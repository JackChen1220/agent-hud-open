import SwiftUI
import UniformTypeIdentifiers
import AgentHUDCore

struct AgentOrderRow: View {
    let agent: AgentDescriptor
    let theme: Theme
    var accountVisible = true
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            OrderDragHandle(theme: theme)
            Text(agent.shortName)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(agent.name)
            Toggle(L10n.text("显示", "Show") + " " + agent.displayName, isOn: Binding(get: { agent.enabled }, set: { onToggle($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(!accountVisible)
                .accessibilityIdentifier("agent-display-\(agent.id)")
        }
        .font(.ui(13))
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .foregroundStyle(agent.enabled ? theme.text : theme.secondary)
        .contentShape(Rectangle())
    }
}

struct OrderDragHandle: View {
    let theme: Theme

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.ui(11, .medium))
            .foregroundStyle(theme.tertiary)
            .frame(width: 16, alignment: .leading)
            .accessibilityHidden(true)
    }
}

enum AgentOrderDrag: Equatable {
    case group(String)
    case model(String)
}

/// Provider handles move entire groups; window rows reorder within their account, keeping other accounts' slots.
struct ReorderDropDelegate: DropDelegate {
    let target: AgentOrderDrag
    @Binding var dragging: AgentOrderDrag?
    let settings: SettingsStore

    func validateDrop(info: DropInfo) -> Bool {
        switch (dragging, target) {
        case let (.group(sourceID), .group(targetID)):
            return settings.agents.contains { $0.displayVendor == sourceID }
                && settings.agents.contains { $0.displayVendor == targetID }
        case let (.model(sourceID), .model(targetID)):
            guard let source = settings.agents.first(where: { $0.id == sourceID }),
                  let destination = settings.agents.first(where: { $0.id == targetID }) else { return false }
            return source.displayVendor == destination.displayVendor && source.displayAccountID == destination.displayAccountID
        default: return false
        }
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), dragging != target else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            switch (dragging, target) {
            case let (.group(sourceID), .group(targetID)):
                settings.moveAgentGroup(id: sourceID, to: targetID)
            case let (.model(sourceID), .model(targetID)):
                settings.moveAccountWindow(id: sourceID, to: targetID)
            default: break
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        let accepted = validateDrop(info: info)
        dragging = nil
        return accepted
    }
}
