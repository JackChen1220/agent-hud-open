import Foundation
import XCTest
@testable import AgentHUDCore

final class CompletionHooksTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1788800000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func json(_ value: [String: Any]) throws -> ProviderJSON {
        try .read(JSONSerialization.data(withJSONObject: value))
    }
    /// A file standing in for an installed app's executable: one that exists is an installation still here.
    private func app(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("\(name).app/Contents/MacOS/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    func testGrokNamespacedCompletionSurvivesUsageLogPrecedence() async throws {
        let root = try directory(), session = root.appendingPathComponent("sessions/%2Ffixture/s")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let logs: [[String: Any]] = [
            ["method": "session/update", "params": ["sessionId": "s", "_meta": ["eventId": "user", "promptId": "p", "agentTimestampMs": 1788800000000],
                "update": ["sessionUpdate": "user_message_chunk"]]],
            ["method": "_x.ai/session/update", "params": ["sessionId": "s", "_meta": ["eventId": "done", "agentTimestampMs": 1788800002000],
                "update": ["sessionUpdate": "turn_completed", "prompt_id": "p", "stop_reason": "end_turn",
                    "usage": ["inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 60, "modelUsage": ["grok-test": [:]]]]]]
        ]
        let lines = try (logs + [logs[1]]).map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        try #"{"ts":"2026-09-07T16:53:21Z","sid":"s","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100,"completion_tokens":20,"cached_prompt_tokens":60}}"#
            .write(to: root.appendingPathComponent("unified.jsonl"), atomically: true, encoding: .utf8)
        let result = await AdditionalLocalStore(source: .grok, roots: [root]).index(since: now.addingTimeInterval(-10))
        let item = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(item.events.count, 1)
        XCTAssertEqual(item.events[0].input, 40)
        XCTAssertEqual(item.completions.count, 1)
        XCTAssertEqual(item.completions[0].model, "grok-test")
        XCTAssertEqual(item.completions[0].startedAt, now)
        XCTAssertEqual(item.turns.count, 1)
        XCTAssertEqual(item.turns[0].turnID, "p")
        XCTAssertEqual(item.turns[0].state, .completed)
    }

    func testGrokAbortedOrUnknownStopDoesNotNotify() throws {
        for reason in ["cancelled", "max_tokens", "error", ""] {
            let directory = try directory(), url = directory.appendingPathComponent("updates.jsonl")
            let payload = try json(["method": "_x.ai/session/update", "params": ["sessionId": directory.lastPathComponent,
                "_meta": ["eventId": "done", "agentTimestampMs": 1788800000000],
                "update": ["sessionUpdate": "turn_completed", "stop_reason": reason]]])
            try JSONEncoder().encode(payload).write(to: url)
            let item = try XCTUnwrap(GrokSessions.read(url).sessions.first)
            XCTAssertTrue(item.completions.isEmpty)
            XCTAssertEqual(item.turns.first?.state, .ended)
        }
    }

    func testAntigravityStopRecordsEveryFinishedTurn() throws {
        let directory = try directory()
        // The payload agy sends when a turn ends; `executionNum` stays 0 on every turn of a conversation.
        var payload: [String: Any] = ["conversationId": "s", "executionNum": 0, "terminationReason": "NO_TOOL_CALL",
            "fullyIdle": true, "error": "", "modelName": "gemini-test", "workspacePaths": ["/work/project"]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try CompletionHooks.record(source: .antigravity, data: data, now: now, directory: directory)
        try CompletionHooks.record(source: .antigravity, data: data, now: now.addingTimeInterval(5), directory: directory)
        let events = try CompletionHooks.read(source: .antigravity, since: now.addingTimeInterval(-1), directory: directory)
            .sorted { $0.completedAt < $1.completedAt }
        XCTAssertEqual(events.map(\.completedAt), [now, now.addingTimeInterval(5)])
        XCTAssertEqual(events[0].sessionID, "antigravity:s")
        XCTAssertEqual(events[0].model, "gemini-test")
        XCTAssertEqual(events[0].task, "Antigravity · project")
        payload["fullyIdle"] = false
        XCTAssertNil(try CompletionHooks.completion(source: .antigravity, payload: json(payload), now: now))
        payload["fullyIdle"] = true
        for reason in ["model_stop", "ERROR", "USER_CANCELED", "MAX_INVOCATIONS", "HALTED_STEP"] {
            payload["terminationReason"] = reason
            XCTAssertNil(try CompletionHooks.completion(source: .antigravity, payload: json(payload), now: now))
        }
        payload["terminationReason"] = "NO_TOOL_CALL"; payload["error"] = "failure"
        XCTAssertNil(try CompletionHooks.completion(source: .antigravity, payload: json(payload), now: now))
    }

    func testCursorInboxStripsUnneededDataAndDoesNotReplay() async throws {
        let directory = try directory()
        var payload: [String: Any] = ["conversation_id": "s", "generation_id": "g", "hook_event_name": "stop",
            "status": "completed", "model_id": "cursor-test", "workspace_roots": ["/work/project"],
            "user_email": "private@example.test", "prompt": "private fixture text"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try CompletionHooks.record(source: .cursor, data: data, now: now, directory: directory)
        try CompletionHooks.record(source: .cursor, data: data, now: now.addingTimeInterval(1), directory: directory)
        let events = try CompletionHooks.read(source: .cursor, since: now.addingTimeInterval(-1), directory: directory)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].completedAt, now)
        let saved = try String(contentsOf: directory.appendingPathComponent("cursor/\(events[0].id).json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("private"))
        for state in ["error", "aborted", "unknown"] {
            payload["status"] = state
            XCTAssertNil(try CompletionHooks.completion(source: .cursor, payload: json(payload), now: now))
        }
        let provider = AdditionalUsageProvider(source: .cursor, readQuota: { throw ProviderFailure.login("Cursor") },
            readSessions: { _ in ProviderSessions() }, history: QuotaHistoryStore(),
            readCompletions: { _ in events }, clock: { self.now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let agents: [AgentDescriptor] = []
        var tracker = IslandEventTracker(startedAt: now.addingTimeInterval(-1))
        XCTAssertEqual(tracker.update(report: report, agents: agents, now: now).completions.count, 1)
        XCTAssertTrue(tracker.update(report: report, agents: agents, now: now).completions.isEmpty)
        var restarted = IslandEventTracker(startedAt: now.addingTimeInterval(1))
        XCTAssertTrue(restarted.update(report: report, agents: agents, now: now.addingTimeInterval(2)).completions.isEmpty)
    }

    func testAutomaticInstallationDoesNotTakeOverAnotherHost() throws {
        let home = try directory()
        let first = try app("Agent HUD", in: home), second = try app("Agent HUD Open", in: home)
        for source in CompletionHooks.Source.allCases {
            try CompletionHooks.configure(source, enabled: true, executable: first, home: home)
            let file = source.configuration(home: home)
            let original = try Data(contentsOf: file)
            XCTAssertThrowsError(try CompletionHooks.configure(source, enabled: true, executable: second, home: home))
            XCTAssertEqual(try Data(contentsOf: file), original)
            try CompletionHooks.configure(source, enabled: false, executable: second, home: home)
            XCTAssertEqual(try Data(contentsOf: file), original, "\(source): switching hooks off leaves another installation's handler")
            try CompletionHooks.configure(source, enabled: true, executable: second, home: home, replacingExisting: true)
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(second.path))
        }
    }

    func testAHandlerLeftWhereTheAppNoLongerRunsIsReplacedOrRemoved() throws {
        let apps = try directory()
        let current = try app("Agent HUD", in: apps.appendingPathComponent("Applications"))
        // A translocated copy still mounted, the disk image the app came on, and an app since deleted.
        let left = [try app("Agent HUD", in: apps.appendingPathComponent("AppTranslocation/5D1C/d")),
                    URL(fileURLWithPath: "/Volumes/Agent HUD/Agent HUD.app/Contents/MacOS/Agent HUD"),
                    apps.appendingPathComponent("Trash/Agent HUD.app/Contents/MacOS/Agent HUD")]
        for source in CompletionHooks.Source.allCases {
            let home = try directory(), file = source.configuration(home: home)
            let ours = { HookCommand.make(executable: $0, arguments: "--completion-hook \(source.rawValue)") }
            for old in left {
                for enabled in [false, true] {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(ProviderJSON.object(try source.format.updating([:], command: ours(old), keeping: [])))
                        .write(to: file)
                    try CompletionHooks.configure(source, enabled: enabled, executable: current, home: home)
                    XCTAssertEqual(source.format.commands(in: try ProviderFiles.json(file).objectValue ?? [:]), enabled ? [ours(current)] : [],
                                   "\(source): the handler left at \(old.path) is \(enabled ? "replaced" : "removed")")
                }
            }
            let installed = try Data(contentsOf: file)
            XCTAssertThrowsError(try CompletionHooks.configure(source, enabled: true, executable: left[1], home: home,
                                                               replacingExisting: true))
            XCTAssertEqual(try Data(contentsOf: file), installed, "\(source): an app running from its disk image adds nothing")
        }
    }

    func testInstallationPreservesOtherHooksAndCanBeRemoved() throws {
        let home = try directory(), executable = home.appendingPathComponent("Agent's HUD.app/Contents/MacOS/Agent HUD")
        for source in CompletionHooks.Source.allCases {
            let url = source.configuration(home: home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = source == .cursor ? #"{"version":1,"hooks":{"stop":[{"command":"other-command"}],"sessionStart":[]}}"#
                : #"{"other-hook":{"Stop":[{"command":"other-command"}]}}"#
            try original.write(to: url, atomically: true, encoding: .utf8)
            for _ in 0..<2 { try CompletionHooks.configure(source, enabled: true, executable: executable, home: home) }
            XCTAssertTrue(CompletionHooks.isInstalled(source, home: home))
            let installed = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(installed.contains("other-command"))
            XCTAssertEqual(installed.components(separatedBy: "--completion-hook").count, 2)
            try CompletionHooks.configure(source, enabled: false, executable: executable, home: home)
            XCTAssertFalse(CompletionHooks.isInstalled(source, home: home))
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("other-command"))
        }
    }
}
