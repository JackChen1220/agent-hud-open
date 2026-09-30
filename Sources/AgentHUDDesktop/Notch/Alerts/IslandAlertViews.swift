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
                        CompletionSymbol(eventID: event.id)
                        Text(L10n.text("已完成", "Completed")).font(.ui(12, .medium))
                    }.frame(width: IslandController.alertWingWidth, alignment: .trailing)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, IslandController.alertSidePadding).frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("island-alert-sessionCompleted")
            .accessibilityLabel("\(event.vendor) · \(L10n.text("本轮已完成", "Turn completed")) · \(event.task)")
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
                    CompletionSymbol(eventID: event.id)
                    Text(L10n.text("本轮已完成", "Turn completed"))
                        .font(.ui(11)).foregroundStyle(Color(IslandAlert.calmAccent))
                }
                Text(event.task).font(.ui(15, .medium)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(event.completedAt.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    if let start = event.startedAt {
                        Text(Countdown.compact(max(0, event.completedAt.timeIntervalSince(start))))
                    }
                }.font(.tabular(11)).foregroundStyle(.white.opacity(0.5))
                Button(action: onOpen) {
                    Text(L10n.text("查看会话记录", "View sessions"))
                        .font(.ui(12, .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Color(IslandAlert.calmAccent), in: RoundedRectangle(cornerRadius: 7))
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
                    CompletionSymbol(eventID: event.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("\(event.vendor) 本轮已完成", "\(event.vendor) turn completed"))
                            .font(.ui(12, .medium))
                        Text(event.task).font(.ui(10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.ui(10))
                }.foregroundStyle(.white).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

private struct CompletionSymbol: View {
    let eventID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTrigger = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(IslandAlert.calmAccent))
            .symbolEffect(.bounce.byLayer, options: .nonRepeating, value: animationTrigger)
            .symbolEffectsRemoved(reduceMotion)
            .task(id: eventID) {
                guard !reduceMotion else { return }
                // Let the island unfold before drawing attention to the completion mark.
                do { try await Task.sleep(for: .seconds(IslandAnimation.duration)) } catch { return }
                guard !reduceMotion else { return }
                animationTrigger += 1
            }
    }
}
