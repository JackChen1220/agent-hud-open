import SwiftUI
import AgentHUDCore

/// Reports the panel's natural height so the island window can size itself to the content.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// User-selected quota rows, token usage and active sessions.
struct HoverPanelView: View {
    let store: UsageStore
    let onOpenStats: () -> Void
    var onOpenSettings: () -> Void = {}
    var additionalHUDControls: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    /// Nil measures the natural layout; the visible panel gives its bounded height.
    var height: CGFloat? = nil
    var alert: IslandAlert? = nil
    var onOpenAlert: () -> Void = {}
    var onOpenAlertSession: () -> Void = {}
    var onOpenAlertUsage: () -> Void = {}
    var sessionNavigationFailed = false
    var onOpenListedSession: (String) -> Void = { _ in }
    var failedListedSessionID: String? = nil
    var onDecideAlert: (PermissionDecision) -> Void = { _ in }
    var waitingRequests: [PermissionRequest] = []
    /// The notch keeps its hardware clearance; a dock leaves room beside its parked logo strip instead.
    var insets = HoverPanelView.notchInsets
    static let notchInsets = EdgeInsets(top: 32, leading: 18, bottom: 14, trailing: 18)

    private let theme = Theme.island
    private let spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if height != nil {
                ScrollView(.vertical) { measuredContent }
            } else {
                measuredContent
            }
            footer
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self,
                                           value: proxy.size.height + insets.top + insets.bottom + spacing)
                })
        }
        .padding(insets)
        .frame(height: height, alignment: .top)
        .foregroundStyle(theme.text)
    }

    private var measuredContent: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let error = store.lastError {
                Text(L10n.text("刷新失败：", "Refresh failed: ") + error)
                    .font(.ui(11)).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let alert {
                IslandAlertInlineView(alert: alert, onOpen: onOpenAlert, onDecide: onDecideAlert,
                                      onOpenSession: onOpenAlertSession, onOpenUsage: onOpenAlertUsage,
                                      sessionNavigationFailed: sessionNavigationFailed,
                                      waitingRequests: waitingRequests).id(alert.id)
                    .padding(.bottom, 4)
            }
            if store.settings.settings.showIslandQuota, !store.rows.isEmpty {
                quotaBlock
            }
            if store.settings.settings.showIslandQuota {
                ForEach(store.enabledBilling) { billing in
                    APIBillingCard(billing: billing, store: store, theme: theme, compact: true)
                        .padding(.top, 8)
                        .topDivider(theme.divider)
                }
            }
            if store.settings.settings.showIslandTokens, store.isLoading || store.isIndexing || !store.consumers.isEmpty {
                TokenConsumptionChart(store: store, theme: theme, context: .island)
                    .padding(.top, 8)
                    .topDivider(theme.divider)
            }
            if store.settings.settings.showIslandSessions {
                sessionLine
            }
        }
    }

    private var quotaBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(store.rowGroups.enumerated()), id: \.element.vendor) { index, group in
                ProviderQuotaBlock(store: store, vendor: group.vendor, rows: group.rows)
                .padding(.top, index > 0 ? 8 : 0)
                .topDivider(index > 0 ? theme.divider : .clear)
            }
            if store.rows.isEmpty {
                Text(L10n.text("暂无额度数据", "No quota data yet"))
                    .font(.ui(12))
                    .foregroundStyle(theme.secondary)
            }
        }
    }

    /// What is running right now: every running session, up to `sessionRowLimit` of them, and the rest as a count.
    /// The statistics window's range never applies here — that range belongs to the session card, which answers a
    /// different question. When nothing is running, the sessions that ended most recently take the same rows.
    /// The header opens the session list; each title returns to its agent and its token count opens usage.
    private var sessionLine: some View {
        let rows = Self.sessionRows(store)
        let running = rows.running, shown = rows.shown
        return VStack(alignment: .leading, spacing: 6) {
            Button { openSessions() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("活跃会话", "Active sessions"))
                        .font(.ui(13, .semibold)).foregroundStyle(theme.text)
                    Spacer()
                    Text(running.isEmpty
                         ? L10n.text("最近结束", "Recently ended")
                         : L10n.text("\(running.count) 个运行中", "\(running.count) running"))
                        .font(.tabular(12)).foregroundStyle(theme.secondary)
                }
                .contentShape(Rectangle())
            }
            .help(L10n.text("查看会话列表", "Show sessions"))
            .accessibilityIdentifier("island-sessions")
            if shown.isEmpty {
                Text(L10n.text("还没有会话", "No sessions yet"))
                    .foregroundStyle(theme.secondary)
            } else {
                ForEach(shown) { session in
                    sessionRow(session)
                }
                if rows.more > 0 {
                    Button { openSessions() } label: {
                        Text(L10n.text("还有 \(rows.more) 个", "+\(rows.more) more"))
                            .foregroundStyle(theme.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.ui(12))
        .padding(.top, 8)
        .topDivider(theme.divider)
    }

    private func sessionRow(_ session: LiveSession) -> some View {
        let canReturn = session.navigationTarget != nil
        let failed = failedListedSessionID == session.id
        let tokens = "\(TokenFormat.short(session.tokensIn + session.tokensOut)) tok"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button { onOpenListedSession(session.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(sessionDotColor(session)).frame(width: 6, height: 6)
                        Text("\(Self.shortTask(session.task)) · \(session.terminal ?? "—")")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .disabled(!canReturn)
                .help(session.task + "\n" + (canReturn
                      ? L10n.text("返回会话", "Return to session")
                      : L10n.text("无法返回此会话", "Session return unavailable")))
                .accessibilityLabel(L10n.text("返回会话：", "Return to session: ") + session.task)
                .accessibilityHint(canReturn ? L10n.text("在 agent 中打开", "Open in the agent")
                                   : L10n.text("无法返回此会话", "Session return unavailable"))
                .accessibilityIdentifier("island-session-return-\(session.id)")

                Button { openSessions(session.id) } label: {
                    Text(tokens)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .help(L10n.text("查看此会话的用量", "View this session's token usage"))
                .accessibilityLabel(L10n.text("查看会话用量：", "View token usage: ") + session.task)
                .accessibilityValue(tokens)
                .accessibilityIdentifier("island-session-usage-\(session.id)")
            }
            .foregroundStyle(theme.secondary)
            if failed {
                Text(canReturn
                     ? L10n.text("返回失败，点击标题重试", "Couldn't return. Click the title to retry.")
                     : L10n.text("无法返回此会话", "Session return unavailable"))
                    .font(.ui(11))
                    .foregroundStyle(theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }

    /// The statistics window on its Sessions page: the list, or one session's page.
    private func openSessions(_ id: String? = nil) {
        store.focusedSessionID = id
        store.statsTab = .sessions
        onOpenStats()
    }

    /// Every running session, else the most recent ones, up to `sessionRowLimit`; and how many running sessions the rows
    /// leave out.
    static func sessionRows(_ store: UsageStore) -> (running: [LiveSession], shown: [LiveSession], more: Int) {
        let running = store.liveSessions
        let shown = Array((running.isEmpty ? store.sessions : running).prefix(sessionRowLimit))
        return (running, shown, max(0, running.count - shown.count))
    }

    /// A running session wears its agent's colour, one blocked on the user the warning colour, and an ended one grey.
    static func sessionDot(_ session: LiveSession, store: UsageStore) -> SessionDot {
        SessionDot(store.view.phase(of: session))
    }

    private func sessionDotColor(_ session: LiveSession) -> Color {
        switch Self.sessionDot(session, store: store) {
        case .waiting: return theme.status(.warning)
        case .running: return AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(session.agentId))
        case .ended: return theme.dotEnded
        }
    }

    private var footer: some View {
        HStack {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(L10n.text("设置", "Settings"))
            .accessibilityLabel(L10n.text("设置", "Settings"))
            Spacer()
            additionalHUDControls()
            Button {
                store.focusedSessionID = nil
                store.statsTab = .tokens
                onOpenStats()
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(L10n.text("用量统计", "Usage statistics"))
            .accessibilityLabel(L10n.text("用量统计", "Usage statistics"))
        }
        .buttonStyle(.plain)
        .font(.ui(14))
        .foregroundStyle(theme.secondary)
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
    }

    /// "fix auth bug in middleware" → "fix auth bug"
    /// How many session rows the island shows before the rest become a count.
    static let sessionRowLimit = 3

    static func shortTask(_ task: String) -> String {
        let words = task.split(separator: " ")
        if words.count > 3 { return words.prefix(3).joined(separator: " ") }
        return String(task.prefix(14))
    }
}
