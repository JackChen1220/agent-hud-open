import AppKit
import AgentHUDCore
import XCTest
@testable import AgentHUDDesktop

final class SessionNavigationTests: XCTestCase {
    @MainActor
    func testNativeRoutesPreserveTheClientIdentity() throws {
        let threadID = UUID().uuidString.lowercased()
        XCTAssertEqual(SessionNavigator.url(for: .codexThread(id: threadID))?.absoluteString,
                       "codex://threads/" + threadID)
        XCTAssertNil(SessionNavigator.url(for: .codexThread(id: "../../other-thread")))
        let pane = "w1t2p3:" + UUID().uuidString
        let url = try XCTUnwrap(SessionNavigator.url(for: .iTermSession(id: pane)))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "iterm2")
        XCTAssertEqual(components.path, "reveal")
        XCTAssertNil(components.host, "iTerm's reveal command uses an opaque URL, without //")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "sessionid", value: pane)])
        XCTAssertNil(SessionNavigator.url(for: .iTermSession(id: " \n")))
        XCTAssertNil(SessionNavigator.url(for: .antigravityConversation(id: threadID)),
                     "Antigravity's URL scheme has no conversation route")
        XCTAssertEqual(SessionNavigator.url(for: .grokBotAgent(id: "agent_ID-1"))?.absoluteString,
                       "grokbot://app/v1/agent?id=agent_ID-1")
        for invalid in ["", "../other", "agent?prompt=submit", String(repeating: "a", count: 129), "对话"] {
            XCTAssertNil(SessionNavigator.url(for: .grokBotAgent(id: invalid)))
        }
        let desktopID = "local_" + threadID
        XCTAssertEqual(SessionNavigator.url(for: .claudeDesktopSession(id: desktopID))?.absoluteString,
                       "claude://claude.ai/epitaxy/" + desktopID)
        XCTAssertEqual(SessionNavigator.url(for: .claudeCoworkSession(id: desktopID))?.absoluteString,
                       "claude://claude.ai/cowork/" + desktopID)
        for invalid in [threadID, "local_../../other-session", "local_" + threadID + "?prompt=submit"] {
            XCTAssertNil(SessionNavigator.url(for: .claudeDesktopSession(id: invalid)))
            XCTAssertNil(SessionNavigator.url(for: .claudeCoworkSession(id: invalid)))
        }
    }

    @MainActor
    func testCompactCompletionExpandsChoicesWithoutChoosingADestination() throws {
        let fixture = try NavigationFixture { _ in XCTFail("Expanding the reminder is not a session jump"); return true }
        defer { fixture.close() }
        let alert = fixture.completion(target: .codexThread(id: UUID().uuidString))
        fixture.hud.present(alert)
        fixture.hud.island.rootView.onOpenAlert()
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        XCTAssertTrue(fixture.hud.island.rootView.showsAlertDetails)
        XCTAssertTrue(fixture.hud.holds(alert.id))
        XCTAssertEqual(fixture.statsOpens, 0)
    }

    @MainActor
    func testAReplyArrivingDuringUsageOpensInTheEventPanel() throws {
        let fixture = try NavigationFixture { _ in XCTFail("Presenting a reply does not navigate"); return true }
        defer { fixture.close() }
        fixture.hud.forceOpen()
        let reply = fixture.completion(target: .codexThread(id: UUID().uuidString))
        fixture.hud.present(reply)
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        XCTAssertTrue(fixture.hud.island.rootView.showsAlertDetails)
        XCTAssertEqual(fixture.hud.island.rootView.sessionEvents.map(\.id), [reply.id])
        XCTAssertEqual(fixture.statsOpens, 0)
    }

    @MainActor
    func testAQueuedReplyRefreshesTheEventPanelAndCanBeSelectedWithoutAnsweringPermission() throws {
        let fixture = try NavigationFixture { _ in XCTFail("Selecting an event does not navigate"); return true }
        defer { fixture.close() }
        fixture.hud.forceOpen()
        let question = PermissionQuestion(question: "Continue?", options: [.init(label: "Continue")])
        let request = PermissionRequest(id: "waiting-permission-" + UUID().uuidString,
                                        source: .claude, sessionID: "session", toolName: "AskUserQuestion",
                                        summary: "Choose the next step", detail: nil,
                                        cwd: "/tmp/agenthud-tests", questions: [question], at: Date())
        fixture.hud.present(.permission(request))
        let draft = QuestionDraft.draft(for: request.id)
        draft.type("Continue after review", of: 0, in: question)
        fixture.hud.island.panel.takeKeyboard()
        fixture.hud.island.rootView.onTyping(true)
        let reply = fixture.completion(target: .codexThread(id: UUID().uuidString))
        fixture.hud.present(reply)
        XCTAssertTrue(fixture.hud.island.rootView.showsAlertDetails)
        XCTAssertEqual(fixture.hud.island.rootView.alert?.id, request.id)
        XCTAssertEqual(fixture.hud.island.rootView.sessionEvents.map(\.id), [request.id, reply.id],
                       "Joining the queue must refresh its visible rows immediately")
        fixture.hud.island.rootView.onSelectRequest(reply.id)
        XCTAssertEqual(fixture.hud.island.rootView.alert?.id, reply.id)
        XCTAssertTrue(fixture.hud.island.rootView.showsAlertDetails)
        XCTAssertTrue(fixture.hud.holds(request.id), "The request is still unanswered after selecting a reply")
        XCTAssertEqual(fixture.hud.questions.map(\.id), [request.id])
        XCTAssertFalse(fixture.hud.island.panel.canBecomeKey, "Selecting a reply releases the old request's keyboard")
        XCTAssertTrue(QuestionDraft.draft(for: request.id) === draft)
        XCTAssertEqual(draft.answer(0, of: question), .init(custom: "Continue after review"), "Switching cards preserves its answer draft")
        XCTAssertEqual(fixture.statsOpens, 0)
    }

    @MainActor
    func testCompletionReturnsToTheClientEvenWithoutAUsageSession() async throws {
        var opened: [SessionNavigationTarget] = []
        let fixture = try NavigationFixture { target in opened.append(target); return true }
        defer { fixture.close() }
        let target = SessionNavigationTarget.codexThread(id: UUID().uuidString)
        fixture.hud.present(fixture.completion(target: target, sessionID: "unindexed-session"))
        await fixture.hud.openAlertSession()
        XCTAssertEqual(opened, [target])
        XCTAssertEqual(fixture.statsOpens, 0)
        XCTAssertNil(fixture.store.focusedSessionID)
    }

    @MainActor
    func testTokenUsageActionOpensTheMatchingUsageSessionWithoutAttemptingNavigation() throws {
        var attempts = 0
        let fixture = try NavigationFixture { _ in attempts += 1; return false }
        defer { fixture.close() }
        let target = SessionNavigationTarget.iTermSession(id: "w0t0p0:" + UUID().uuidString)
        fixture.hud.present(fixture.completion(target: target))
        fixture.hud.island.rootView.onOpenAlertUsage()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(fixture.statsOpens, 1)
        XCTAssertEqual(fixture.store.focusedSessionID, "session")
        XCTAssertEqual(fixture.store.statsTab, .sessions, "The selected session detail includes its token usage")
    }

    @MainActor
    func testFailedSessionJumpKeepsTheReminderForRetryOrTokenUsage() async throws {
        var attempts = 0
        let fixture = try NavigationFixture { _ in attempts += 1; return attempts > 1 }
        defer { fixture.close() }
        let alert = fixture.completion(target: .iTermSession(id: "w0t0p0:" + UUID().uuidString))
        fixture.hud.present(alert)
        await fixture.hud.openAlertSession()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(fixture.statsOpens, 0, "Failure must not silently change the selected destination")
        XCTAssertTrue(fixture.hud.holds(alert.id))
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        XCTAssertTrue(fixture.hud.island.rootView.sessionNavigationFailed)
        await fixture.hud.openAlertSession()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(fixture.hud.holds(alert.id))
        XCTAssertEqual(fixture.statsOpens, 0)
    }

    @MainActor
    func testFailedSessionJumpStillOffersAnExplicitTokenUsageChoice() async throws {
        let fixture = try NavigationFixture { _ in false }
        defer { fixture.close() }
        let alert = fixture.completion(target: .codexThread(id: UUID().uuidString))
        fixture.hud.present(alert, inUsagePanel: true)
        await fixture.hud.openAlertSession()
        XCTAssertTrue(fixture.hud.island.rootView.sessionNavigationFailed)
        fixture.hud.openAlertUsage()
        XCTAssertEqual(fixture.statsOpens, 1)
        XCTAssertEqual(fixture.store.focusedSessionID, "session")
        XCTAssertFalse(fixture.hud.holds(alert.id))
    }

    @MainActor
    func testCompletionWithoutAnOriginKeepsUsageAvailable() async throws {
        let fixture = try NavigationFixture { _ in XCTFail("No client was identified"); return true }
        defer { fixture.close() }
        fixture.hud.present(fixture.completion(target: nil))
        await fixture.hud.openAlertSession()
        XCTAssertEqual(fixture.statsOpens, 0, "An unavailable session action cannot become a usage action")
        fixture.hud.openAlertUsage()
        XCTAssertEqual(fixture.statsOpens, 1)
        XCTAssertEqual(fixture.store.focusedSessionID, "session")
    }

    @MainActor
    func testTokenUsageForAnUnindexedReplyOpensTheTokenOverview() throws {
        let fixture = try NavigationFixture { _ in XCTFail("Usage has no native navigation"); return true }
        defer { fixture.close() }
        fixture.store.statsTab = .sessions
        fixture.hud.present(fixture.completion(target: nil, sessionID: "unindexed-session"))
        fixture.hud.openAlertUsage()
        XCTAssertEqual(fixture.statsOpens, 1)
        XCTAssertNil(fixture.store.focusedSessionID)
        XCTAssertEqual(fixture.store.statsTab, .tokens)
    }

    @MainActor
    func testAPendingSessionJumpKeepsItsReminderWhenThePointerLeaves() async throws {
        var continuation: CheckedContinuation<Bool, Never>?
        let fixture = try NavigationFixture { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        defer { fixture.close() }
        fixture.hud.pointer(inside: true)
        let alert = fixture.completion(target: .antigravityConversation(id: UUID().uuidString))
        fixture.hud.present(alert)
        let click = Task { await fixture.hud.openAlertSession() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let reply = try XCTUnwrap(continuation)
        fixture.hud.pointer(inside: false)
        try await Task.sleep(for: IslandAlertQueue.visibleDuration + .milliseconds(200))
        XCTAssertTrue(fixture.hud.holds(alert.id), "A pending attempt must not lose its retry and usage choices")
        fixture.hud.openAlert()
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        reply.resume(returning: false)
        await click.value
        XCTAssertTrue(fixture.hud.holds(alert.id))
        XCTAssertTrue(fixture.hud.island.rootView.sessionNavigationFailed)
    }

    @MainActor
    func testQuotaAlertStillOpensUsage() async throws {
        let fixture = try NavigationFixture { _ in XCTFail("Quota events have no agent session"); return true }
        defer { fixture.close() }
        fixture.store.focusedSessionID = "session"
        fixture.hud.present(QuotaAlert.preview(.reset, agent: DemoData.agents[0]))
        fixture.hud.openAlert()
        XCTAssertEqual(fixture.statsOpens, 1)
        XCTAssertNil(fixture.store.focusedSessionID)
        XCTAssertEqual(fixture.store.statsTab, .tokens)
    }

    @MainActor
    func testAQueuedCompletionUsesTheSourcesCurrentTargetIncludingItsRemoval() async throws {
        var opened: [SessionNavigationTarget] = []
        let fixture = try NavigationFixture { target in opened.append(target); return true }
        defer { fixture.close() }
        let original = SessionNavigationTarget.iTermSession(id: "old-pane")
        let moved = SessionNavigationTarget.iTermSession(id: "current-pane")
        let alert = fixture.completion(target: original)
        guard case .completion(var latest) = alert else { return XCTFail("Expected completion") }
        fixture.hud.present(alert)
        latest.navigationTarget = moved
        fixture.store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: [], completions: [latest]))
        await fixture.hud.openAlertSession()
        XCTAssertEqual(opened, [moved])

        fixture.hud.present(alert)
        latest.navigationTarget = nil
        fixture.store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: [], completions: [latest]))
        await fixture.hud.openAlertSession()
        XCTAssertEqual(opened, [moved], "A cleared target must not resurrect the queued card's old pane")
        XCTAssertEqual(fixture.statsOpens, 0)
        fixture.hud.openAlertUsage()
        XCTAssertEqual(fixture.statsOpens, 1)
    }

    @MainActor
    func testALateFailureDoesNotOverrideANewerNavigation() async throws {
        let firstTarget = SessionNavigationTarget.antigravityConversation(id: UUID().uuidString)
        let newerTarget = SessionNavigationTarget.codexThread(id: UUID().uuidString)
        var firstReply: CheckedContinuation<Bool, Never>?
        var opened: [SessionNavigationTarget] = []
        let fixture = try NavigationFixture { target in
            opened.append(target)
            if target == firstTarget {
                return await withCheckedContinuation { firstReply = $0 }
            }
            return true
        }
        defer { fixture.close() }
        fixture.hud.present(fixture.completion(target: firstTarget))
        let firstClick = Task { await fixture.hud.openAlertSession() }
        for _ in 0..<100 where firstReply == nil { await Task.yield() }
        let reply = try XCTUnwrap(firstReply)
        fixture.hud.openAlertUsage()
        fixture.hud.present(fixture.completion(target: newerTarget))
        await fixture.hud.openAlertSession()
        reply.resume(returning: false)
        await firstClick.value
        XCTAssertEqual(opened, [firstTarget, newerTarget])
        XCTAssertEqual(fixture.statsOpens, 1, "Only the explicit token usage choice opens usage")
        XCTAssertFalse(fixture.hud.island.rootView.sessionNavigationFailed,
                       "The cancelled request cannot put its failure over the user's newer destination")
    }

    @MainActor
    func testListedSessionActionUsesTheCurrentSourceTargetAndCollapsesAfterSuccess() async throws {
        let original = SessionNavigationTarget.iTermSession(id: "old-pane")
        let current = SessionNavigationTarget.iTermSession(id: "current-pane")
        var opened: [SessionNavigationTarget] = []
        var continuation: CheckedContinuation<Bool, Never>?
        let fixture = try NavigationFixture { target in
            opened.append(target)
            return await withCheckedContinuation { continuation = $0 }
        }
        defer { fixture.close() }
        fixture.session(target: original)
        let unrelatedAlert = fixture.completion(target: nil)
        fixture.hud.present(unrelatedAlert, inUsagePanel: true)
        let action = fixture.hud.island.rootView.onOpenListedSession
        fixture.session(target: current, apply: false)
        action("session")
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let reply = try XCTUnwrap(continuation)
        XCTAssertEqual(opened, [current], "The row's old rendering cannot retain a moved destination")
        fixture.hud.forceOpen()
        reply.resume(returning: true)
        for _ in 0..<100 where fixture.hud.island.rootView.isOpen { await Task.yield() }
        XCTAssertFalse(fixture.hud.island.rootView.isOpen, "Success also collapses a panel reopened while navigation waited")
        XCTAssertTrue(fixture.hud.holds(unrelatedAlert.id), "A listed session must not consume another completion")
        XCTAssertEqual(fixture.statsOpens, 0)
        XCTAssertNil(fixture.store.focusedSessionID)
    }

    @MainActor
    func testListedSessionWithAClearedOrMissingTargetKeepsThePanelAndDoesNotOpenUsage() async throws {
        let fixture = try NavigationFixture { _ in XCTFail("No current source destination exists"); return true }
        defer { fixture.close() }
        fixture.session(target: .codexThread(id: UUID().uuidString))
        fixture.hud.forceOpen()
        fixture.session(target: nil, apply: false)
        await fixture.hud.openListedSession("session")
        await fixture.hud.openListedSession("removed-session")
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        XCTAssertNil(fixture.hud.island.rootView.failedListedSessionID)
        XCTAssertEqual(fixture.statsOpens, 0)
        XCTAssertNil(fixture.store.focusedSessionID)
    }

    @MainActor
    func testListedSessionFailureMarksOnlyItsRowAndRetryUsesTheCurrentTarget() async throws {
        let original = SessionNavigationTarget.iTermSession(id: "old-pane")
        let current = SessionNavigationTarget.iTermSession(id: "current-pane")
        var opened: [SessionNavigationTarget] = []
        let fixture = try NavigationFixture { target in opened.append(target); return target == current }
        defer { fixture.close() }
        fixture.session(target: original)
        fixture.hud.forceOpen()
        await fixture.hud.openListedSession("session")
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        XCTAssertEqual(fixture.hud.island.rootView.failedListedSessionID, "session")
        XCTAssertFalse(fixture.hud.island.rootView.sessionNavigationFailed)
        XCTAssertEqual(fixture.statsOpens, 0)
        fixture.session(target: nil)
        await fixture.hud.openListedSession("session")
        XCTAssertEqual(opened, [original], "Retry cannot revive an origin the source has removed")
        XCTAssertTrue(fixture.hud.island.rootView.isOpen)
        XCTAssertEqual(fixture.statsOpens, 0)
        fixture.session(target: current)
        await fixture.hud.openListedSession("session")
        XCTAssertEqual(opened, [original, current])
        XCTAssertNil(fixture.hud.island.rootView.failedListedSessionID)
        XCTAssertFalse(fixture.hud.island.rootView.isOpen)
        XCTAssertEqual(fixture.statsOpens, 0)
    }

    @MainActor
    func testListedTokenUsageCancelsAPendingSessionJumpWithoutALateFailure() async throws {
        var continuation: CheckedContinuation<Bool, Never>?
        let fixture = try NavigationFixture { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        defer { fixture.close() }
        fixture.session(target: .antigravityConversation(id: UUID().uuidString))
        fixture.hud.forceOpen()
        let click = Task { await fixture.hud.openListedSession("session") }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let reply = try XCTUnwrap(continuation)
        fixture.store.focusedSessionID = "session"
        fixture.hud.island.rootView.onOpenStats()
        reply.resume(returning: false)
        await click.value
        XCTAssertEqual(fixture.statsOpens, 1)
        XCTAssertEqual(fixture.store.focusedSessionID, "session")
        XCTAssertEqual(fixture.store.statsTab, .sessions)
        XCTAssertFalse(fixture.hud.island.rootView.isOpen)
        XCTAssertNil(fixture.hud.island.rootView.failedListedSessionID)
    }

    @MainActor
    func testALateListedFailureCannotOverrideANewerTargetForTheSameSession() async throws {
        let original = SessionNavigationTarget.antigravityConversation(id: UUID().uuidString)
        let current = SessionNavigationTarget.codexThread(id: UUID().uuidString)
        var continuation: CheckedContinuation<Bool, Never>?
        var opened: [SessionNavigationTarget] = []
        let fixture = try NavigationFixture { target in
            opened.append(target)
            if target == original {
                return await withCheckedContinuation { continuation = $0 }
            }
            return true
        }
        defer { fixture.close() }
        fixture.session(target: original)
        let click = Task { await fixture.hud.openListedSession("session") }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let reply = try XCTUnwrap(continuation)
        fixture.session(target: current)
        await fixture.hud.openListedSession("session")
        reply.resume(returning: false)
        await click.value
        XCTAssertEqual(opened, [original, current])
        XCTAssertFalse(fixture.hud.island.rootView.isOpen)
        XCTAssertNil(fixture.hud.island.rootView.failedListedSessionID)
        XCTAssertEqual(fixture.statsOpens, 0)
    }

    @MainActor
    func testCompletionNavigationCancelsALateListedFailure() async throws {
        let listed = SessionNavigationTarget.antigravityConversation(id: UUID().uuidString)
        let completion = SessionNavigationTarget.codexThread(id: UUID().uuidString)
        var continuation: CheckedContinuation<Bool, Never>?
        var opened: [SessionNavigationTarget] = []
        let fixture = try NavigationFixture { target in
            opened.append(target)
            if target == listed {
                return await withCheckedContinuation { continuation = $0 }
            }
            return true
        }
        defer { fixture.close() }
        fixture.session(target: listed)
        let click = Task { await fixture.hud.openListedSession("session") }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let reply = try XCTUnwrap(continuation)
        let alert = fixture.completion(target: completion)
        fixture.hud.present(alert)
        await fixture.hud.openAlertSession()
        reply.resume(returning: false)
        await click.value
        XCTAssertEqual(opened, [listed, completion])
        XCTAssertFalse(fixture.hud.holds(alert.id))
        XCTAssertNil(fixture.hud.island.rootView.failedListedSessionID)
        XCTAssertFalse(fixture.hud.island.rootView.sessionNavigationFailed)
        XCTAssertEqual(fixture.statsOpens, 0)
    }
}

@MainActor
private final class NavigationFixture {
    let defaults: UserDefaults
    let domain = "app.agenthud.tests.navigation." + UUID().uuidString
    let store: UsageStore
    let hud: ScreenHUD
    var statsOpens = 0

    init(open: @escaping @MainActor (SessionNavigationTarget) async -> Bool) throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: [
            LiveSession(id: "session", agentId: "codex-model:model", task: "Test", terminal: nil,
                        startedAt: Date(), pctOfWindow: nil, tokensIn: 0, tokensOut: 0)
        ]))
        let screen = try XCTUnwrap(NSScreen.main)
        hud = ScreenHUD(key: ScreenIdentity.key(for: screen), screen: screen, store: store, settings: settings,
                        mouseLocation: { .zero }, openSession: open)
        hud.onOpenStats = { [weak self] in self?.statsOpens += 1 }
    }

    func completion(target: SessionNavigationTarget?, sessionID: String = "session") -> IslandAlert {
        .completion(SessionCompletion(sessionID: sessionID, vendor: "Codex",
                                      turnID: UUID().uuidString, task: "Test", model: "model", startedAt: nil,
                                      completedAt: Date(), navigationTarget: target))
    }

    func session(target: SessionNavigationTarget?, apply: Bool = true) {
        store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: [
            LiveSession(id: "session", agentId: "codex-model:model", task: "Test", terminal: nil,
                        startedAt: Date(), pctOfWindow: nil, tokensIn: 0, tokensOut: 0,
                        navigationTarget: target)
        ]))
        if apply { hud.apply(animated: false) }
    }

    func close() {
        hud.close()
        defaults.removePersistentDomain(forName: domain)
    }
}
