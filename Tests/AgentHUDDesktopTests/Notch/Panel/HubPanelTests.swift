import AppKit
import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

final class HubPanelTests: XCTestCase {
    @MainActor
    func testPinKeepsPanelOpenAndUnpinRestoresHoverCollapse() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.pin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        settings.update { $0.hoverDelayMs = 0; $0.collapseDelayMs = 0 }
        let usage = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let hud = ScreenHUD(key: "pin-test", screen: NSScreen.main, store: usage, settings: settings)
        defer { hud.close() }
        hud.toggleFromKeyboard()
        hud.pointer(inside: true)
        hud.togglePin()
        hud.pointer(inside: false)
        hud.dismissFromOutside(at: CGPoint(x: -100000, y: -100000))
        XCTAssertTrue(hud.isPinned && hud.isOpen)
        hud.pointer(inside: true)
        hud.togglePin()
        XCTAssertFalse(hud.isPinned || hud.keyboardHeld)
        XCTAssertTrue(hud.isOpen)
        hud.pointer(inside: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(hud.isOpen)
        hud.toggleFromKeyboard()
        hud.togglePin()
        hud.forceCollapse()
        XCTAssertFalse(hud.isPinned || hud.isOpen)
    }

    @MainActor
    func testExpandedHubStaysDarkAcrossAppearanceChanges() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: 24, now: Date()))
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 540, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for scheme in [ColorScheme.light, .dark, .light] {
            var root = IslandRootView.placeholder
            root = IslandRootView(store: store, isOpen: true, collapsedSize: root.collapsedSize,
                                  collapsedTopRadius: root.collapsedTopRadius,
                                  collapsedBottomRadius: root.collapsedBottomRadius,
                                  lightBorder: false, onOpenStats: {}, navigation: HubNavigation())
            host.rootView = AnyView(root.environment(\.colorScheme, scheme))
            host.frame = CGRect(x: 0, y: 0, width: 540, height: 700)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Sample the backdrop before the content inset, not a session label.
            let color = try XCTUnwrap(bitmap.colorAt(x: 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/validation/hub-\(scheme == .light ? "light" : "dark").png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            XCTAssertLessThan(color.redComponent, 0.1, "Hub stays black even when independent windows use light appearance")
        }
    }

    @MainActor
    func testTabSwitchUpdatesNativeHeightImmediatelyWithoutUsageRefresh() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.tabheight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        settings.update { $0.showIslandQuota = false; $0.showIslandTokens = false; $0.showIslandSessions = false }
        let usage = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let repositories = RepositoryStore(storageURL: nil)
        await repositories.load()
        let controller = IslandController(store: usage, settings: settings)
        controller.repositories = repositories
        defer { controller.stop() }
        controller.forceOpen()
        controller.apply(animated: false)
        let initial = controller.island.panel.frame.height
        for _ in 0..<4 {
            controller.navigation.tab = .branches
            let branchHeight = controller.island.panel.frame.height
            XCTAssertGreaterThan(branchHeight, initial + 100, "Native mask/frame must grow in the tab action, not on the next usage poll")
            controller.navigation.tab = .agents
            XCTAssertEqual(controller.island.panel.frame.height, initial, accuracy: 1, "No stale blank area after switching back")
        }
    }

    @MainActor
    func testKeyboardOpenStaysOpenAndCloseRequiresPointerExit() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.hub.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        settings.update { $0.hoverDelayMs = 0; $0.collapseDelayMs = 0 }
        let usage = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let hud = ScreenHUD(key: "test", screen: NSScreen.main, store: usage, settings: settings)
        defer { hud.close() }
        hud.toggleFromKeyboard()
        XCTAssertTrue(hud.isOpen && hud.keyboardHeld)
        hud.pointer(inside: true)
        hud.pointer(inside: false)
        XCTAssertTrue(hud.isOpen, "Moving to the keyboard-opened panel must not collapse it")
        hud.pointer(inside: true)
        hud.toggleFromKeyboard()
        XCTAssertFalse(hud.isOpen)
        hud.pointer(inside: true)
        XCTAssertFalse(hud.isOpen, "A stationary pointer must not reopen a dismissed panel")
        hud.pointer(inside: false)
        hud.toggleFromKeyboard()
        hud.dismissFromOutside(at: CGPoint(x: -100000, y: -100000))
        XCTAssertFalse(hud.isOpen || hud.keyboardHeld)
    }

    @MainActor
    func testBranchPanelRendersBoundedContentAndKeepsNavigation() async throws {
        _ = NSApplication.shared
        L10n.setLanguage(.zhHans)
        defer { L10n.setLanguage(.system) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        var archive = RepositoryArchive()
        let repo = TrackedRepository(id: root.appendingPathComponent(".git").path, path: root.appendingPathComponent("crm-monorepo").path)
        archive.repositories = [repo]; archive.selectedID = repo.id
        let branch = GitBranch(name: "feat/team/CRM-89714", current: true, remote: false,
            upstream: "origin/feat/team/CRM-89714-clean", upstreamRemote: "origin", ahead: 2, behind: 0,
            sync: .ahead, subject: "修复报告数值与批量任务状态", committedAt: Date())
        var note = BranchNote(); note.title = "投诉报告"; note.progress = .testing; note.pinned = true
        archive.notes[repo.id] = [branch.name: note]
        archive.snapshots[repo.id] = RepositorySnapshot(branches: [branch], worktrees: [], remotes: ["origin"], readAt: Date())
        try JSONEncoder().encode(archive).write(to: cache)
        let repositories = RepositoryStore(storageURL: cache)
        await repositories.load()
        let domain = "app.agenthud.tests.branchpanel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        let usage = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let navigation = HubNavigation(); navigation.tab = .branches
        let view = HoverPanelView(store: usage, onOpenStats: {}, repositories: repositories, navigation: navigation, observesRepositories: false)
            .frame(width: 540).background(.black)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 540, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        let height = hosting.fittingSize.height
        XCTAssertGreaterThan(height, 300)
        XCTAssertLessThan(height, 650, "A branch list must not grow the island past the screen")
        hosting.frame = CGRect(x: 0, y: 0, width: 540, height: height)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/branch-panel-preview.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        XCTAssertEqual(navigation.tab, .branches)
        repositories.stop()
    }
}
