import AgentHUDCore
import XCTest
@testable import AgentHUDDesktop

/// How a request waiting for its user behaves on the island, next to news that expires on its own.
@MainActor
final class PermissionAlertTests: XCTestCase {
    private func request(_ id: String) -> PermissionRequest {
        PermissionRequest(id: id, source: .claude, sessionID: "s", toolName: "Bash",
                          summary: "Remove the build output", detail: "rm -rf .build", cwd: "/Users/me/agent-hud", at: Date())
    }

    private func completion() -> IslandAlert {
        .completion(SessionCompletion(sessionID: "s", vendor: "Claude", turnID: "t", task: "Build the dashboard",
                                      model: "opus", startedAt: nil, completedAt: Date()))
    }

    func testARequestHoldsTheIslandAndKeepsRepliesBesideIt() async throws {
        let queue = IslandAlertQueue()
        var expired = 0
        queue.onExpire = { expired += 1 }
        let reply = completion()

        XCTAssertTrue(queue.show(.permission(request("a")), inUsagePanel: false))
        XCTAssertFalse(queue.show(reply, inUsagePanel: false), "a reply joins the list without replacing the question")
        XCTAssertFalse(queue.show(.permission(request("b")), inUsagePanel: false), "a second request waits its turn")
        XCTAssertEqual(queue.sessionEvents.map(\.id), ["a", reply.id, "b"])
        let quota = IslandAlert.quota(QuotaAlert.preview(.reset, agent: DemoData.agents[0]))
        XCTAssertFalse(queue.show(quota, inUsagePanel: false))
        XCTAssertFalse(queue.contains(id: quota.id), "quota news still stays out of an approval queue")

        try await Task.sleep(for: IslandAlertQueue.visibleDuration + .milliseconds(200))
        XCTAssertEqual(expired, 0, "a request is not news: it stays until it is answered or withdrawn")
        XCTAssertEqual(queue.current?.alert.id, "a")

        // The oldest unanswered request comes next, with the reply still waiting in the list.
        let next = queue.remove(id: "a")
        XCTAssertTrue(next.removed)
        XCTAssertEqual(next.next?.id, "b")
        XCTAssertTrue(queue.contains(id: reply.id))
        let second = try XCTUnwrap(next.next)
        XCTAssertTrue(queue.show(second, inUsagePanel: true))
        XCTAssertFalse(try XCTUnwrap(queue.current).inUsagePanel)
        XCTAssertEqual(queue.remove(id: "b").next?.id, reply.id)
    }

    func testSessionEventsShareAStandaloneSurfaceWithoutSharingPersistence() throws {
        let permission = IslandAlert.permission(request("a"))
        let reply = completion()
        XCTAssertTrue(permission.isPersistent)
        XCTAssertFalse(reply.isPersistent, "A finished reply must not become an unresolved approval")
        for event in [permission, reply] {
            let queue = IslandAlertQueue()
            XCTAssertTrue(event.isSessionEvent)
            XCTAssertEqual(event.detailWidth, 470)
            XCTAssertEqual(try XCTUnwrap(event.detailInsets).top, 32)
            XCTAssertTrue(queue.show(event, inUsagePanel: true))
            XCTAssertFalse(try XCTUnwrap(queue.current).inUsagePanel,
                           "An open usage panel cannot turn a session event into an inline message")
        }
    }

    func testSelectingAReplyKeepsThePermissionWaitingAndUsesTheEventSurface() throws {
        let queue = IslandAlertQueue()
        let quota = IslandAlert.quota(QuotaAlert.preview(.reset, agent: DemoData.agents[0]))
        let permission = IslandAlert.permission(request("a"))
        let reply = completion()
        XCTAssertTrue(queue.show(quota, inUsagePanel: true))
        XCTAssertFalse(queue.show(permission, inUsagePanel: true))
        XCTAssertFalse(queue.show(reply, inUsagePanel: true))
        XCTAssertEqual(queue.pendingIDs, [permission.id, reply.id])
        XCTAssertTrue(queue.promote(id: reply.id))
        XCTAssertEqual(queue.current?.alert.id, reply.id)
        XCTAssertFalse(try XCTUnwrap(queue.current).inUsagePanel,
                       "Selecting an event must not inherit the previous quota card's inline surface")
        XCTAssertEqual(queue.questions.map(\.id), [permission.id])
        XCTAssertEqual(queue.sessionEvents.map(\.id), [reply.id, permission.id])
        XCTAssertEqual(queue.dismiss()?.id, permission.id)
    }

    func testAWithdrawnRequestIsTakenOutOfTheQueueWhereverItIs() {
        let queue = IslandAlertQueue()
        _ = queue.show(.permission(request("a")), inUsagePanel: false)
        _ = queue.show(.permission(request("b")), inUsagePanel: false)

        let waiting = queue.remove(id: "b")
        XCTAssertTrue(waiting.removed)
        XCTAssertNil(waiting.next, "the one on screen is still the one on screen")
        XCTAssertEqual(queue.current?.alert.id, "a")

        XCTAssertFalse(queue.remove(id: "gone").removed)
        let showing = queue.remove(id: "a")
        XCTAssertTrue(showing.removed)
        XCTAssertNil(showing.next)
        XCTAssertNil(queue.current)
    }

    func testBringingAStackedRequestForwardSwapsItWithTheOneOnScreen() {
        let queue = IslandAlertQueue()
        _ = queue.show(.permission(request("a")), inUsagePanel: false)
        _ = queue.show(.permission(request("b")), inUsagePanel: false)
        _ = queue.show(.permission(request("c")), inUsagePanel: false)

        XCTAssertTrue(queue.promote(id: "c"), "the card the user picked becomes the card being decided")
        XCTAssertEqual(queue.current?.alert.id, "c")
        XCTAssertFalse(queue.promote(id: "c"), "the one already in front cannot be brought forward again")
        XCTAssertFalse(queue.promote(id: "gone"))

        // The one it replaced keeps its place in the pile rather than going to the back of it.
        XCTAssertTrue(queue.promote(id: "b"))
        XCTAssertEqual(queue.current?.alert.id, "b")
        let answered = queue.remove(id: "b")
        XCTAssertEqual(answered.next?.id, "a", "answering hands over to the oldest one still waiting")
    }

    func testARequestOutlivesItsDisplayAndMovesToTheScreenItIsPickedOn() throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.permission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let controller = IslandController(store: UsageStore(provider: DemoUsageProvider(), settings: settings), settings: settings)
        defer { controller.rebuild(keys: [], screens: []) }
        controller.rebuild(keys: ["screen:a", "screen:b"], screens: [])
        let a = try XCTUnwrap(controller.huds["screen:a"]), b = try XCTUnwrap(controller.huds["screen:b"])
        a.present(.permission(request("first")))
        a.present(.permission(request("second")))
        b.present(.permission(request("third")))

        b.selectRequest("second")
        XCTAssertFalse(a.holds("second"), "a request picked on another screen leaves the one it arrived on")
        XCTAssertEqual(b.questions.map(\.id), ["second", "third"], "and is the card being decided")

        controller.rebuild(keys: ["screen:b"], screens: [])
        XCTAssertEqual(Set(b.questions.map(\.id)), ["first", "second", "third"], "a display that goes away hands on its requests")
        controller.present(.permission(request("first")))
        XCTAssertEqual(b.questions.filter { $0.id == "first" }.count, 1, "a request is shown once")
    }

    func testNewsStillExpiresOnItsOwn() async throws {
        let queue = IslandAlertQueue()
        var expired = 0
        queue.onExpire = { expired += 1 }
        XCTAssertTrue(queue.show(completion(), inUsagePanel: false))
        try await Task.sleep(for: IslandAlertQueue.visibleDuration + .milliseconds(200))
        XCTAssertEqual(expired, 1)
    }

    func testAQuestionIsAnsweredWithWhatWasChosenAndSkippedQuestionsAreLeftOut() {
        let one = PermissionQuestion(question: "Push now?", options: [.init(label: "Push"), .init(label: "Wait")])
        let many = PermissionQuestion(question: "Which pages?", options: [.init(label: "Channels"), .init(label: "Documents")],
                                      multiSelect: true)
        let draft = QuestionDraft()
        XCTAssertEqual(draft.answers(for: [one, many]), [:])

        draft.pick(1, of: 0, in: one)
        draft.pick(0, of: 0, in: one)
        XCTAssertEqual(draft.answer(0, of: one), .init(selected: ["Push"]), "a single answer replaces the one before it")
        draft.type("Push tomorrow", of: 0, in: one)
        XCTAssertEqual(draft.answer(0, of: one), .init(custom: "Push tomorrow"), "writing one's own answer sets the offered ones aside")
        draft.type("  ", of: 0, in: one)
        XCTAssertNil(draft.answer(0, of: one), "blank words are no answer")
        draft.pick(1, of: 0, in: one)
        draft.chooseOwn(of: 0, in: one)
        XCTAssertNil(draft.answer(0, of: one), "going into the field sets the offered answer aside")
        draft.pick(1, of: 0, in: one)

        draft.pick(1, of: 1, in: many)
        draft.pick(0, of: 1, in: many)
        draft.type("Settings", of: 1, in: many)
        XCTAssertEqual(draft.answers(for: [one, many]),
                       ["Push now?": .init(selected: ["Wait"]),
                        "Which pages?": .init(selected: ["Channels", "Documents"], custom: "Settings")],
                       "several answers keep the order they were offered in, the user's own words last")
        draft.pick(0, of: 1, in: many)
        XCTAssertEqual(draft.answer(1, of: many), .init(selected: ["Documents"], custom: "Settings"), "picking again takes it back")
        draft.skip(1)
        XCTAssertEqual(draft.answers(for: [one, many]), ["Push now?": .init(selected: ["Wait"])], "a skipped question is left out")
    }

    func testQuestionAnswersKeepIdentityChoicesAndCustomWordsSeparate() {
        let one = PermissionQuestion(id: "one", question: "Choose", options: [.init(label: "CSV, JSON")])
        let two = PermissionQuestion(id: "two", question: "Choose", options: [.init(label: "A")], multiSelect: true)
        let draft = QuestionDraft()
        draft.pick(0, of: 0, in: one)
        draft.pick(0, of: 1, in: two)
        draft.type("A, but later", of: 1, in: two)
        XCTAssertEqual(draft.answers(for: [one, two]), [
            "one": .init(selected: ["CSV, JSON"]),
            "two": .init(selected: ["A"], custom: "A, but later"),
        ])
    }
}

/// What counts as pointing at the HUD, which decides whether a waiting request can be answered at all.
@MainActor
final class IslandHoverRegionTests: XCTestCase {
    private let marks = CGRect(x: 900, y: 1300, width: 200, height: 32)
    private let wings = CGRect(x: 640, y: 1300, width: 720, height: 38)
    private let panel = CGRect(x: 700, y: 1000, width: 470, height: 340)

    func testAnEventIsHoveredAnywhereItDraws() {
        // The wings carry the project, the state and the count; pointing at any of them opens the card.
        XCTAssertEqual(ScreenHUD.hoverRegion(open: false, panel: panel, alert: wings, marks: marks), wings)
        XCTAssertTrue(ScreenHUD.hoverRegion(open: false, panel: panel, alert: wings, marks: marks)
            .contains(CGPoint(x: 700, y: 1310)), "the left wing is part of the reminder")
        XCTAssertFalse(marks.contains(CGPoint(x: 700, y: 1310)), "and it is outside the silhouette the HUD idles at")
    }

    func testWithoutAnEventOnlyTheMarksAreHovered() {
        XCTAssertEqual(ScreenHUD.hoverRegion(open: false, panel: panel, alert: nil, marks: marks), marks,
                       "a collapsed HUD must let clicks through everywhere it is not drawing")
    }

    func testAnsweringTheLastRequestClosesTheIslandRatherThanOpeningThePanel() {
        // The pointer is on the button that was just pressed; the usage panel is not what that press asked for.
        XCTAssertTrue(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: false, pointerInside: true))
        XCTAssertTrue(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: false, pointerInside: false))
        // A request answered as a row inside the panel leaves the panel where the user had it.
        XCTAssertFalse(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: true, pointerInside: true))
        XCTAssertTrue(ScreenHUD.closesAfterLastAlert(wasInUsagePanel: true, pointerInside: false))
    }

    func testTheWindowKeepsASurfaceUnderThePointerWhileTheCardShrinks() {
        // Opening a shorter request, or answering one and losing its row, makes the card shorter than the pointer
        // that asked for it. The window holds its height so the pointer still stands on the HUD; what it holds is
        // transparent, because the card is drawn at its own size.
        XCTAssertEqual(ScreenHUD.heldWindowHeight(card: 200, floor: 320, pointerInside: true), 320)
        // Growing is free, and raises the floor with it.
        XCTAssertEqual(ScreenHUD.heldWindowHeight(card: 420, floor: 320, pointerInside: true), 420)
        // The pointer gone, the window is the card again — nothing invisible is left behind.
        XCTAssertEqual(ScreenHUD.heldWindowHeight(card: 200, floor: 320, pointerInside: false), 200)
    }

    func testAnOpenPanelOwnsItsWholeFrame() {
        XCTAssertEqual(ScreenHUD.hoverRegion(open: true, panel: panel, alert: wings, marks: marks), panel)
    }

    func testOptionIsNeededOnlyToStartTheHover() {
        // Passing over the closed HUD leaves it closed; the same hover with Option down opens it.
        XCTAssertFalse(ScreenHUD.opensOnHover(counted: false, open: false, pointerInside: true, typing: false,
                                              requiresOption: true, optionDown: false))
        XCTAssertTrue(ScreenHUD.opensOnHover(counted: false, open: false, pointerInside: true, typing: false,
                                             requiresOption: true, optionDown: true))
        // A tap is enough: once the hover counts, letting go of Option does not take it back.
        XCTAssertTrue(ScreenHUD.opensOnHover(counted: true, open: false, pointerInside: true, typing: false,
                                             requiresOption: true, optionDown: false), "a tap opens the panel")
        // An open panel stays under a pointer that came back before it closed, and leaving still closes it.
        XCTAssertTrue(ScreenHUD.opensOnHover(counted: false, open: true, pointerInside: true, typing: false,
                                             requiresOption: true, optionDown: false))
        XCTAssertFalse(ScreenHUD.opensOnHover(counted: true, open: true, pointerInside: false, typing: false,
                                              requiresOption: true, optionDown: false))
    }
}
