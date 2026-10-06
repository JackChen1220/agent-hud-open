import SwiftUI
import AgentHUDCore

struct IslandAlertCompactView: View {
    let alert: IslandAlert
    let cameraWidth: CGFloat
    let height: CGFloat
    let onOpen: () -> Void
    var waitingRequests: [PermissionRequest] = []

    var body: some View {
        switch alert {
        case .permission(let request):
            PermissionAlertCompactView(request: request, cameraWidth: cameraWidth, height: height,
                                       waiting: max(1, waitingRequests.count))
        case .quota(let event):
            QuotaAlertCompactView(alert: event, cameraWidth: cameraWidth, height: height, onOpen: onOpen)
        case .resetCredits(let event):
            ResetCreditAlertCompactView(grant: event, cameraWidth: cameraWidth, height: height, onOpen: onOpen)
        case .completion(let event):
            Button(action: onOpen) {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        AgentLogo(vendor: event.vendor, size: 17)
                        Text(event.vendor).font(.ui(13, .semibold)).lineLimit(1)
                    }.frame(width: IslandController.alertWingWidth, alignment: .leading)
                    Color.clear.frame(width: cameraWidth)
                    HStack(spacing: 7) {
                        TurnEndedSymbol()
                        Text(L10n.text("有新回复", "New reply"))
                            .font(.ui(12, .medium)).foregroundStyle(Color(alert.accent))
                    }.frame(width: IslandController.alertWingWidth, alignment: .trailing)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, IslandController.alertSidePadding).frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("island-alert-sessionCompleted")
            .accessibilityLabel("\(event.vendor) · \(L10n.text("有新回复", "New reply")) · \(event.task)")
        }
    }
}

struct IslandAlertDetailView: View {
    let alert: IslandAlert
    let onOpen: () -> Void
    let onDecide: (PermissionDecision) -> Void
    var waitingRequests: [PermissionRequest] = []
    var onSelectRequest: (String) -> Void = { _ in }
    var body: some View {
        switch alert {
        case .permission(let request):
            PermissionAlertDetailView(request: request, onDecide: onDecide,
                                      all: waitingRequests, onSelect: onSelectRequest)
        case .quota(let event): QuotaAlertDetailView(alert: event, onOpen: onOpen)
        case .resetCredits(let event): ResetCreditAlertDetailView(grant: event, onOpen: onOpen)
        case .completion(let event):
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    AgentLogo(vendor: event.vendor, size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.vendor).font(.ui(13, .semibold))
                        Text(event.model).font(.ui(10)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    TurnEndedSymbol()
                    Text(L10n.text("有新回复", "New reply"))
                        .font(.ui(11)).foregroundStyle(Color(alert.accent))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.task).font(.ui(15, .medium)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = event.message {
                        Text(message).font(.ui(12)).foregroundStyle(.white.opacity(0.68)).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text(event.completedAt.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    if let start = event.startedAt {
                        Text(Countdown.compact(max(0, event.completedAt.timeIntervalSince(start))))
                    }
                }.font(.tabular(11)).foregroundStyle(.white.opacity(0.5))
                Button(action: onOpen) {
                    Text(L10n.text("查看 Token 用量", "View token usage"))
                        .font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }.foregroundStyle(.white)
        }
    }
}

struct IslandAlertInlineView: View {
    let alert: IslandAlert
    let onOpen: () -> Void
    let onDecide: (PermissionDecision) -> Void
    var waitingRequests: [PermissionRequest] = []
    var body: some View {
        switch alert {
        case .permission(let request): PermissionAlertInlineView(request: request, onDecide: onDecide,
                                                                 waiting: max(1, waitingRequests.count))
        case .quota(let event): QuotaAlertInlineView(alert: event, onOpen: onOpen)
        case .resetCredits(let event): ResetCreditAlertInlineView(grant: event, onOpen: onOpen)
        case .completion(let event):
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    TurnEndedSymbol()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("\(event.vendor) · 有新回复", "\(event.vendor) · New reply"))
                            .font(.ui(12, .medium)).foregroundStyle(Color(alert.accent))
                        Text(event.task).font(.ui(10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        if let message = event.message {
                            Text(message).font(.ui(10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.ui(10))
                }.foregroundStyle(.white).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

private struct TurnEndedSymbol: View {
    var body: some View {
        Image(systemName: "text.bubble")
            .symbolRenderingMode(.palette)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(IslandAlert.turnAccent))
    }
}
