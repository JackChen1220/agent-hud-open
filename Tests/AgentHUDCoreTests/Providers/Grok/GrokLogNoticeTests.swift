import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokLogNoticeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testCoexistingFormatsWarnOnlyForOldUsageBeforeNewInference() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inference = try readInference(in: directory, session: "same", at: start)
        for offset in [-1.0, 0, 1] {
            let old = try readUpdates(in: directory, session: "same", at: start.addingTimeInterval(offset))
            XCTAssertEqual(old.events.first?.timestamp, start.addingTimeInterval(offset), "millisecond updates become Date values")
            XCTAssertEqual(inference.events.first?.timestamp, start, "ISO8601 inference records use the same Date time base")
            XCTAssertEqual(GrokSessions.notice(merging: [old, inference]) != nil, offset < 0,
                "coexistence alone is no evidence of lost older usage; an equal timestamp is covered")
        }
    }

    func testOlderUsageFromAnotherSessionDoesNotWarn() {
        let old = session("old", path: "/old/updates.jsonl", at: start.addingTimeInterval(-1))
        let inference = session("new", path: "/logs/unified.jsonl", at: start)
        XCTAssertNil(GrokSessions.notice(merging: [old, inference]))
    }

    func testEarliestInferenceAcrossFilesOwnsTheCoverageBoundary() {
        let old = session("same", path: "/same/updates.jsonl", at: start.addingTimeInterval(1))
        let early = session("same", path: "/first/unified.jsonl", at: start)
        let later = session("same", path: "/second/unified.jsonl", at: start.addingTimeInterval(2))
        XCTAssertNil(GrokSessions.notice(merging: [old, later, early]))
        XCTAssertNil(GrokSessions.notice(merging: [early, later, old]))
    }

    func testContextOnlyNoticeStaysVisibleWithoutAnOverlapWarning() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("same")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("updates.jsonl")
        try write(["method": "session/update", "params": ["sessionId": "same",
            "_meta": ["agentTimestampMs": RecordCoding.milliseconds(start), "totalTokens": 1234],
            "update": ["sessionUpdate": "agent_message_chunk"]]], to: url)
        let old = try GrokSessions.read(url)
        XCTAssertNotNil(old.notice)
        XCTAssertTrue(old.sessions[0].events.isEmpty, "context size is not usage")
        XCTAssertNil(GrokSessions.notice(merging: old.sessions + [session("same", path: "/logs/unified.jsonl", at: start)]))
    }

    func testInvalidUsageStillFailsTheRead() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("same")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("updates.jsonl")
        try write(["method": "session/update", "params": ["sessionId": "same",
            "_meta": ["agentTimestampMs": RecordCoding.milliseconds(start)],
            "update": ["sessionUpdate": "turn_completed", "usage": ["inputTokens": 1, "outputTokens": 1, "cachedReadTokens": 2]]]], to: url)
        XCTAssertThrowsError(try GrokSessions.read(url))
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readUpdates(in directory: URL, session: String, at date: Date) throws -> ProviderSession {
        let folder = directory.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("updates.jsonl")
        try write(["method": "session/update", "params": ["sessionId": session,
            "_meta": ["eventId": "old", "agentTimestampMs": RecordCoding.milliseconds(date)],
            "update": ["sessionUpdate": "turn_completed", "usage": ["inputTokens": 10, "outputTokens": 1]]]], to: url)
        return try XCTUnwrap(GrokSessions.read(url).sessions.first)
    }

    private func readInference(in directory: URL, session: String, at date: Date) throws -> ProviderSession {
        let url = directory.appendingPathComponent("unified.jsonl")
        try write(["sid": session, "ts": ISO8601DateFormatter().string(from: date), "msg": "shell.turn.inference_done",
            "ctx": ["prompt_tokens": 10, "completion_tokens": 1]], to: url)
        return try XCTUnwrap(GrokSessions.read(url).sessions.first)
    }

    private func session(_ rawID: String, path: String, at date: Date) -> ProviderSession {
        var session = ProviderSession(id: "grok:" + rawID, title: "Fixture", path: path, client: "Grok CLI")
        session.events = [.init(id: path, model: "fixture", timestamp: date, input: 10, output: 1)]
        return session
    }

    private func write(_ json: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)
        try data.write(to: url)
    }
}
