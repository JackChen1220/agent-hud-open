import XCTest
@testable import AgentHUDCore

final class LedgerFileStoreTests: XCTestCase, @unchecked Sendable {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// One `<key> <tokens>` line per request.
    private enum Requests: TailLog {
        static let source = "fixture"
        static let summaryKey = "keys"
        static let version = 1
        static func summary(for url: URL) -> [String] { [] }
        static func ingest(_ lines: Data, into keys: inout [String]) -> [UsageLedger.Event] {
            lines.split(separator: 0x0A).map { line in
                let parts = String(decoding: line, as: UTF8.self).split(separator: " ").map(String.init)
                keys.append(parts[0])
                return UsageLedger.Event(key: parts[0], timestamp: LedgerFileStoreTests.base, agentId: "fixture-model:m", tokensIn: Int(parts[1])!, tokensOut: 0)
            }
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tokens(_ ledger: UsageLedger, source: String = Requests.source) async throws -> Int {
        try await ledger.buckets(since: .distantPast, source: source).reduce(0) { $0 + $1.tokensIn }
    }

    func testMissingLogLeavesTheLedgerWhileAListedUnreadableLogStays() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory()
        let kept = root.appendingPathComponent("kept.log"), gone = root.appendingPathComponent("gone.log")
        try "a 10\n".write(to: kept, atomically: true, encoding: .utf8)
        try "b 5\n".write(to: gone, atomically: true, encoding: .utf8)
        let store = TailLogStore<Requests>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        _ = await store.index(since: .distantPast, timeBudget: 5)
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 15)
        try "a 10\nc 1\n".write(to: kept, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: kept.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path) }
        try FileManager.default.removeItem(at: gone)
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertEqual(pass.failures.count, 1)
        total = try await tokens(ledger)
        XCTAssertEqual(total, 10, "the deleted log leaves; the unreadable one keeps what it recorded")
        let files = try await ledger.fileStates(source: Requests.source)
        XCTAssertEqual(files.keys.map { URL(fileURLWithPath: $0).lastPathComponent }, ["kept.log"])
    }

    func testRolledBackPassIsReadAndWrittenAgain() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory()
        try "a 10\n".write(to: root.appendingPathComponent("s.log"), atomically: true, encoding: .utf8)
        let store = TailLogStore<Requests>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        await ledger.beginPass()
        _ = await store.index(since: .distantPast, timeBudget: 5)
        await ledger.rollBackPass()
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 0)
        let pass = await store.index(since: .distantPast, timeBudget: 5)
        XCTAssertTrue(pass.reloaded)
        total = try await tokens(ledger)
        XCTAssertEqual(total, 10, "an unchanged log is read again once the ledger lost its position")
    }

    func testLongLineMakesProgressAcrossBudgetsAndWaitsForNewline() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory()
        let file = root.appendingPathComponent("long.log")
        let key = String(repeating: "x", count: TailLogStore<Requests>.chunkSize * 2 + 123)
        try (key + " 7").write(to: file, atomically: true, encoding: .utf8)
        let store = TailLogStore<Requests>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        for _ in 0..<3 {
            let pass = await store.index(since: .distantPast, timeBudget: 0)
            XCTAssertLessThanOrEqual(pass.bytesRead, TailLogStore<Requests>.chunkSize)
        }
        let idle = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(idle.bytesRead, 0, "an incomplete final line waits for an append")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nb 3\n".utf8))
        try handle.close()
        let appended = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(appended.bytesRead, 5, "the previous prefix is not read again")
        let total = try await tokens(ledger)
        XCTAssertEqual(total, 10)
        let path = try XCTUnwrap(appended.logs.first?.path)
        XCTAssertEqual(store.entry(path)?.summary.map(\.count), [key.count, 1])
    }

    func testLongLineCompletesWithOneChunkPerPass() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory()
        let file = root.appendingPathComponent("long.log")
        let key = String(repeating: "x", count: TailLogStore<Requests>.chunkSize * 2 + 123)
        try ("a 2\n" + key + " 7\nb 3\n").write(to: file, atomically: true, encoding: .utf8)
        let store = TailLogStore<Requests>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        for _ in 0..<2 {
            let pass = await store.index(since: .distantPast, timeBudget: 0)
            XCTAssertEqual(pass.pending, 1)
            XCTAssertEqual(pass.bytesRead, TailLogStore<Requests>.chunkSize)
        }
        let complete = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(complete.pending, 0, "the long line must not trap indexing at its start")
        let total = try await tokens(ledger)
        XCTAssertEqual(total, 12)
        let idle = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(idle.bytesRead, 0)
    }

    func testPartialLongLineIsDiscardedAfterRewriteAndRollback() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory()
        let file = root.appendingPathComponent("long.log")
        let key = String(repeating: "x", count: TailLogStore<Requests>.chunkSize + 123)
        try (key + " 7\n").write(to: file, atomically: true, encoding: .utf8)
        let store = TailLogStore<Requests>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        await ledger.beginPass()
        _ = await store.index(since: .distantPast, timeBudget: 0)
        await ledger.rollBackPass()
        let reloaded = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertTrue(reloaded.reloaded)
        XCTAssertEqual(reloaded.pending, 1)
        let completed = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(completed.pending, 0)
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 7)
        try (key + " 7\n" + key).write(to: file, atomically: true, encoding: .utf8)
        _ = await store.index(since: .distantPast, timeBudget: 0)
        try "b 3\n".write(to: file, atomically: true, encoding: .utf8)
        let rewritten = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(rewritten.pending, 0)
        total = try await tokens(ledger)
        XCTAssertEqual(total, 3, "a stale partial line cannot survive a file rewrite")
    }

    func testCodexLongToolOutputIsSkippedWhileFollowingUsageIsRead() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory()
        let file = root.appendingPathComponent("rollout-long.jsonl")
        let header = #"{"timestamp":"2026-10-07T08:00:00Z","type":"response_item","payload":{"type":"function_call_output","output":""#
        let body = String(repeating: "x", count: TailLogStore<CodexRollouts>.chunkSize * 2 + 123)
        let meta = #"{"timestamp":"2026-10-07T08:00:00Z","type":"session_meta","payload":{"id":"long-output"}}"#
        let usage = #"{"timestamp":"2026-10-07T08:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"output_tokens":3}}}}"#
        try (meta + "\n" + header + body + "\"}}\n" + usage + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(CodexRollouts.keepsLongLine(prefix: Data(header.utf8)))
        XCTAssertFalse(CodexRollouts.keepsLongLine(prefix: Data(#"{ "type" : "response_item", "payload": {"#.utf8)))
        XCTAssertTrue(CodexRollouts.keepsLongLine(prefix: Data(usage.utf8)))
        XCTAssertTrue(CodexRollouts.keepsLongLine(prefix: Data(#"{"payload":{"type":"response_item"},"type":"event_msg"}"#.utf8)),
                      "a nested type never identifies the outer envelope")
        let store = TailLogStore<CodexRollouts>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        for _ in 0..<3 { _ = await store.index(since: .distantPast, timeBudget: 0) }
        let idle = await store.index(since: .distantPast, timeBudget: 0)
        XCTAssertEqual(idle.pending, 0)
        XCTAssertEqual(idle.bytesRead, 0)
        let total = try await tokens(ledger, source: CodexRollouts.source)
        XCTAssertEqual(total, 7)
    }

    func testSessionsOfAMissingFileLeaveUnlessAListedFileHoldsThemAndRollbacksAreWrittenAgain() async throws {
        let ledger = UsageLedger.inMemory(), recorder = SessionLedger(source: "fixture", ledger: ledger), window = Date(timeIntervalSince1970: 0)
        func session(_ id: String, _ tokens: Int) -> (id: String, events: [UsageEvent]) {
            (id, [UsageEvent(timestamp: Self.base, agentId: "fixture-model:m", tokensIn: tokens, tokensOut: 0, eventID: id)])
        }
        await recorder.record(files: ListedFiles(paths: ["/a", "/b"], sessions: ["/a": ["s1"], "/b": ["s2"]]), revision: 1, window: window) {
            [session("s1", 10), session("s2", 5)]
        }
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 15)
        // `/a` was deleted; `/b` is still listed but has no parse at hand, as after a restart with an unreadable file.
        await recorder.record(files: ListedFiles(paths: ["/b"]), revision: 2, window: window) { [] }
        total = try await tokens(ledger)
        XCTAssertEqual(total, 5)
        await ledger.beginPass()
        let added = ListedFiles(paths: ["/b", "/c"], sessions: ["/c": ["s3"]])
        await recorder.record(files: added, revision: 3, window: window) { [session("s3", 7)] }
        await ledger.rollBackPass()
        await recorder.record(files: added, revision: 3, window: window) { [session("s3", 7)] }
        total = try await tokens(ledger)
        XCTAssertEqual(total, 12, "what the rolled-back pass wrote is written again")
        await recorder.record(files: ListedFiles(paths: []), revision: 3, window: window) { [] }
        total = try await tokens(ledger)
        XCTAssertEqual(total, 0)
    }
}
