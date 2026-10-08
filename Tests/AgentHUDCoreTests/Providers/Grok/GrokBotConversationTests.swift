import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokBotConversationTests: XCTestCase {
    func testOnlyVisibleUserAndTextRepliesAreReturnedWithoutFabricatedCompletion() throws {
        let f = try fixture()
        var reasoning = f.prompt("reasoning", sequence: 2, text: "Excluded reasoning")
        reasoning["role"] = "developer"
        let tool: [String: Any] = ["id": "tool", "seq": 3, "kind": "tool-call", "content": "Excluded tool"]
        let widget: [String: Any] = ["id": "widget", "seq": 4, "kind": "send-message", "message": ["type": "widget", "content": "Excluded widget"]]
        try f.writeTranscript([f.prompt("p", sequence: 1), reasoning, tool, widget,
            f.reply("r1", sequence: 5), f.reply("r2", sequence: 6, text: "Second visible paragraph")])
        XCTAssertEqual(read(f), [.init(turnID: "p@1", prompt: "Synthetic prompt", reply: "Synthetic reply\n\nSecond visible paragraph",
                                      startedAt: f.now.addingTimeInterval(-30), endedAt: nil)])
    }

    func testAssistantMessageIsVisibleButSuppressedAndRoutedBodiesAreNot() throws {
        let f = try fixture()
        var visible = f.prompt("assistant", sequence: 2, text: "Visible assistant message")
        visible["role"] = "assistant"
        var hidden = f.prompt("hidden", sequence: 3, text: "Hidden body")
        hidden["role"] = "assistant"; hidden["suppressed"] = false // Native suppression is any non-null marker.
        var routed = f.prompt("routed", sequence: 4, text: "Internal agent mail")
        routed["role"] = "assistant"; routed["fromAgent"] = ["id": "other-agent"]
        try f.writeTranscript([f.prompt("user", sequence: 1), visible, hidden, routed, f.reply("reply", sequence: 5)])
        XCTAssertEqual(read(f).first?.reply, "Visible assistant message\n\nSynthetic reply")
    }

    func testSequenceGapKeepsPromptButDoesNotJoinReplyAcrossMissingHistory() throws {
        let f = try fixture()
        try f.writeTranscript([f.reply("orphan", sequence: 7), f.prompt("p", sequence: 8),
            f.reply("after-gap", sequence: 10), f.prompt("next", sequence: 11, text: "Next prompt"), f.reply("answer", sequence: 12)])
        let turns = read(f)
        XCTAssertEqual(turns.map(\.prompt), ["Synthetic prompt", "Next prompt"])
        XCTAssertNil(turns[0].reply)
        XCTAssertEqual(turns[1].reply, "Synthetic reply")
    }

    func testRequestMismatchOrUnknownSequenceDoesNotClaimAReply() throws {
        let f = try fixture()
        try f.writeTranscript([f.prompt("p", sequence: 1), f.reply("other", sequence: 2, request: "another-request"),
            f.prompt("unknown", sequence: nil), f.reply("not-proven", sequence: nil)])
        XCTAssertEqual(read(f).map(\.reply), [nil, nil])
    }

    func testIdentityIncludesSequenceAndNativeDuplicateIdentityRejectsReplica() throws {
        let f = try fixture()
        try f.writeTranscript([f.prompt("same", sequence: 1), f.reply("reply", sequence: 2),
            f.prompt("same", sequence: 3, text: "Another prompt"), f.reply("reply", sequence: 4)])
        XCTAssertEqual(read(f).map(\.turnID), ["same@1", "same@3"])
        let duplicate = f.prompt("same", sequence: 1)
        try f.writeTranscript([duplicate, duplicate])
        XCTAssertTrue(read(f).isEmpty)
    }

    func testExactAccountSessionAndReplicaAreRequired() throws {
        let f = try fixture()
        try f.writeTranscript([f.prompt("p", sequence: 1)])
        XCTAssertEqual(read(f).count, 1)
        XCTAssertTrue(GrokBotConversation.turns(at: f.transcript, sessionID: "grok:\(f.agent)", since: .distantPast, limit: 10, now: f.now).isEmpty)
        let other = try f.writeTranscript([f.prompt("other", sequence: 1)], agent: "other-agent")
        XCTAssertTrue(GrokBotConversation.turns(at: other, sessionID: f.sessionID, since: .distantPast, limit: 10, now: f.now).isEmpty)
        try f.writeAccount("other-account")
        XCTAssertTrue(read(f).isEmpty)
        try f.writeTranscript([f.prompt("new", sequence: 1)], account: "other-account")
        XCTAssertTrue(read(f).isEmpty)
        try f.writeAccount(nil)
        XCTAssertTrue(read(f).isEmpty)
    }

    func testCacheRetentionSchemaAndRecentLimitDoNotSuggestCompleteHistory() throws {
        let f = try fixture()
        let rows = [f.prompt("old", sequence: 30, at: -60), f.reply("old-reply", sequence: 31),
                    f.prompt("new", sequence: 32, at: -10), f.reply("new-reply", sequence: 33)]
        try f.writeTranscript(rows)
        XCTAssertEqual(read(f, since: f.now.addingTimeInterval(-20)).map(\.turnID), ["new@32"])
        XCTAssertEqual(read(f, limit: 1).map(\.turnID), ["new@32"])
        XCTAssertTrue(read(f, limit: 0).isEmpty)
        try f.writeTranscript(rows, persistedAt: f.now.addingTimeInterval(-GrokBotCache.retention - 1))
        XCTAssertTrue(read(f).isEmpty)
        try f.writeTranscript(rows, schema: 2)
        XCTAssertTrue(read(f).isEmpty)
    }

    private func read(_ f: GrokBotCacheFixture, since: Date = .distantPast, limit: Int = 10) -> [ConversationTurn] {
        GrokBotConversation.turns(at: f.transcript, sessionID: f.sessionID, since: since, limit: limit, now: f.now)
    }

    private func fixture() throws -> GrokBotCacheFixture {
        let fixture = try GrokBotCacheFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }
}
