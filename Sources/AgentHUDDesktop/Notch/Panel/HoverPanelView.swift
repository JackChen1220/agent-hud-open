import SwiftUI
import AgentHUDCore

/// Reports the panel's natural height so the island window can size itself to the content.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// The selected quota rows and a compact token chart, then the local session summary.
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

    /// The row whose questions are open for answering here rather than in the agent.
    var answeringSessionID: String? = nil
    var onAnswerSession: (String?) -> Void = { _ in }

    var repositories: RepositoryStore? = nil
    var navigation: HubNavigation? = nil
    var isPinned = false
    var onTogglePin: () -> Void = {}
    var observesRepositories = true
    var maximumPanelHeight: CGFloat = 700
    var onOpenRepositories: () -> Void = {}

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
            if let alert, !alert.isSessionEvent {
                IslandAlertInlineView(alert: alert, onOpen: onOpenAlert, onDecide: onDecideAlert,
                                      onOpenSession: onOpenAlertSession, onOpenUsage: onOpenAlertUsage,
                                      sessionNavigationFailed: sessionNavigationFailed,
                                      waitingRequests: waitingRequests).id(alert.id)
                    .padding(.bottom, 4)
            }
            if navigation?.tab == .branches, let repositories {
                BranchPanelView(store: repositories, onManage: onOpenRepositories,
                                observesChanges: observesRepositories,
                                listHeight: max(80, min(285, maximumPanelHeight - 235)))
            } else {
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
                    TokenConsumptionChart(store: store, theme: theme, context: .island, compact: true, onOpenStats: onOpenStats)
                        .padding(.top, 8)
                        .topDivider(theme.divider)
                }
                if store.settings.settings.showIslandSessions {
                    sessionLine
                }
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

    /// What is waiting, running and recently ended: the sessions with work in flight first — those waiting for the
    /// user ahead of those still running — then those last active in the past day, up to five rows in total. The
    /// remaining count includes every other session in that summary. The statistics window's range never applies here — that
    /// range belongs to the session card, which answers a different question. The header opens the session list; each
    /// row's title returns to its agent, or opens its session page where the client names no destination, and its
    /// token count opens usage.
    private var sessionLine: some View {
        let rows = Self.sessionRows(store)
        let running = rows.running, shown = rows.shown
        let hasAbove = store.lastError != nil || alert.map { !$0.isSessionEvent } == true
            || (store.settings.settings.showIslandQuota && (!store.rows.isEmpty || !store.enabledBilling.isEmpty))
            || (store.settings.settings.showIslandTokens && (store.isLoading || store.isIndexing || !store.consumers.isEmpty))
        return VStack(alignment: .leading, spacing: 6) {
            Button { openSessions() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("会话", "Sessions"))
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
        .padding(.top, hasAbove ? 8 : 0)
        .topDivider(hasAbove ? theme.divider : .clear)
    }

    private func sessionRow(_ session: LiveSession) -> some View {
        let asks = Self.questionRequests(for: session, waiting: waitingRequests)
        let expanded = answeringSessionID == session.id && !asks.isEmpty
        let failed = failedListedSessionID == session.id
        let tokens = "\(TokenFormat.short(session.tokensIn + session.tokensOut)) tok"
        let dot = Self.sessionDot(session, store: store)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { open(session) } label: {
                    HStack(spacing: 8) {
                        sessionMark(session, dot: dot)
                        Text(Self.sessionTitle(session))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .help(session.task + "\n" + (session.navigationTarget != nil
                      ? L10n.text("返回会话", "Return to session")
                      : L10n.text("查看会话详情", "Show session details")))
                .accessibilityLabel(L10n.text("打开会话：", "Open session: ") + session.task)
                .accessibilityHint(session.navigationTarget != nil
                                   ? L10n.text("在 agent 中打开", "Open in the agent")
                                   : L10n.text("打开此会话的详情页", "Open this session's detail page"))
                .accessibilityIdentifier("island-session-return-\(session.id)")

                if !asks.isEmpty {
                    questionBadge(asks, session: session, expanded: expanded)
                }

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
                Text(session.navigationTarget != nil
                     ? L10n.text("返回失败，点击标题重试", "Couldn't return. Click the title to retry.")
                     : L10n.text("无法返回此会话", "Session return unavailable"))
                    .font(.ui(11))
                    .foregroundStyle(theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
            if expanded {
                questionAnswer(asks, session: session)
            }
        }
    }

    /// Back to the agent where its client names a destination; where none exists, the session's own page, so a row
    /// always leads to that conversation rather than nowhere.
    private func open(_ session: LiveSession) {
        if session.navigationTarget != nil { onOpenListedSession(session.id) } else { openSessions(session.id) }
    }

    /// The agent's mark with the session's state on its corner: its own colour while it runs, the warning colour
    /// while it waits for the user, grey once it ends. A source without a bundled mark falls back to the dot alone.
    private func sessionMark(_ session: LiveSession, dot: SessionDot) -> some View {
        let color = dotColor(dot, session: session)
        guard let vendor = store.sessionSource(session).agentVendor, !vendor.isEmpty else {
            return AnyView(Circle().fill(color).frame(width: 6, height: 6))
        }
        return AnyView(
            ZStack(alignment: .bottomTrailing) {
                AgentLogo(vendor: vendor, size: 14)
                Circle().fill(color)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(theme.windowBackground, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .frame(width: 14, height: 14)
            .opacity(dot == .ended ? 0.7 : 1)
        )
    }

    /// How many questions this session waits on, and where answering them opens.
    private func questionBadge(_ asks: [PermissionRequest], session: LiveSession, expanded: Bool) -> some View {
        Button {
            onAnswerSession(expanded ? nil : session.id)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 9, weight: .semibold))
                if asks.count > 1 {
                    Text("\(asks.count)").font(.tabular(9, .semibold))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.status(.warning).opacity(0.16)))
            .foregroundStyle(theme.status(.warning))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.text("有 \(asks.count) 个提问待回答，点击在此展开",
                        "\(asks.count) questions waiting for an answer — click to answer here"))
        .accessibilityLabel(L10n.text("待回答的提问：", "Questions waiting: ") + session.task)
        .accessibilityValue(L10n.text("\(asks.count) 个", "\(asks.count)"))
        .accessibilityIdentifier("island-session-question-\(session.id)")
        .accessibilityAddTraits(expanded ? [.isSelected] : [])
    }

    /// The questions themselves, answered right here the way the island's own card answers them, beside the way
    /// back to the agent for answering them there instead.
    private func questionAnswer(_ asks: [PermissionRequest], session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(asks) { request in
                PermissionQuestionCard(request: request) { decision in
                    if case .answer = decision { onAnswerSession(nil) }
                    PermissionRequests.shared.resolve(request.id, decision)
                }
            }
            HStack(spacing: 6) {
                Button {
                    onAnswerSession(nil)
                    open(session)
                } label: {
                    HStack(spacing: 4) {
                        Text(session.navigationTarget != nil
                             ? L10n.text("在 Agent 中回答", "Answer in the agent")
                             : L10n.text("查看会话", "View session"))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                }
                Spacer(minLength: 8)
                Button { onAnswerSession(nil) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                        Text(L10n.text("收起", "Hide"))
                    }
                }
            }
            .font(.ui(11, .medium))
            .foregroundStyle(theme.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.text.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder))
        .padding(.leading, 14)
        .accessibilityIdentifier("island-session-question-card-\(session.id)")
    }

    /// The statistics window on its Sessions page: the list, or one session's page.
    private func openSessions(_ id: String? = nil) {
        store.focusedSessionID = id
        store.statsTab = .sessions
        onOpenStats()
    }

    /// The island's summary: local work in flight and sessions last active in the past day, with waiting before
    /// running, newest created first, then the most recently ended. The full session list holds any hidden rows.
    static func sessionRows(_ store: UsageStore) -> (running: [LiveSession], shown: [LiveSession], more: Int) {
        // Account-wide API receipts belong to statistics, not this Mac's local activity summary.
        let view = store.view, cutoff = view.now.addingTimeInterval(-sessionRecency)
        let candidates = view.sessions.filter {
            !$0.session.accountWide && ($0.phase.isInFlight || $0.lastEventAt >= cutoff)
        }
        let active = candidates.filter(\.phase.isInFlight).sorted {
            let lhsWaiting = $0.phase.state == .waitingForApproval
            let rhsWaiting = $1.phase.state == .waitingForApproval
            if lhsWaiting != rhsWaiting { return lhsWaiting }
            return $0.session.startedAt > $1.session.startedAt
        }
        // ReportView already orders by the last event, so ended rows reflect recent work rather than creation.
        let ended = candidates.filter { !$0.phase.isInFlight }
        let summary = active + ended
        let shown = summary.prefix(sessionRowLimit).map(\.session)
        return (active.map(\.session), shown, summary.count - shown.count)
    }

    /// The questions this session is waiting on: only a question put to this exact session reaches its row.
    static func questionRequests(for session: LiveSession, waiting: [PermissionRequest]) -> [PermissionRequest] {
        waiting.filter { $0.sessionID == session.id && $0.isQuestion }
    }

    /// A running session wears its agent's colour, one blocked on the user the warning colour, and an ended one grey.
    static func sessionDot(_ session: LiveSession, store: UsageStore) -> SessionDot {
        SessionDot(store.view.phase(of: session))
    }

    private func dotColor(_ dot: SessionDot, session: LiveSession) -> Color {
        switch dot {
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
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.ui(13, .medium))
                    .foregroundStyle(isPinned ? theme.text : theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isPinned ? theme.text.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
            }
            .help(isPinned ? L10n.text("取消固定，鼠标移出后收起", "Unpin; collapse when the pointer leaves") : L10n.text("固定面板，鼠标移出后保持展开", "Pin; keep open when the pointer leaves"))
            .accessibilityLabel(L10n.text("固定面板", "Pin panel"))
            .accessibilityValue(isPinned ? L10n.text("已固定", "Pinned") : L10n.text("未固定", "Unpinned"))
            .accessibilityIdentifier("hub-pin")
            Spacer()
            if let navigation {
                HStack(spacing: 4) {
                    ForEach(HubTab.allCases, id: \.self) { tab in
                        Button { navigation.tab = tab } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tab.symbol)
                                    .renderingMode(.template)
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundColor(navigation.tab == tab ? theme.text : theme.secondary)
                                Text(tab.title)
                            }
                                .font(.ui(12, .medium))
                                .padding(.horizontal, 16)
                                .frame(minWidth: 104, minHeight: 40)
                                .foregroundStyle(navigation.tab == tab ? theme.text : theme.secondary)
                                .background(RoundedRectangle(cornerRadius: 8).fill(navigation.tab == tab ? theme.text.opacity(0.12) : .clear))
                                // Plain buttons must include the icon gaps and transparent padding in hit testing.
                                .contentShape(Rectangle())
                        }.accessibilityAddTraits(navigation.tab == tab ? .isSelected : [])
                        .accessibilityIdentifier(tab == .agents ? "hub-tab-agents" : "hub-tab-branches")
                    }
                }
            }
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

    static let sessionRowLimit = 5
    static let sessionRecency: TimeInterval = 24 * 3600

    static func sessionTitle(_ session: LiveSession) -> String {
        guard let terminal = session.terminal, !terminal.isEmpty else { return session.task }
        return "\(shortTask(session.task)) · \(terminal)"
    }

    /// "fix auth bug in middleware" → "fix auth bug"
    static func shortTask(_ task: String) -> String {
        let words = task.split(separator: " ")
        if words.count > 3 { return words.prefix(3).joined(separator: " ") }
        return String(task.prefix(14))
    }
}
