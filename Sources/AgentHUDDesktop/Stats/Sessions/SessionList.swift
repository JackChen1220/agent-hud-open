import AppKit
import SwiftUI
import AgentHUDCore

/// How the Sessions page lists its sessions: every session of the last seven days under its day, or only those in flight
/// or active in the last day, without days.
enum SessionArrangement: Hashable {
    case day, active
}

/// The Sessions page: every session of the last seven days under the day it was last active on, a running one under
/// today, newest first, below the totals of the sessions filed under today. Today and any day with a session still
/// running are open; the other days fold to their totals until clicked. Sessions last active before the named days share
/// one Earlier group. The Active arrangement drops the days: it lists the sessions active in the last day, newest
/// activity first, below the same totals. Each session reads as it does in the phone's list.
struct SessionList: View {
    let store: UsageStore
    let theme: Theme
    let source: SessionSource?
    let activeOnly: Bool
    var project: SessionProject? = nil
    var search = ""
    /// Days the user opened or closed against how they start.
    @State private var flipped: Set<Date> = []

    var body: some View {
        let sessions = store.listedSessions(source: source, activeOnly: activeOnly, project: project, search: search)
        let calendar = Calendar.current, today = calendar.startOfDay(for: store.now)
        let filedToday = Self.filedToday(sessions, store: store, today: today, calendar: calendar)
        VStack(alignment: .leading, spacing: 0) {
            if !filedToday.isEmpty {
                SessionsTodayCard(sessions: filedToday, store: store, theme: theme).padding(.bottom, 18)
            }
            if activeOnly {
                if !sessions.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text("近 24 小时", "Last 24 hours")).font(.ui(13, .semibold)).foregroundStyle(theme.text)
                        Spacer(minLength: 8)
                        Text(L10n.text("每轮 Token", "Tokens per turn")).font(.ui(11))
                    }
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    cards(sessions)
                }
            } else {
                let groups = Self.groups(sessions, store: store, today: today, calendar: calendar)
                ForEach(Array(groups.enumerated()), id: \.element.day) { index, group in
                    let day = Self.dayState(group.day, sessions: group.sessions, today: today, store: store)
                    let open = day.opens != flipped.contains(group.day)
                    dayHeader(group.day, sessions: group.sessions, running: day.running, open: open, notesTurns: index == 0,
                              today: today, calendar: calendar)
                    if open { cards(group.sessions) }
                }
            }
            if sessions.isEmpty {
                Text(project != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? L10n.text("没有匹配的会话", "No matching sessions")
                     : activeOnly ? L10n.text("近 24 小时没有活跃的会话", "No sessions active in the last 24 hours")
                                  : L10n.text("近 7 天没有会话", "No sessions in the last 7 days"))
                    .font(.ui(12)).foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(theme)
            }
        }
    }

    /// The named days, newest first, then Earlier, keyed by the distant past, for the sessions last active before them.
    static func groups(_ sessions: [LiveSession], store: UsageStore, today: Date, calendar: Calendar) -> [(day: Date, sessions: [LiveSession])] {
        let first = calendar.date(byAdding: .day, value: -6, to: today)!
        let days = store.sessionsByDay(sessions, calendar: calendar)
        let earlier = days.filter { $0.day < first }.flatMap(\.sessions)
        return days.filter { $0.day >= first } + (earlier.isEmpty ? [] : [(day: Date.distantPast, sessions: earlier)])
    }

    /// The sessions the card above the list sums in either arrangement: today's group, the sessions last active today or
    /// in flight, whenever they began.
    static func filedToday(_ sessions: [LiveSession], store: UsageStore, today: Date, calendar: Calendar) -> [LiveSession] {
        groups(sessions, store: store, today: today, calendar: calendar).first { $0.day == today }?.sessions ?? []
    }

    /// How many of a day's sessions are running, and whether the day starts open: today does, and so does any day with a
    /// session still running.
    static func dayState(_ day: Date, sessions: [LiveSession], today: Date, store: UsageStore) -> (running: Int, opens: Bool) {
        let view = store.view
        let running = sessions.filter { view.phase(of: $0).isInFlight }.count
        return (running, day == today || running > 0)
    }

    /// Sessions in one card, each opening its page.
    private func cards(_ sessions: [LiveSession]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { position, session in
                SessionCard(session: session, store: store, theme: theme)
                    .overlay(alignment: .top) { if position > 0 { Rectangle().fill(theme.divider).frame(height: 1) } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .card(theme, padding: EdgeInsets())
        .padding(.bottom, 18)
    }

    /// The day's name and count, and while it is folded what its sessions spent; a click folds or opens it.
    private func dayHeader(_ day: Date, sessions: [LiveSession], running: Int, open: Bool, notesTurns: Bool, today: Date,
                           calendar: Calendar) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { flipped.formSymmetricDifference([day]) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Text(Self.title(day, today: today, calendar: calendar)).font(.ui(13, .semibold)).foregroundStyle(theme.text)
                Text("\(sessions.count)").font(.tabular(11))
                if running > 0 {
                    Text(L10n.text("\(running) 个运行中", "\(running) running")).font(.ui(11)).foregroundStyle(theme.status(.ok))
                }
                Spacer(minLength: 8)
                if !open {
                    if let costs = SessionsTodayCard.costs(sessions, store: store) {
                        Text(costs).font(.tabular(11))
                    }
                    let tokens = sessions.reduce(0) { $0 + store.sessionTokens($1).total }
                    Text(tokens > 0 ? TokenFormat.short(tokens) : "—")
                        .font(.tabular(11, .semibold)).foregroundStyle(theme.text)
                        .frame(minWidth: 44, alignment: .trailing)
                } else if notesTurns {
                    Text(L10n.text("每轮 Token", "Tokens per turn")).font(.ui(11))
                }
            }
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, open ? 0 : 9)
            .background {
                if !open {
                    RoundedRectangle(cornerRadius: 10).fill(theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, open ? 6 : 8)
        .accessibilityLabel(Self.title(day, today: today, calendar: calendar))
        .accessibilityValue(open ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
    }

    /// Today, yesterday, then the weekday and date; Earlier for the sessions last active before the named days.
    static func title(_ day: Date, today: Date, calendar: Calendar) -> String {
        if day == today { return L10n.text("今天", "Today") }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return L10n.text("昨天", "Yesterday") }
        if day == .distantPast { return L10n.text("更早", "Earlier") }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day()
            .locale(L10n.dateLocale))
    }
}

/// The sessions filed under today in one card: how many, what they cost, and every token they and their sub-agents spent
/// by kind, a session begun on an earlier day with its whole totals.
struct SessionsTodayCard: View {
    let sessions: [LiveSession]
    let store: UsageStore
    let theme: Theme

    var body: some View {
        let kinds = sessions.reduce(TokenKinds()) { $0 + store.sessionTokens($1) }
        let present = TokenKind.allCases.filter { kinds[$0] > 0 }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("今天 · \(sessions.count) 个会话", sessions.count == 1 ? "Today · 1 session" : "Today · \(sessions.count) sessions"))
                    .font(.ui(13, .semibold))
                Spacer(minLength: 8)
                if let costs {
                    Text(L10n.text("费用 ", "Cost ")).font(.ui(11)).foregroundStyle(theme.secondary)
                        + Text(costs).font(.tabular(12, .semibold))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TokenFormat.short(kinds.total)).font(.tabular(24, .semibold))
                Text(L10n.text("Token", "tokens")).font(.ui(12)).foregroundStyle(theme.secondary)
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            GeometryReader { proxy in
                let gaps = CGFloat(max(0, present.count - 1)) * 1.5
                HStack(spacing: 1.5) {
                    ForEach(present, id: \.self) { kind in
                        Rectangle().fill(theme.kind(kind))
                            .frame(width: max(1, (proxy.size.width - gaps) * CGFloat(kinds[kind]) / CGFloat(max(1, kinds.total))))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(.bottom, 10)
            // One row when the kinds fit side by side, else a grid.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    ForEach(present, id: \.self) { legend($0, kinds) }
                    Spacer(minLength: 0)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(present, id: \.self) { legend($0, kinds) }
                }
            }
        }
        .card(theme, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    private func legend(_ kind: TokenKind, _ kinds: TokenKinds) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(theme.kind(kind)).frame(width: 7, height: 7)
            Text(kind.label).foregroundStyle(theme.secondary)
            Text(TokenFormat.short(kinds[kind])).font(.tabular(11))
        }
        .font(.ui(11))
        .fixedSize()
        .help("\(kind.label) \(kinds[kind].formatted())")
    }

    private var costs: String? { Self.costs(sessions, store: store) }

    /// Priced accounts' estimates and, for the rest, what their calls would cost at API list prices, added up per currency.
    static func costs(_ sessions: [LiveSession], store: UsageStore) -> String? {
        var sums: [String: Decimal] = [:]
        for session in sessions {
            switch store.sessionMoney(session) {
            case .account(let amount, let currency)?: sums[currency, default: 0] += amount
            case .listPrice(let amount)?: sums["USD", default: 0] += amount
            case .accountUnknown?, nil: break
            }
        }
        guard !sums.isEmpty else { return nil }
        return sums.keys.sorted().map { "≈" + MoneyFormat.amount(sums[$0]!, currency: $0) }.joined(separator: " · ")
    }
}

/// The dot a session wears in the island, on its card and on its page: blocked on the user, running, or neither.
enum SessionDot: Equatable {
    case waiting, running, ended

    init(_ phase: SessionPhase) {
        switch phase.state {
        case .waitingForApproval: self = .waiting
        case .running: self = .running
        case .idle, .unverified: self = .ended
        }
    }
}

/// One session as the phone lists it: its state, title and tokens with sub-agents'; model, project and cost; each recent
/// turn's new tokens; its state, turns and how long the turn has run or how long ago it was active, and how full its
/// context is. A click opens its page.
struct SessionCard: View {
    let session: LiveSession
    let store: UsageStore
    let theme: Theme
    @State private var hovered = false

    var body: some View {
        let usage = store.sessionUsage(session), tokens = store.sessionTokens(session)
        let kind = Self.dot(session, store: store)
        let waiting = kind == .waiting, running = kind == .running
        let dot = waiting ? theme.status(.warning) : running ? theme.status(.ok) : theme.dotEnded
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .background(Circle().fill(dot.opacity(running ? 0.22 : 0)).frame(width: 13, height: 13))
                Text(session.task).font(.ui(13, .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(tokens.total > 0 ? TokenFormat.short(tokens.total) : "—")
                    .font(.tabular(13, .semibold))
                    .help(TokenKind.allCases.map { "\($0.label) \(tokens[$0].formatted())" }.joined(separator: " · "))
            }
            HStack(spacing: 8) {
                Text(place).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let cost { Text(cost).font(.tabular(11)) }
            }
            .font(.ui(11))
            .foregroundStyle(theme.secondary)
            .padding(.leading, 15)
            if let usage {
                TurnSparkline(usage: usage, theme: theme).frame(height: 22).padding(.leading, 15).padding(.top, 2)
            }
            HStack(spacing: 8) {
                Text(status(usage, dot: kind)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if let usage, let context = usage.contextTokens {
                    Text(L10n.text("上下文", "Context"))
                    if let fill = usage.contextFill {
                        Capsule().fill(theme.track).frame(width: 36, height: 4).overlay(alignment: .leading) {
                            Capsule().fill(fill >= 0.8 ? theme.status(.warning) : theme.secondary).frame(width: 36 * min(1, fill), height: 4)
                        }
                        Text(TokenFormat.percent(fill * 100)).font(.tabular(11)).foregroundStyle(theme.text)
                            .frame(minWidth: 30, alignment: .trailing)
                    } else {
                        Text(TokenFormat.short(context)).font(.tabular(11)).foregroundStyle(theme.text)
                    }
                }
            }
            .font(.ui(11))
            .foregroundStyle(theme.secondary)
            .padding(.leading, 15)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 9, trailing: 14))
        .background(hovered ? theme.sessionRowBackground : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.focusedSessionID = session.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.focusedSessionID = session.id }
        .help([session.task, store.sessionSource(session).name, session.displayPath].compactMap { $0 }.joined(separator: " · "))
        .contextMenu {
            if let path = session.transcriptPath {
                Button(L10n.text("在 Finder 中显示日志", "Reveal log in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }

    /// The model and the project, else the client; an account-wide session says so.
    private var place: String {
        ([store.consumerName(session.agentId), (session.accountWide ? nil : session.displayPath) ?? store.sessionSource(session).name]
            + (session.accountWide ? [L10n.text("账户 · 跨设备", "Account · across devices")] : [])).joined(separator: " · ")
    }

    /// A priced account's estimate, else what the calls would cost at API list prices.
    private var cost: String? {
        guard let money = store.sessionMoney(session) else { return nil }
        if case .accountUnknown = money { return nil }
        return money.text
    }

    /// The state as the phone is told it, the turns, and how long the turn in flight has run or how long ago the session
    /// was last active.
    private func status(_ usage: SessionUsage?, dot: SessionDot) -> String {
        let turns = usage.flatMap { $0.turnCount > 0 ? L10n.text("\($0.turnCount) 轮", $0.turnCount == 1 ? "1 turn" : "\($0.turnCount) turns") : nil }
        let interval = store.now.timeIntervalSince(Self.elapsedStart(session, store: store))
        let elapsed = dot == .ended ? Countdown.age(interval) : Countdown.format(interval)
        return [Self.state(session, dot: dot, store: store), turns, elapsed].compactMap { $0 }.joined(separator: " · ")
    }

    /// Blocked on the user, else running, else neither.
    static func dot(_ session: LiveSession, store: UsageStore) -> SessionDot {
        SessionDot(store.view.phase(of: session))
    }

    /// The state, as the session's page words it. Without live status there is no state.
    static func state(_ session: LiveSession, dot: SessionDot, store: UsageStore) -> String? {
        switch dot {
        case .waiting: return L10n.text("等待批准", "Needs approval")
        case .running: return L10n.text("运行中", "Running")
        case .ended:
            let shown = store.view.session(for: session)
            guard shown.liveStatus else { return nil }
            // In flight by a reading too old for the Mac to vouch for, the session's state is not known.
            return shown.phase.state == .unverified ? L10n.text("状态待更新", "Status out of date") : L10n.text("等你回复", "Waiting for you")
        }
    }

    /// What the elapsed time counts from: the start of the work in flight, else the session's last event.
    static func elapsedStart(_ session: LiveSession, store: UsageStore) -> Date {
        store.view.phase(of: session).since
    }
}

/// Each recent turn's new tokens as a small stacked bar, or each period's for a log that marks no prompts.
struct TurnSparkline: View {
    let usage: SessionUsage
    let theme: Theme
    /// Enough turns to keep each bar a few points wide.
    static let limit = 64

    var body: some View {
        let bars = Array((usage.turns.isEmpty ? SessionBar.periods(usage) : SessionBar.turns(usage)).suffix(Self.limit))
        let peak = max(1, bars.map(\.kinds.new).max() ?? 0)
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            // At least a dozen slots, and on a wide card as many as keep a bar about as wide as on the phone.
            let slot = size.width / CGFloat(max(bars.count, 12, Int(size.width / 28)))
            let width = max(slot - 2, 2), scale = (size.height - 1) / CGFloat(peak)
            for (index, bar) in bars.enumerated() where bar.kinds.new > 0 {
                // A turn that added almost nothing still shows as a stub.
                let barScale = max(scale, 1.5 / CGFloat(bar.kinds.new))
                var y = size.height
                for kind in SessionBarsChart.stacked where bar.kinds[kind] > 0 {
                    let height = CGFloat(bar.kinds[kind]) * barScale
                    y -= height
                    context.fill(Path(CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: y + 0.4, width: width, height: max(0.6, height - 0.8))),
                                 with: .color(theme.kind(kind)))
                }
            }
            context.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)), with: .color(theme.divider))
        }
        .accessibilityHidden(true)
    }
}

/// A session's recorded directory, shared across clients, or an unknown directory. A folder name alone is not a path.
enum SessionProject: Hashable {
    case directory(String)
    case unassigned

    init(_ session: LiveSession) {
        if let path = session.workingDirectory, !path.isEmpty { self = .directory(path) }
        else { self = .unassigned }
    }

    var label: String {
        switch self {
        case .directory(let path): (path as NSString).abbreviatingWithTildeInPath
        case .unassigned: L10n.text("未归属项目", "Unassigned project")
        }
    }
}

extension UsageStore {
    /// The list's sessions, from one source or all: the last seven days', or with `activeOnly`, the Active arrangement,
    /// those running or active in the last day. Newest activity first.
    func listedSessions(source: SessionSource?, activeOnly: Bool, project: SessionProject? = nil, search: String = "") -> [LiveSession] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = statsSessions.filter { session in
            guard source == nil || sessionSource(session) == source,
                  project == nil || SessionProject(session) == project else { return false }
            guard !query.isEmpty else { return true }
            return [session.task, session.workingDirectory, session.displayPath, SessionProject(session).label,
                    sessionSource(session).name, consumerName(session.agentId)]
                .compactMap { $0 }.contains { $0.localizedStandardContains(query) }
        }
        guard activeOnly else { return sessions }
        let view = self.view, since = now.addingTimeInterval(-86_400)
        return sessions.filter {
            let shown = view.session(for: $0)
            return shown.phase.isInFlight || shown.lastEventAt >= since
        }
    }
}
