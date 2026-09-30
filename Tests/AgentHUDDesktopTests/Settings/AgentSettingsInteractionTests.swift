import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// Native pointer interactions on the Agents settings page. Click positions follow the 760 × 800 Chinese reference
/// snapshots (`settings-agents-*`).
final class AgentSettingsInteractionTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    @MainActor
    func testGroupExpandsTogglesAWindowAndCollapses() async throws {
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

        let hosting = NSHostingView(rootView: AnyView(SettingsView(settings: settings, store: store, initialTab: .sources,
                                                                  sourceStatuses: sources).frame(width: 760, height: 800)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 800)
        let window = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 800))
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
        var eventNumber = 0
        func click(x: CGFloat, yFromTop: CGFloat) {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                eventNumber += 1
                return NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 800 - yFromTop),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let moved = event(.mouseMoved), let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
                return XCTFail("Could not create mouse events")
            }
            window.sendEvent(moved)
            // AppKit tracks a press synchronously and takes its release from the event queue.
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
        }
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap(scrollView).first
        }
        func documentHeight() -> CGFloat { scrollView(hosting)?.documentView?.bounds.height ?? 0 }

        await settle()
        let collapsedHeight = documentHeight()
        XCTAssertGreaterThan(collapsedHeight, 0, "Settings content renders")
        click(x: 450, yFromTop: 130)
        await settle(until: { documentHeight() > collapsedHeight + 100 })
        XCTAssertGreaterThan(documentHeight(), collapsedHeight + 100, "The group expands to show its windows")

        // The first window switch sits below the group's Live status row.
        let windowSwitchY: CGFloat = 246
        let agentsBefore = settings.agents
        let liveStatusBefore = settings.settings.liveStatusEnabled(for: "Claude")
        click(x: 700, yFromTop: windowSwitchY)
        await settle(until: { settings.agents != agentsBefore
            || settings.settings.liveStatusEnabled(for: "Claude") != liveStatusBefore })
        // Name whatever the click toggled, so a moved layout fails with its cause.
        let toggled = settings.agents.filter { agent in agentsBefore.first { $0.id == agent.id }?.enabled != agent.enabled }.map(\.id)
            + (settings.settings.liveStatusEnabled(for: "Claude") != liveStatusBefore ? ["Claude live status"] : [])
        XCTAssertEqual(toggled, ["settings-claude-5h"],
                       "The display switch at y \(Int(windowSwitchY)) must change the stored window selection; compare settings-agents-expanded-dark.png")
        let group = AgentSettingsGroup.make(sources: sources, agents: settings.agents).first { $0.id == "Claude" }
        XCTAssertEqual(group?.displayedCount, 1)
        XCTAssertEqual(group?.agents.count, 3)

        if let scroll = scrollView(hosting) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await settle()
        click(x: 450, yFromTop: 130)
        await settle(until: { abs(documentHeight() - collapsedHeight) <= 2 })
        XCTAssertEqual(documentHeight(), collapsedHeight, accuracy: 2, "The group collapses again")
    }
}
