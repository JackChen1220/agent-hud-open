import AppKit
import AgentHUDCore
import SwiftUI

/// Owns the local desktop presentation and observes the supplied usage store.
@MainActor
public final class DesktopApplication {
    public let settings: SettingsStore
    public let store: UsageStore
    private let options: DesktopLaunchOptions
    private let additionalSettingsPages: [DesktopSettingsPage]
    private let additionalMenuItems: () -> [NSMenuItem]
    private let additionalHUDControls: @MainActor (@escaping @MainActor () -> Void) -> AnyView
    private let onIslandEvents: ((IslandEventTracker.Update, UsageReport, Date) -> Void)?
    private var islandEvents = IslandEventTracker()
    /// The requests already on the island, so a change to the waiting list says which ones arrived and which left.
    private var shownRequests: [String] = []
    /// The clients whose observer directory existed at the last look, so one that appears later is noticed.
    private var observedClients: Set<String> = []
    private let antigravityApprovals = AntigravityPermissionObserver()
    private let deepseekQuestions = DeepSeekQuestionObserver()
    private var notch: IslandController?
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, store: store, additionalPages: additionalSettingsPages
    )
    private lazy var statsWindow = StatsWindowController(store: store)
    private lazy var repositories = RepositoryStore(storageURL: options.demo ? nil : AppSupport.directory.appendingPathComponent("repositories-v1.json"))
    private lazy var repositoryWindow = RepositoryWindowController(store: repositories)
    private let onboardingWindow: OnboardingWindowController

    /// `onIslandEvents` receives every island event check after the island has presented it, including checks that
    /// found nothing, with the report and time the check used.
    public init(options: DesktopLaunchOptions, settings: SettingsStore, store: UsageStore,
                additionalSettingsPages: [DesktopSettingsPage] = [],
                additionalMenuItems: @escaping () -> [NSMenuItem] = { [] },
                additionalHUDControls: @escaping @MainActor (@escaping @MainActor () -> Void) -> AnyView = { _ in AnyView(EmptyView()) },
                onIslandEvents: ((IslandEventTracker.Update, UsageReport, Date) -> Void)? = nil) {
        self.options = options
        self.settings = settings
        self.store = store
        self.additionalSettingsPages = additionalSettingsPages
        self.additionalMenuItems = additionalMenuItems
        self.additionalHUDControls = additionalHUDControls
        self.onIslandEvents = onIslandEvents
        onboardingWindow = OnboardingWindowController(settings: settings, store: store,
            sources: options.demo ? { DemoData.sources } : { SourceDetector.detect() })
        onboardingWindow.onFinish = { [weak self] in
            guard let self else { return }
            self.settings.markOnboardingComplete()
            Task { await self.store.refresh() }
        }
    }

    public func start() {
        let sources = options.demo ? DemoData.sources : SourceDetector.resolve(SourceDetector.detect(), report: store.report)
        settings.update { $0.applyLiveStatusDefaults(sources: sources) }
        applyAppearance()
        let notch = IslandController(store: store, settings: settings, additionalHUDControls: additionalHUDControls)
        notch.onOpenStats = { [weak self] in self?.showStats() }
        notch.onOpenSettings = { [weak self] in self?.showSettings() }
        self.notch = notch
        notch.repositories = repositories
        notch.onOpenRepositories = { [weak self] in self?.repositoryWindow.show() }
        Task { await repositories.load() }
        let statusItem = StatusItemController(store: store, settings: settings, additionalMenuItems: additionalMenuItems)
        statusItem.actions = MenuActions(
            toggleGlow: { [weak self] in self?.toggleGlow() },
            openSettings: { [weak self] in self?.showSettings() },
            openStats: { [weak self] in self?.showStatsOverview() },
            quit: { NSApp.terminate(nil) }
        )
        self.statusItem = statusItem
        HotKeyCenter.shared.register(id: 1, keyCode: HotKeyCenter.keyH, modifiers: HotKeyCenter.commandOption) { [weak self] in
            self?.toggleGlow()
        }
        configurePanelShortcut()
        trackChanges({ [weak self] in self?.settings.settings.panelShortcut },
                     onChange: { [weak self] in self?.configurePanelShortcut() })
        trackChanges({ [weak self] in
            self?.settings.settings.appearance
        }, onChange: { [weak self] in self?.applyAppearance() })
        trackChanges({ [weak self] in
            self?.settings.settings.language
        }, onChange: { [weak self] in
            guard let self else { return }
            self.statusItem?.refreshButton()
            self.notch?.apply(animated: false)
            Task { await self.store.refresh() }
        })
        trackChanges({ [weak self] in
            _ = self?.store.lastError
        }, onChange: { [weak self] in
            if let error = self?.store.lastError { NSLog("[AgentHUD] refresh failed: %@", error) }
        })
        // A new install starts with launch at login on, and nothing registers it until the setting is applied: a start
        // registers an item that was never registered, and a flip of the switch applies at once. The demo leaves the
        // system's login items alone.
        if !options.demo, settings.settings.launchAtLogin { LoginItem.registerIfNeverRegistered() }
        trackChanges({ [weak self] in
            self?.settings.settings.launchAtLogin
        }, onChange: { [weak self] in
            guard let self, !self.options.demo else { return }
            LoginItem.set(self.settings.settings.launchAtLogin)
        })
        PermissionRequests.shared.holdTime = TimeInterval(settings.settings.approvalWaitMinutes * 60)
        trackChanges({ [weak self] in
            self?.settings.settings.approvalWaitMinutes
        }, onChange: { [weak self] in
            guard let self else { return }
            PermissionRequests.shared.holdTime = TimeInterval(self.settings.settings.approvalWaitMinutes * 60)
        })
        // The host installs the handlers at launch; a change of mind while running applies at once, with the same
        // executable the host gave them.
        trackChanges({ [weak self] in
            self?.settings.settings.clientHooks
        }, onChange: { [weak self] in
            guard let self, !self.options.demo, let executable = Bundle.main.executableURL else { return }
            SessionObservers.configure(executable: executable, enabled: self.settings.settings.clientHooks)
            self.antigravityApprovals.setEnabled(self.settings.settings.clientHooks)
            self.deepseekQuestions.setEnabled(self.settings.settings.clientHooks)
        })
        // A client run for the first time creates its directory, and its observer goes in with the next report
        // rather than at the next launch.
        if !options.demo { observedClients = SessionObservers.observedClients() }
        trackChanges({ [weak self] in
            _ = self?.store.report
        }, onChange: { [weak self] in self?.installObserversForNewClients() })
        trackChanges({ [weak self] in
            _ = self?.store.report
            _ = self?.settings.agents
            _ = self?.settings.settings.disabledLiveStatusSources
        }, onChange: { [weak self] in self?.checkIslandEvents() })
        // The channel is open whenever the app is: a client that asks while it is closed keeps its own prompt.
        trackChanges({ PermissionRequests.shared.pending.map(\.id) },
                       onChange: { [weak self] in self?.syncPermissionRequests() })
        // Seeded after the island is listening, so the demo's requests arrive the way a client's would.
        if options.demo { PermissionRequests.shared.seedDemo() } else { PermissionRequests.shared.start() }
        if !options.demo {
            antigravityApprovals.setEnabled(settings.settings.clientHooks)
            deepseekQuestions.setEnabled(settings.settings.clientHooks)
        }
        store.start()
        if options.openPanel { notch.forceOpen() }
        if store.isAccessAllowed, options.showOnboarding || !settings.hasCompletedOnboarding { showOnboarding() }
        if options.showSettings { showSettings() }
        if options.showStats { showStats() }
    }

    public func stop() {
        antigravityApprovals.stop()
        deepseekQuestions.stop()
        // Quitting must never leave a client waiting on an answer that is no longer coming.
        PermissionRequests.shared.stop()
        store.stop()
        repositories.stop()
        notch?.stop()
        HotKeyCenter.shared.unregister(id: 2)
    }

    /// Mirrors the requests waiting for the user onto the island: a new one is shown, and one the client took back
    /// disappears without being answered.
    private func syncPermissionRequests() {
        let pending = PermissionRequests.shared.pending
        let ids = pending.map(\.id)
        for id in shownRequests where !ids.contains(id) { notch?.withdraw(requestID: id) }
        for request in pending where !shownRequests.contains(request.id) { notch?.present(.permission(request)) }
        shownRequests = ids
        QuestionDraft.keep(Set(ids))
        // A request that only joined or left the queue changes no card, but it does change how many are waiting.
        notch?.apply(animated: true)
    }
    private func configurePanelShortcut() {
        let shortcut = settings.settings.panelShortcut
        let center = HotKeyCenter.shared
        center.unregister(id: 2)
        center.panelShortcutError = nil
        guard shortcut.enabled else { return }
        if !center.register(id: 2, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, handler: { [weak self] in
            self?.notch?.togglePanel()
        }) {
            center.panelShortcutError = L10n.text("快捷键被占用或不可用，请更换组合。", "Shortcut is unavailable or in use. Choose another combination.")
        }
    }

    public func showSettings(pageID: String? = nil) { settingsWindow.show(pageID: pageID) }
    public func showStats() {
        Task { await store.refreshAccounts() }
        statsWindow.show()
    }
    /// The statistics window on its Tokens page: the menu's rows are about quotas and balances. A session page opened
    /// from the HUD outlives its window, so the Sessions page starts from its list again.
    public func showStatsOverview() {
        store.focusedSessionID = nil
        store.statsTab = .tokens
        showStats()
    }
    public func showOnboarding() { onboardingWindow.show() }
    public func toggleGlow() { store.glowHidden.toggle() }

    /// Start-up installs observers only where a client's directory already exists. A client that already runs loads its
    /// observer when it next starts or reloads.
    private func installObserversForNewClients() {
        guard !options.demo else { return }
        let present = SessionObservers.observedClients()
        if settings.settings.clientHooks, !present.subtracting(observedClients).isEmpty { SessionObservers.installObservers() }
        observedClients = present
    }

    /// A paused store or a failed refresh leaves the island silent; the baselines wait for the next good report.
    private func checkIslandEvents() {
        guard !store.isPaused, store.lastError == nil, let report = store.report else { return }
        let now = Date()
        let update = islandEvents.update(report: report, agents: settings.agents, now: now, settings: settings.settings)
        for alert in update.quotaAlerts { notch?.present(alert) }
        for grant in update.resetCreditGrants { notch?.present(.resetCredits(grant)) }
        for completion in update.completions { notch?.present(.completion(completion)) }
        onIslandEvents?(update, report, now)
    }

    private func applyAppearance() {
        switch settings.settings.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}
