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
            .accessibilityHint(L10n.text("展开会话与 Token 用量操作", "Show session and token usage actions"))
        }
    }
}

struct IslandAlertDetailView: View {
    let alert: IslandAlert
    let onOpen: () -> Void
    let onDecide: (PermissionDecision) -> Void
    var onOpenSession: () -> Void = {}
    var onOpenUsage: () -> Void = {}
    var sessionNavigationFailed = false
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
                CompletionAlertActions(hasSession: event.navigationTarget != nil,
                                       navigationFailed: sessionNavigationFailed,
                                       onOpenSession: onOpenSession, onOpenUsage: onOpenUsage)
            }.foregroundStyle(.white)
        }
    }
}

/// Session events share one panel: the selected card is open and the other events remain selectable rows.
struct IslandEventPanelView: View {
    let alert: IslandAlert
    let onOpen: () -> Void
    let onDecide: (PermissionDecision) -> Void
    var onOpenSession: () -> Void = {}
    var onOpenUsage: () -> Void = {}
    var sessionNavigationFailed = false
    var events: [IslandAlert] = []
    var waitingRequests: [PermissionRequest] = []
    var onSelectRequest: (String) -> Void = { _ in }

    private var requests: [PermissionRequest] {
        if !waitingRequests.isEmpty { return waitingRequests }
        var values = events.compactMap { event -> PermissionRequest? in
            guard case .permission(let request) = event else { return nil }
            return request
        }
        if case .permission(let request) = alert, !values.contains(where: { $0.id == request.id }) {
            values.insert(request, at: 0)
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private var replies: [SessionCompletion] {
        events.compactMap { event in
            guard case .completion(let reply) = event, reply.id != alert.id else { return nil }
            return reply
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IslandAlertDetailView(alert: alert, onOpen: onOpen, onDecide: onDecide,
                                  onOpenSession: onOpenSession, onOpenUsage: onOpenUsage,
                                  sessionNavigationFailed: sessionNavigationFailed,
                                  waitingRequests: requests, onSelectRequest: onSelectRequest)
                .accessibilityIdentifier("island-event-selected-\(alert.id)")

            if case .completion = alert, !requests.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(L10n.text("待审批", "Waiting"))
                            .font(.ui(11, .semibold)).foregroundStyle(PermissionColor.secondary)
                        Spacer()
                        Text("\(requests.count)")
                            .font(.tabular(10, .semibold)).foregroundStyle(PermissionColor.signal)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PermissionColor.signal.opacity(0.16), in: Capsule())
                    }.padding(.horizontal, 4).padding(.bottom, 8)
                    VStack(spacing: 2) {
                        ForEach(requests) { request in
                            PermissionClosedRow(request: request, onSelect: { onSelectRequest(request.id) })
                                .accessibilityIdentifier("island-event-permission-\(request.id)")
                                .help(L10n.text("展开请求详情", "Show request details"))
                        }
                    }
                }
            }

            if !replies.isEmpty {
                VStack(spacing: 2) {
                    ForEach(replies) { reply in
                        CompletionClosedRow(event: reply, onSelect: { onSelectRequest(reply.id) })
                    }
                }
            }
        }
        .foregroundStyle(Theme.island.text)
        .accessibilityIdentifier("island-event-panel")
    }
}

private struct CompletionClosedRow: View {
    let event: SessionCompletion
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                AgentLogo(vendor: event.vendor, size: 13).opacity(0.8)
                Text(event.vendor).font(.ui(12, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 3) {
                    Image(systemName: "text.bubble").font(.system(size: 8, weight: .bold))
                    Text(L10n.text("有新回复", "New reply")).font(.ui(10, .bold))
                }
                .foregroundStyle(Color(IslandAlert.turnAccent))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color(IslandAlert.turnAccent).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                Text(event.task).font(.ui(11)).foregroundStyle(Theme.island.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(event.completedAt.formatted(date: .omitted, time: .shortened))
                    .font(.tabular(11)).foregroundStyle(Theme.island.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.island.segmentBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("island-event-reply-\(event.id)")
        .accessibilityLabel(L10n.text("打开 \(event.vendor) 的回复：\(event.task)",
                                      "Open \(event.vendor) reply: \(event.task)"))
        .help(L10n.text("展开回复与会话操作", "Show reply and session actions"))
    }
}

struct IslandAlertInlineView: View {
    let alert: IslandAlert
    let onOpen: () -> Void
    let onDecide: (PermissionDecision) -> Void
    var onOpenSession: () -> Void = {}
    var onOpenUsage: () -> Void = {}
    var sessionNavigationFailed = false
    var waitingRequests: [PermissionRequest] = []
    var body: some View {
        switch alert {
        case .permission(let request): PermissionAlertInlineView(request: request, onDecide: onDecide,
                                                                 waiting: max(1, waitingRequests.count))
        case .quota(let event): QuotaAlertInlineView(alert: event, onOpen: onOpen)
        case .resetCredits(let event): ResetCreditAlertInlineView(grant: event, onOpen: onOpen)
        case .completion(let event):
            VStack(alignment: .leading, spacing: 10) {
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
                }
                CompletionAlertActions(hasSession: event.navigationTarget != nil,
                                       navigationFailed: sessionNavigationFailed,
                                       onOpenSession: onOpenSession, onOpenUsage: onOpenUsage)
            }.foregroundStyle(.white).padding(.vertical, 8)
        }
    }
}

/// The same destinations in the standalone reply card and the usage panel's inline reminder.
private struct CompletionAlertActions: View {
    let hasSession: Bool
    let navigationFailed: Bool
    let onOpenSession: () -> Void
    let onOpenUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if navigationFailed && hasSession {
                Text(L10n.text("无法回到会话，请重试或查看 Token 用量", "Couldn't return to session. Retry or view token usage."))
                    .font(.ui(10)).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasSession {
                Text(L10n.text("暂时无法回到原会话", "Session return unavailable"))
                    .font(.ui(10)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 6) {
                Button(action: onOpenUsage) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.island.secondary)
                        Text(L10n.text("查看 Token 用量", "View token usage"))
                            .font(.ui(11, .medium)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.island.secondary)
                    .padding(.horizontal, 9).frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.island.cardBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("island-alert-openTokenUsage")
                Spacer(minLength: 8)
                if hasSession {
                    Button(action: onOpenSession) {
                        HStack(spacing: 4) {
                            Image(systemName: navigationFailed ? "arrow.clockwise" : "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                            Text(navigationFailed ? L10n.text("重试会话跳转", "Retry session")
                                 : L10n.text("回到会话", "Return to session"))
                                .font(.ui(11, .medium)).lineLimit(1)
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Color(IslandAlert.turnAccent), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("island-alert-openSession")
                }
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
