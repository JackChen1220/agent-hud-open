import XCTest
@testable import AgentHUDCore

final class SessionCompletionTests: XCTestCase {
    func testFinalParagraphIsSelectedBeforeClippingTheAnswer() {
        let reply = String(repeating: "Earlier explanation. ", count: 200) + "\n \n最后一段第一行。\n最后一段第二行。\n\n  "
        XCTAssertEqual(completion(message: reply).message, "最后一段第一行。\n最后一段第二行。")
        XCTAssertNil(completion(message: " \n\n ").message)
        XCTAssertNil(completion(message: nil).message)
        XCTAssertEqual(completion(message: "First paragraph.\r\n\r\nLast paragraph.\r\nSecond line.\r\n").message,
                       "Last paragraph.\nSecond line.")
        let long = completion(message: "Earlier paragraph.\r\n\r\n" + String(repeating: "末", count: 700) + "\r\n")
        XCTAssertEqual(long.message, String(repeating: "末", count: 599) + "…")
    }

    func testReplyPreviewIsNotPersistedAndChangingTitlePreservesIdentity() throws {
        var value = completion(message: "Earlier explanation.\n\nFinal result.")
        let id = value.id
        value.task = "The conversation's saved title"
        XCTAssertEqual(value.id, id)
        let data = try JSONEncoder().encode(value)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["message"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Final result."))
        let restored = try JSONDecoder().decode(SessionCompletion.self, from: data)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.task, value.task)
        XCTAssertNil(restored.message)
    }

    private func completion(message: String?) -> SessionCompletion {
        SessionCompletion(sessionID: "session", vendor: "Codex", turnID: "turn", task: "Initial question",
                          model: "gpt-6.1-sol", startedAt: nil, completedAt: Date(), message: message)
    }
}
