import Foundation
import SQLite3
import XCTest
@testable import AgentHUDCore

final class AntigravityConversationTests: XCTestCase, @unchecked Sendable {
    private let epoch: UInt64 = 1_788_800_000
    private var start: Date { date(0) }

    func testVisibleInputAndFinalReplyExcludeGeneratedContextReasoningAndTools() throws {
        let url = try conversation()
        try database(url) { db in
            var input = string(1, "fallback query") + string(2, "visible user response")
            input += message(3, string(1, "ignored item"))
            input += message(3, message(2, string(1, "private generated context")))
            try insert(db, index: 0, kind: 14, at: 0, payload: message(19, input))
            var planning = string(1, "visible pre-tool note") + string(3, "private reasoning")
            planning += message(7, string(2, "private tool") + string(3, "private arguments"))
            planning += number(12, 10)
            try insert(db, index: 1, kind: 15, at: 1, completed: 2, payload: message(20, planning))
            // Non-message payloads are not decoded, even if they contain bytes that are not valid protobuf.
            try insert(db, index: 2, kind: 19, at: 2, payload: [0xff])
            var final = string(1, "visible final reply") + string(3, "private final reasoning")
            final += string(8, "internal modified response") + number(12, 2)
            try insert(db, index: 3, kind: 15, at: 3, completed: 4, payload: message(20, final))
            let items = message(3, string(1, "first ")) + message(3, string(1, "second"))
            try insert(db, index: 4, kind: 14, at: 5, payload: message(19, string(1, "fallback") + items))
            try insert(db, index: 5, kind: 15, at: 6, completed: 7, payload: response("item reply"))
            try insert(db, index: 6, kind: 14, at: 8, payload: message(19, string(1, "query-only prompt")))
        }

        let turns = read(url)
        XCTAssertEqual(turns.map(\.turnID), ["step-0", "step-4", "step-6"])
        XCTAssertEqual(turns.map(\.prompt), ["visible user response", "first second", "query-only prompt"])
        XCTAssertEqual(turns.map(\.reply), ["visible final reply", "item reply", nil])
        XCTAssertEqual(turns.map(\.startedAt), [date(0), date(5), date(8)])
        XCTAssertEqual(turns.map(\.endedAt), [date(4), date(7), nil])
    }

    func testToolGenerationDoesNotEndTurnAndFinishNeedsNoPayload() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: 0, payload: prompt("working prompt"))
            var planner = string(1, "visible progress") + number(12, 10)
            planner += message(7, string(2, "fixture_tool"))
            try insert(db, index: 1, kind: 15, at: 1, completed: 2, payload: message(20, planner))
        }
        let running = try XCTUnwrap(read(url).first)
        XCTAssertNil(running.reply, "a tool-requesting generation is not the final reply")
        XCTAssertNil(running.endedAt)

        try database(url) { db in try insert(db, index: 2, kind: 2, at: 3, completed: 4, payload: nil) }
        let finished = try XCTUnwrap(read(url).first)
        XCTAssertEqual(finished.reply, "visible progress")
        XCTAssertEqual(finished.endedAt, date(4))
        XCTAssertEqual(finished.turnID, running.turnID)
    }

    func testInterruptedGenerationKeepsItsVisibleTextAndRecordedEnd() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: 0, payload: prompt("interrupted prompt"))
            try insert(db, index: 1, kind: 15, status: 12, at: 1, completed: 2,
                       payload: message(20, string(1, "visible interrupted text")))
        }
        let turn = try XCTUnwrap(read(url).first)
        XCTAssertEqual(turn.reply, "visible interrupted text")
        XCTAssertEqual(turn.endedAt, date(2))
    }

    func testNewUserBoundaryDoesNotInventCompletionOfPreviousTurn() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: 0, payload: prompt("first prompt"))
            let incomplete = message(20, string(1, "incomplete text") + number(12, 1))
            try insert(db, index: 1, kind: 15, at: 1, completed: 2, payload: incomplete)
            try insert(db, index: 2, kind: 14, at: 3, payload: prompt("next prompt"))
            try insert(db, index: 3, kind: 15, at: 4, completed: 5, payload: response("next reply"))
        }
        let turns = read(url)
        XCTAssertEqual(turns.count, 2)
        XCTAssertNil(turns[0].reply)
        XCTAssertNil(turns[0].endedAt, "the next prompt's date is not the previous turn's completion date")
        XCTAssertEqual(turns[1].reply, "next reply")
        XCTAssertEqual(turns[1].endedAt, date(5))
    }

    func testFinalReplyWithNoCompletionTimeKeepsUnknownEndAndUnknownStopDoesNotEnd() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: 0, payload: prompt("known final"))
            try insert(db, index: 1, kind: 15, at: 1, payload: response("final with unknown time"))
            try insert(db, index: 2, kind: 14, at: 3, payload: prompt("unknown stop"))
            let unknown = message(20, string(1, "unconfirmed final") + number(12, 125))
            try insert(db, index: 3, kind: 15, at: 4, completed: 5, payload: unknown)
        }
        let turns = read(url)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].reply, "final with unknown time")
        XCTAssertNil(turns[0].endedAt, "a planner creation timestamp is not its completion timestamp")
        XCTAssertNil(turns[1].reply)
        XCTAssertNil(turns[1].endedAt)
    }

    func testLatestTurnsArePagedBeforeApplyingRetentionAndKeepStableIDs() throws {
        let url = try conversation()
        try database(url) { db in
            try sql(db, "BEGIN")
            for index in 0..<140 {
                try insert(db, index: Int64(index * 2), kind: 14, at: UInt64(index * 3), payload: prompt("prompt \(index)"))
                try insert(db, index: Int64(index * 2 + 1), kind: 15, at: UInt64(index * 3 + 1),
                           completed: UInt64(index * 3 + 2), payload: response("reply \(index)"))
            }
            try sql(db, "COMMIT")
        }
        // 260 message rows exceed one SQL page. Latest turns, rather than the first page, are authoritative.
        let paged = read(url, limit: 130)
        XCTAssertEqual(paged.count, 130)
        XCTAssertEqual(paged.first?.turnID, "step-20")
        XCTAssertEqual(paged.last?.turnID, "step-278")
        XCTAssertEqual(paged.last?.reply, "reply 139")
        let retained = read(url, since: date(390), limit: 130)
        XCTAssertEqual(retained.map(\.turnID), (130..<140).map { "step-\($0 * 2)" })

        try database(url) { db in
            try insert(db, index: 280, kind: 14, at: 420, payload: prompt("new prompt"))
        }
        let updated = read(url, limit: 130)
        XCTAssertEqual(updated.dropLast().map(\.turnID), paged.dropFirst().map(\.turnID))
        XCTAssertEqual(updated.last?.turnID, "step-280")
    }

    func testWALIncludesCommittedMessagesAndExcludesAnUncommittedReply() throws {
        let url = try conversation()
        try database(url) { writer in
            try sql(writer, "PRAGMA journal_mode=WAL")
            try sql(writer, "PRAGMA wal_autocheckpoint=0")
            try insert(writer, index: 0, kind: 14, at: 0, payload: prompt("committed prompt"))
            try sql(writer, "BEGIN")
            try insert(writer, index: 1, kind: 15, at: 1, completed: 2, payload: response("uncommitted reply"))
            let before = try XCTUnwrap(read(url).first)
            XCTAssertEqual(before.prompt, "committed prompt")
            XCTAssertNil(before.reply)
            try sql(writer, "COMMIT")
            let after = try XCTUnwrap(read(url).first)
            XCTAssertEqual(after.reply, "uncommitted reply")
            XCTAssertEqual(after.endedAt, date(2))
            XCTAssertEqual(after.turnID, before.turnID)
        }
    }

    func testInvalidAndClearedStepsCannotBecomeConversationMessages() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: 0, payload: prompt("visible prompt"))
            try insert(db, index: 1, kind: 14, status: 4, at: 1, payload: [0xff])
            try insert(db, index: 2, kind: 15, status: 5, at: 2, payload: [0xff])
            try insert(db, index: 3, kind: 15, at: 3, completed: 4, payload: response("visible reply"))
        }
        let turns = read(url)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.prompt, "visible prompt")
        XCTAssertEqual(turns.first?.reply, "visible reply")
    }

    func testMalformedMessageOrUnsupportedFormatDoesNotPublishPartialHistory() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: 0, payload: prompt("valid prompt"))
            try insert(db, index: 1, kind: 15, at: 1, completed: 2, payload: response("valid reply"))
            try insert(db, index: 2, kind: 14, at: 3, payload: [0x9a, 0x01, 0x05, 0x0a])
        }
        XCTAssertTrue(read(url).isEmpty)
        try database(url) { db in
            try sql(db, "DELETE FROM steps WHERE idx = 2")
            try insert(db, index: 2, kind: 14, at: 3, payload: prompt("unsupported prompt"), format: 1)
        }
        XCTAssertTrue(read(url).isEmpty)
    }

    func testSessionIdentityAndMissingTimestampsAreNeverInferred() throws {
        let url = try conversation()
        try database(url) { db in
            try insert(db, index: 0, kind: 14, at: nil, payload: prompt("undated prompt"))
            try insert(db, index: 1, kind: 15, at: 1, completed: 2, payload: response("unpaired reply"))
        }
        XCTAssertTrue(read(url).isEmpty)
        XCTAssertTrue(AntigravityConversation.turns(atPath: url.path, sessionID: "antigravity:other", since: start, limit: 100).isEmpty)
        XCTAssertTrue(read(url, limit: 0).isEmpty)
        try database(url) { db in
            try insert(db, index: 2, kind: 14, at: 3, payload: prompt("dated prompt"))
        }
        let prefixed = read(url)
        let native = AntigravityConversation.turns(atPath: url.path, sessionID: "conversation", since: start, limit: 100)
        XCTAssertEqual(native, prefixed)
        XCTAssertEqual(prefixed.first?.prompt, "dated prompt")
        XCTAssertNil(prefixed.first?.reply)
    }

    private func date(_ offset: UInt64) -> Date { Date(timeIntervalSince1970: Double(epoch + offset)) }
    private func read(_ url: URL, since: Date? = nil, limit: Int = 100) -> [ConversationTurn] {
        AntigravityConversation.turns(atPath: url.path, sessionID: "antigravity:conversation", since: since ?? start, limit: limit)
    }
    private func conversation() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.db")
        try database(url) { db in
            try sql(db, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, metadata BLOB, step_payload BLOB, step_format INTEGER)")
        }
        return url
    }
    private func database(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        try body(database)
    }
    private func sql(_ database: OpaquePointer, _ query: String) throws {
        guard sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK else { throw ProviderFailure.local }
    }
    private func insert(_ database: OpaquePointer, index: Int64, kind: Int, status: Int = 3,
                        at: UInt64?, completed: UInt64? = nil, payload: [UInt8]?, format: Int = 0) throws {
        var metadata = at.map { message(1, number(1, epoch + $0)) } ?? []
        if let completed { metadata += message(8, number(1, epoch + completed)) }
        let hex = metadata.map { String(format: "%02x", $0) }.joined()
        let body = payload.map { "X'" + $0.map { String(format: "%02x", $0) }.joined() + "'" } ?? "NULL"
        try sql(database, "INSERT INTO steps VALUES (\(index), \(kind), \(status), X'\(hex)', \(body), \(format))")
    }
    private func prompt(_ text: String) -> [UInt8] { message(19, message(3, string(1, text))) }
    private func response(_ text: String) -> [UInt8] { message(20, string(1, text) + number(12, 2)) }
    private func string(_ field: UInt64, _ text: String) -> [UInt8] { message(field, Array(text.utf8)) }
    private func number(_ field: UInt64, _ value: UInt64) -> [UInt8] { varint(field << 3) + varint(value) }
    private func message(_ field: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        varint((field << 3) | 2) + varint(UInt64(bytes.count)) + bytes
    }
    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 127)
            value >>= 7
            if value > 0 { byte |= 128 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }
}
