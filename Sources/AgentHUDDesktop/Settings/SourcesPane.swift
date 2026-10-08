import SwiftUI
import UniformTypeIdentifiers
import AgentHUDCore

struct SourcesPane: View {
    let settings: SettingsStore
    let store: UsageStore
    let theme: Theme
    var sources: [SourceStatus]? = nil
    @State private var selectedProviderID: String?
    @State private var dragging: AgentOrderDrag?

    init(settings: SettingsStore, store: UsageStore, theme: Theme, sources: [SourceStatus]? = nil,
         initialProviderID: String? = nil) {
        self.settings = settings; self.store = store; self.theme = theme; self.sources = sources
        _selectedProviderID = State(initialValue: initialProviderID)
    }

    var body: some View {
        let detected = sources ?? SourceDetector.resolve(SourceDetector.detect(), report: store.report)
        let groups = AgentSettingsGroup.make(sources: detected, agents: settings.agents, report: store.report)
        let selected = groups.first { $0.id == selectedProviderID } ?? groups.first
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(groups) { group in
                            AgentProviderRow(group: group, settings: settings, theme: theme,
                                selected: group.id == selected?.id, dragging: $dragging) {
                                selectedProviderID = group.id
                            }
                        }
                    }
                    .padding(6)
                }
                .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder.opacity(0.55), lineWidth: 1))
                Text(L10n.text("拖动分组或窗口，调整光晕和面板中的顺序。", "Drag groups or windows to reorder the glow and panel."))
                    .font(.ui(11)).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            .frame(width: 152)
            .padding(.bottom, 20)
            if let selected {
                ScrollView {
                    AgentProviderDetail(group: selected, settings: settings, report: store.report, theme: theme,
                                        accountLabel: { store.accountLabel(for: $0) }, dragging: $dragging)
                        .padding(.trailing, 8)
                        .padding(.bottom, 32)
                }
                .id(selected.id)
                .accessibilityIdentifier("provider-detail-\(selected.id)")
            } else {
                Text(L10n.text("尚未检测到智能体", "No agents detected yet"))
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: groups.map(\.id), initial: true) { _, ids in
            if selectedProviderID.map({ ids.contains($0) }) != true { selectedProviderID = ids.first }
        }
    }
}

/// Provider ordering stays separate from its settings, so a long account or window list never moves another provider.
private struct AgentProviderRow: View {
    let group: AgentSettingsGroup
    let settings: SettingsStore
    let theme: Theme
    let selected: Bool
    @Binding var dragging: AgentOrderDrag?
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if !group.agents.isEmpty {
                OrderDragHandle(theme: theme)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onDrag {
                        dragging = .group(group.id)
                        return NSItemProvider(object: group.id as NSString)
                    }
                    .help(L10n.text("拖动以调整分组顺序", "Drag to reorder this group"))
            } else {
                Color.clear.frame(width: 16)
            }
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    AgentLogo(vendor: group.id, size: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(VendorCatalog.name(group.id)).font(.ui(12, selected ? .semibold : .regular))
                            .lineLimit(2)
                        if !group.agents.isEmpty {
                            Text(L10n.text("显示 \(group.displayedCount(settings: settings.settings))/\(group.agents.count)",
                                           "Showing \(group.displayedCount(settings: settings.settings))/\(group.agents.count)"))
                                .font(.tabular(10)).foregroundStyle(theme.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .accessibilityIdentifier("agent-group-\(group.id)")
            .accessibilityLabel(VendorCatalog.name(group.id))
            .accessibilityValue(selected ? L10n.text("已选中", "Selected") : L10n.text("未选中", "Not selected"))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(target: .group(group.id), dragging: $dragging, settings: settings))
    }
}

/// Each section owns one kind of preference and grows independently as a provider gains more settings.
private struct AgentProviderDetail: View {
    let group: AgentSettingsGroup
    let settings: SettingsStore
    let report: UsageReport?
    let theme: Theme
    /// Whether an account is current or when it was last read, as its header in the panel says.
    let accountLabel: @MainActor (AccountObservation) -> String
    @Binding var dragging: AgentOrderDrag?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if !group.accounts.isEmpty || !group.billingAccounts.isEmpty || !group.unobservedAccounts.isEmpty {
                SettingsSection(title: L10n.text("账户", "Accounts"),
                                subtitle: L10n.text("显隐不影响历史会话和 Token 统计。", "Visibility leaves session history and token usage intact."),
                                theme: theme) {
                    ForEach(group.accounts) { account in
                        AccountSummary(account: account, label: accountLabel(account), settings: settings, theme: theme)
                        if account.id != group.accounts.last?.id || !balanceAccounts.isEmpty || !group.unobservedAccounts.isEmpty {
                            SettingsDivider(theme: theme)
                        }
                    }
                    ForEach(balanceAccounts) { billing in
                        AccountVisibilitySummary(id: billing.id, name: billing.displayName, detail: billing.billingPool?.label,
                                                 settings: settings, theme: theme)
                        if billing.id != balanceAccounts.last?.id || !group.unobservedAccounts.isEmpty {
                            SettingsDivider(theme: theme)
                        }
                    }
                    ForEach(group.unobservedAccounts) { account in
                        AccountVisibilitySummary(id: account.id, name: account.displayName, detail: account.detail,
                                                 settings: settings, theme: theme)
                        if account.id != group.unobservedAccounts.last?.id { SettingsDivider(theme: theme) }
                    }
                }
            }
            if !group.agents.isEmpty {
                SettingsSection(title: L10n.text("显示窗口", "Visible windows"),
                                subtitle: L10n.text("拖动窗口，调整光晕和面板中的顺序。", "Drag windows to reorder the glow and panel."), theme: theme) {
                    ForEach(group.agents) { agent in
                        AgentOrderRow(agent: agent, theme: theme, accountName: group.accountName(for: agent)) {
                            settings.setAgent(id: agent.id, enabled: $0)
                        }
                        .onDrag {
                            dragging = .model(agent.id)
                            return NSItemProvider(object: agent.id as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(target: .model(agent.id), dragging: $dragging, settings: settings))
                        if agent.id != group.agents.last?.id { SettingsDivider(theme: theme) }
                    }
                }
            }
            if group.hasLiveStatus {
                SettingsSection(title: L10n.text("会话与提醒", "Sessions & reminders"), theme: theme) {
                    AgentLiveStatusSettings(vendor: group.id, settings: settings)
                }
            }
            let observer = ClientObserverStatus(vendor: group.id, clientHooks: settings.settings.clientHooks, report: report)
            if observer != nil || group.id == AdditionalSource.copilot.vendor {
                SettingsSection(title: L10n.text("客户端读取", "Client readings"), theme: theme) {
                    if let observer { ClientObserverSettings(status: observer, theme: theme) }
                    if group.id == AdditionalSource.copilot.vendor {
                        if observer != nil { SettingsDivider(theme: theme) }
                        CopilotQuotaSettings(settings: settings)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var balanceAccounts: [APIBilling] {
        group.billingAccounts.filter { billing in !group.accounts.contains { $0.account.id == billing.id } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentLogo(vendor: group.id, size: 26)
            VStack(alignment: .leading, spacing: 7) {
                Text(VendorCatalog.name(group.id)).font(.ui(17, .semibold))
                ForEach(group.plans, id: \.self) { plan in PlanBadge(plan: plan, theme: theme) }
                if !group.apiProviders.isEmpty {
                    Text("API · " + group.apiProviders.joined(separator: ", "))
                        .font(.ui(11)).foregroundStyle(theme.secondary)
                }
                if let source = group.source {
                    Text(source.statusLabel).font(.ui(11)).foregroundStyle(theme.secondary)
                    if !source.detail.isEmpty {
                        Text(source.detail).font(.ui(11)).foregroundStyle(theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One signed-in or previously seen account: its plan badge, name and whether it is the current login.
private struct AccountSummary: View {
    let account: AccountObservation
    let label: String
    let settings: SettingsStore
    let theme: Theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(account.displayName)
                    .font(.ui(12)).foregroundStyle(account.isCurrent ? theme.text : theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if let plan = account.planLabel { PlanBadge(plan: plan, theme: theme) }
                    Text(label).font(.ui(10)).foregroundStyle(theme.tertiary)
                }
            }
            Spacer(minLength: 8)
            AccountVisibilityToggle(id: account.account.id, name: account.displayName, settings: settings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AccountVisibilitySummary: View {
    let id: String
    let name: String
    let detail: String?
    let settings: SettingsStore
    let theme: Theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.ui(11)).foregroundStyle(theme.secondary)
                if let detail {
                    Text(detail).font(.ui(10)).foregroundStyle(theme.tertiary)
                }
            }
            Spacer(minLength: 8)
            AccountVisibilityToggle(id: id, name: name, settings: settings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AccountVisibilityToggle: View {
    let id: String
    let name: String
    let settings: SettingsStore

    var body: some View {
        Toggle(L10n.text("在 HUD 中显示", "Show in HUD"), isOn: Binding(
            get: { settings.settings.accountVisible(id) },
            set: { settings.setAccount(id: id, visible: $0) }
        ))
        .labelsHidden().toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(L10n.text("在 HUD 中显示 \(name)", "Show \(name) in HUD"))
        .accessibilityIdentifier("account-visibility-\(id)")
        .help(L10n.text("显示此账户的额度和余额。历史会话和 Token 统计持续更新。",
                       "Show this account's quotas and balances. Session history and token usage keep updating."))
    }
}

private struct AgentLiveStatusSettings: View {
    let vendor: String
    let settings: SettingsStore

    var body: some View {
        SettingRow(label: L10n.text("实时状态", "Live status"),
                   subtitle: L10n.text("显示会话状态与完成提醒", "Show session status and completion reminders")) {
            Toggle(L10n.text("实时状态", "Live status"), isOn: Binding(get: {
                settings.settings.liveStatusEnabled(for: vendor)
            }, set: { value in
                settings.update { $0.setLiveStatus(for: vendor, enabled: value) }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityIdentifier("agent-live-status-\(vendor.lowercased())")
        }
        .help(L10n.text("历史会话和 Token 统计持续更新。", "Session history and token usage keep updating."))
    }
}

/// Pi and OpenCode report finished turns only through the file Agent HUD keeps in them, and a client reads that file only
/// when it starts, so the row says whether the file is in place, when it last reported, and what an open client needs.
struct ClientObserverStatus {
    let label: String
    let state: String
    let detail: String
    let isWorking: Bool

    init?(vendor: String, clientHooks: Bool, report: UsageReport?, now: Date = Date()) {
        let file: ClientObserverFile, last: Date?, taken: String, open: String, unsupported: String?
        switch vendor {
        case "Pi":
            label = L10n.text("Pi 扩展", "Pi extension")
            file = PiSessionObserver.fileState()
            last = report?.turns.filter { $0.provider == "Pi" }.map { Date(timeIntervalSince1970: Double($0.observedAtMs) / 1000) }.max()
            taken = L10n.text("agent-hud.ts 已被其他扩展使用，Agent HUD 不会动它。", "agent-hud.ts belongs to another extension, which Agent HUD leaves alone.")
            open = L10n.text("已经开着的 Pi 输入一次 /reload 后开始报告", "Pi sessions already open report after /reload")
            unsupported = PiSessionObserver.unsupportedVersion().map {
                let first = PiSessionObserver.firstSettlingRelease
                return L10n.text("Pi \(first) 起才会报告完成，这里的 Pi 是 \($0)。", "Pi \(first) and later report finished turns; this Pi is \($0).")
            }
        case "OpenCode":
            label = L10n.text("OpenCode 插件", "OpenCode plugin")
            file = OpenCodeSessionObserver.fileState()
            last = report?.completions.filter { $0.vendor == "OpenCode" }.map(\.completedAt).max()
            taken = L10n.text("agent-hud.js 已被其他插件使用，Agent HUD 不会动它。", "agent-hud.js belongs to another plugin, which Agent HUD leaves alone.")
            open = L10n.text("已经开着的 OpenCode 重开后开始报告", "OpenCode already open reports once restarted")
            unsupported = nil
        default: return nil
        }
        switch file {
        case _ where !clientHooks:
            state = L10n.text("已关闭", "Off")
            detail = L10n.text("在「通用」中打开「客户端回调」后安装。", "Installed once Client hooks is on in General.")
        case .foreign:
            state = L10n.text("未安装", "Not installed")
            detail = taken
        case .missing:
            state = L10n.text("未安装", "Not installed")
            detail = L10n.text("Agent HUD 下次启动时安装。", "Installed when Agent HUD next starts.")
        case .installed:
            state = L10n.text("已安装", "Installed")
            if let unsupported {
                detail = unsupported
            } else if let last {
                let ago = Countdown.formatRough(max(0, now.timeIntervalSince(last)))
                detail = L10n.text("上次报告 \(ago) 前。", "Last report \(ago) ago. ") + open + L10n.text("。", ".")
            } else {
                detail = L10n.text("还没有报告。", "No reports yet. ") + open + L10n.text("，新开的会自动加载。", "; new ones load it on their own.")
            }
        }
        isWorking = clientHooks && file == .installed && unsupported == nil
    }
}

private struct ClientObserverSettings: View {
    let status: ClientObserverStatus
    let theme: Theme

    var body: some View {
        SettingRow(label: status.label, subtitle: status.detail) {
            Text(status.state).font(.ui(12))
                .foregroundStyle(status.isWorking ? theme.secondary : theme.statusText(.warning))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Quota reading uses the GitHub CLI sign-in, so each time it is switched on the user confirms what is read.
private struct CopilotQuotaSettings: View {
    let settings: SettingsStore
    @State private var confirming = false

    var body: some View {
        SettingRow(label: L10n.text("读取额度", "Read quota"),
                   subtitle: L10n.text("使用 GitHub CLI 的登录查询 Copilot 额度", "Query Copilot quota with the GitHub CLI sign-in")) {
            Toggle(L10n.text("读取额度", "Read quota"), isOn: Binding(get: {
                settings.settings.readCopilotQuota || confirming
            }, set: { value in
                if value { confirming = true } else { settings.update { $0.readCopilotQuota = false } }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityIdentifier("agent-copilot-quota")
        }
        .alert(L10n.text("读取 GitHub Copilot 额度？", "Read GitHub Copilot quota?"), isPresented: $confirming) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("同意", "Allow")) { settings.update { $0.readCopilotQuota = true } }
        } message: {
            Text(L10n.text(
                "将读取 GitHub CLI 的登录信息（环境变量 GH_TOKEN 或 GITHUB_TOKEN、macOS 钥匙串中的 gh:github.com、~/.config/gh/hosts.yml），向 api.github.com 查询 Copilot 额度。macOS 可能会请求访问钥匙串。",
                "This reads the GitHub CLI sign-in (the GH_TOKEN or GITHUB_TOKEN environment variable, gh:github.com in the macOS keychain, ~/.config/gh/hosts.yml) to query Copilot quota from api.github.com. macOS may ask for keychain access."))
        }
    }
}
