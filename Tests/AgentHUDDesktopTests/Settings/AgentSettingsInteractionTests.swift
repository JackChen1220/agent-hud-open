import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// Native control actions and provider pointer interactions, located from the rendered AppKit controls.
final class AgentSettingsInteractionTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    @MainActor
    func testProviderSelectionAndAccountSwitchesKeepRelatedSettingsConsistent() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.agents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0.language = .zhHans }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        settings.updateAgents { _ in [
            AgentDescriptor(id: "settings-claude-5h", vendor: "Claude", model: L10n.windowSession, source: L10n.sourceClaudeCode, enabled: true),
            AgentDescriptor(id: "settings-claude-week", vendor: "Claude", model: L10n.windowWeekly, source: L10n.sourceClaudeCode, enabled: true),
            AgentDescriptor(id: "settings-claude-model", vendor: "Claude", model: L10n.windowWeeklyPrefix + "Fable", source: L10n.sourceClaudeCode, enabled: false),
            AgentDescriptor(id: "settings-codex", vendor: "Codex", model: "5h", source: L10n.sourceCodexAppServer, enabled: true),
            AgentDescriptor(id: "settings-deepseek-chat", vendor: "DeepSeek", model: "deepseek-chat", source: L10n.sourceDeepSeekSessions, enabled: true),
            AgentDescriptor(id: "settings-deepseek-reasoner", vendor: "DeepSeek", model: "deepseek-reasoner", source: L10n.sourceDeepSeekSessions, enabled: true),
        ] }
        let sources: [SourceStatus] = [
            .init(id: "claude-code", name: "Claude", detail: L10n.text("额度、会话与用量统计", "Quota, sessions and usage"), state: .ready(plan: "max_20x")),
            .init(id: "codex-cli", name: "Codex", detail: L10n.text("额度、会话与用量统计", "Quota, sessions and usage"), state: .ready(plan: "prolite")),
            .init(id: "deepseek", name: "DeepSeek", detail: L10n.text("Harness 会话、API 余额与费用", "Harness sessions, API balance and costs"), state: .ready(plan: nil)),
            .init(id: "antigravity", name: "Antigravity", detail: L10n.text("启动并登录 Antigravity 或 agy 后读取额度 · 部分本地会话无法读取，用量可能不完整", "Start and sign in to Antigravity or agy to load quota. Some local sessions could not be read; usage may be incomplete."), state: .unavailable),
            .init(id: "cursor", name: "Cursor", detail: L10n.text("账户额度与跨设备用量", "Account quota and usage across devices"), state: .notDetected),
            .init(id: "grok", name: "Grok", detail: L10n.text("Grok CLI 额度与本地会话", "Grok CLI quota and local sessions"), state: .ready(plan: "X Premium")),
            .init(id: "opencode", name: "OpenCode", detail: "", state: .installed),
            .init(id: "pi", name: "Pi", detail: "", state: .installed),
            .init(id: "kimi", name: "Kimi", detail: "", state: .ready(plan: "Allegretto")),
            .init(id: "glm", name: "GLM", detail: "", state: .notDetected),
        ]
        store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: [],
            subscriptions: ["kimi-plan": "Allegretto"], billing: [DemoData.deepSeekBilling(now: Date())], services: [
                .init(client: "OpenCode", provider: "Anthropic", product: .api),
                .init(client: "OpenCode", provider: "OpenAI", product: .api),
                .init(client: "OpenCode", provider: "Kimi", product: .plan, accountID: "kimi-plan"),
                .init(client: "Pi", provider: "Anthropic", product: .api),
            ]))

        let size = SettingsWindowLayout.size
        let hosting = NSHostingView(rootView: AnyView(SettingsView(settings: settings, store: store, initialTab: .sources,
                                                                  sourceStatuses: sources).frame(width: size.width, height: size.height)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = AgentSettingsTestWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size))
        window.contentView = hosting
        window.acceptsMouseMovedEvents = true
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }

        func settle() async {
            try? await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
        }
        /// SwiftUI applies a click on its own schedule, so wait for the change the click makes instead of trusting a
        /// single delay; a loaded machine needs several.
        func settle(until reached: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while true {
                await settle()
                if reached() || Date() >= deadline { return }
            }
        }
        func views(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { views(in: $0) }
        }
        func scrollViews() -> [NSScrollView] {
            views(in: hosting).compactMap { $0 as? NSScrollView }
                .sorted { $0.convert($0.bounds, to: hosting).minX < $1.convert($1.bounds, to: hosting).minX }
        }
        func switches() -> [NSSwitch] {
            guard let detail = scrollViews().last else { return [] }
            return views(in: detail).compactMap { $0 as? NSSwitch }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .sorted {
                    let lhs = $0.convert($0.bounds, to: hosting), rhs = $1.convert($1.bounds, to: hosting)
                    return hosting.isFlipped ? lhs.minY < rhs.minY : lhs.maxY > rhs.maxY
                }
        }
        func providerButtons() -> [CGRect] {
            guard let list = scrollViews().first, let document = list.documentView else { return [] }
            let viewport = list.convert(list.bounds, to: hosting)
            var frames: [CGRect] = []
            for view in views(in: document) where !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: hosting)
                // Plain SwiftUI buttons need not have an NSButton backing. These are the rendered row controls,
                // narrower than the whole row (which includes its drag handle), with the row's full hit height.
                guard frame.width >= 70, frame.width < viewport.width - 24,
                      frame.height >= 40, frame.height <= 70, viewport.contains(frame),
                      !frames.contains(frame) else { continue }
                frames.append(frame)
            }
            return frames.sorted { hosting.isFlipped ? $0.minY < $1.minY : $0.maxY > $1.maxY }
        }
        func hierarchy() -> String {
            views(in: hosting).map {
                "\(type(of: $0)) frame=\($0.convert($0.bounds, to: hosting)) hidden=\($0.isHiddenOrHasHiddenAncestor)"
            }.joined(separator: "\n")
        }
        var eventNumber = 0
        func click(_ frame: CGRect) throws {
            let point = hosting.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                eventNumber += 1
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            }
            let moved = try event(.mouseMoved), down = try event(.leftMouseDown), up = try event(.leftMouseUp)
            window.sendEvent(moved)
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            window.sendEvent(up)
        }
        func clickFirstSwitch() throws {
            let control = try XCTUnwrap(switches().first, "Missing native switch\n\(hierarchy())")
            // AppKit routes the native action even when the test window is outside the display's hit-test bounds.
            control.performClick(nil)
        }
        func selectProvider(_ index: Int) throws {
            let buttons = providerButtons()
            guard buttons.indices.contains(index) else {
                XCTFail("Missing provider row \(index)\n\(hierarchy())")
                throw NSError(domain: "AgentSettingsInteractionTests", code: 1)
            }
            try click(buttons[index])
        }

        await settle(until: { switches().count == 4 && providerButtons().count >= 2 })
        XCTAssertEqual(scrollViews().count, 2, "The provider list and details scroll independently")
        XCTAssertEqual(switches().count, 4, "Claude's three windows and Live status are editable immediately\n\(hierarchy())")

        let agentsBefore = settings.agents
        let liveStatusBefore = settings.settings.liveStatusEnabled(for: "Claude")
        try clickFirstSwitch()
        await settle(until: { settings.agents != agentsBefore })
        let toggled = settings.agents.filter { agent in agentsBefore.first { $0.id == agent.id }?.enabled != agent.enabled }.map(\.id)
        XCTAssertEqual(toggled, ["settings-claude-5h"], "The window switch changes only its stored display preference")
        XCTAssertEqual(settings.settings.liveStatusEnabled(for: "Claude"), liveStatusBefore)
        let group = AgentSettingsGroup.make(sources: sources, agents: settings.agents).first { $0.id == "Claude" }
        XCTAssertEqual(group?.displayedCount(settings: settings.settings), 1)
        XCTAssertEqual(group?.agents.count, 3)
        let editedAgents = settings.agents

        try selectProvider(1)
        await settle(until: { switches().count == 2 })
        XCTAssertEqual(switches().count, 2, "Selecting Codex replaces Claude's settings with its window and Live status")
        XCTAssertEqual(settings.agents, editedAgents)
        try clickFirstSwitch()
        await settle(until: { settings.agents.first { $0.id == "settings-codex" }?.enabled == false })
        XCTAssertEqual(settings.agents.first { $0.id == "settings-codex" }?.enabled, false,
                       "The selected provider's rendered switch edits Codex, not Claude")
        let editedProviders = settings.agents

        try selectProvider(0)
        await settle(until: { switches().count == 4 })
        XCTAssertEqual(switches().count, 4)
        XCTAssertEqual(settings.agents, editedProviders, "Switching providers preserves both providers' edited windows")

        try selectProvider(0)
        await settle()
        XCTAssertEqual(switches().count, 4, "Selecting the current provider does not collapse its details")
        XCTAssertEqual(settings.agents, editedProviders)
        try clickFirstSwitch()
        await settle(until: { settings.agents.first { $0.id == "settings-claude-5h" }?.enabled == true })
        XCTAssertEqual(settings.agents.first { $0.id == "settings-claude-5h" }?.enabled, true,
                       "The window remains editable after selecting the current provider again")
        XCTAssertEqual(settings.agents.first { $0.id == "settings-codex" }?.enabled, false)

        // A provider without a local installation has an editable, initially Off live-status switch.
        let cursorIndex = try XCTUnwrap(AgentSettingsGroup.make(sources: sources, agents: settings.agents, report: store.report)
            .firstIndex { $0.id == "Cursor" })
        try selectProvider(cursorIndex)
        await settle(until: { switches().count == 1 && switches().first?.state == .off })
        XCTAssertFalse(settings.settings.liveStatusEnabled(for: "Cursor"))
        XCTAssertEqual(switches().first?.state, .off)
        XCTAssertEqual(switches().first?.isEnabled, true)
        try clickFirstSwitch()
        await settle(until: { settings.settings.liveStatusEnabled(for: "Cursor") && switches().first?.state == .on })
        XCTAssertTrue(settings.settings.liveStatusEnabled(for: "Cursor"), "An undetected client can still be enabled manually")
        XCTAssertEqual(switches().first?.state, .on)

        let work = try XCTUnwrap(ProviderAccount.identified(provider: "Codex", user: "work@example.com", workspace: nil))
        let personal = try XCTUnwrap(ProviderAccount.identified(provider: "Codex", user: "personal@example.com", workspace: nil))
        let accountWindows = [
            AgentDescriptor(id: work.windowID("5h"), vendor: "Codex", model: "5h", source: "", enabled: true, account: work),
            AgentDescriptor(id: work.windowID("weekly"), vendor: "Codex", model: "Weekly", source: "", enabled: false, account: work),
            AgentDescriptor(id: personal.windowID("5h"), vendor: "Codex", model: "5h", source: "", enabled: true, account: personal),
        ]
        settings.updateAgents { _ in accountWindows }
        store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: []))
        hosting.rootView = AnyView(SettingsView(settings: settings, store: store, initialTab: .sources,
            sourceStatuses: sources, initialProviderID: "Codex")
            .frame(width: size.width, height: size.height).id("account-windows"))
        await settle(until: { switches().count == 6 })
        XCTAssertEqual(switches().count, 6, "Two account switches, three windows and Live status")
        XCTAssertTrue(settings.settings.liveStatusEnabled(for: "Cursor"), "Rendering another provider preserves the manual On choice")
        try clickFirstSwitch()
        await settle(until: { !settings.settings.accountVisible(work.id) && switches().map(\.state) == [.off, .on, .off, .off, .on, .on] })
        XCTAssertFalse(settings.settings.accountVisible(work.id))
        XCTAssertEqual(settings.agents.map(\.enabled), [false, false, true], "Account Off changes only its own windows")
        XCTAssertEqual(switches().map(\.state), [.off, .on, .off, .off, .on, .on], "Rendered window switches follow Account Off")
        XCTAssertEqual(switches().map(\.isEnabled), [true, true, false, false, true, true], "Hidden windows wait for their account to be shown")
        try clickFirstSwitch()
        await settle(until: { settings.settings.accountVisible(work.id) && switches().allSatisfy { $0.state == .on } })
        XCTAssertTrue(settings.settings.accountVisible(work.id))
        XCTAssertEqual(settings.agents.map(\.enabled), [true, true, true], "Account On enables every corresponding window")
        XCTAssertTrue(switches().allSatisfy { $0.state == .on }, "Rendered window switches follow Account On")
        XCTAssertTrue(switches().allSatisfy(\.isEnabled), "Showing the account makes each window editable again")
        XCTAssertEqual(settings.agents.map(\.id), accountWindows.map(\.id), "Account toggles preserve manual window order")
    }
}

/// The interaction test also runs against Release builds, which omit the snapshot runner's window helper.
@MainActor
private final class AgentSettingsTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
