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

    /// The same logs read by a later version that skips `x` lines.
    private enum RequestsWithoutX: TailLog {
        static let source = Requests.source
        static let summaryKey = Requests.summaryKey
        static let version = 2
        static func summary(for url: URL) -> [String] { [] }
        static func ingest(_ lines: Data, into keys: inout [String]) -> [UsageLedger.Event] {
            Requests.ingest(Data(lines.split(separator: 0x0A).filter { $0.first != UInt8(ascii: "x") }.joined(separator: [0x0A])), into: &keys)
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

    func testALogOfAnotherStateVersionIsReadAgainAndReplacesItsUsage() async throws {
        let root = try directory(), ledger = UsageLedger.inMemory(), now = Date()
        let log = root.appendingPathComponent("s.log"), expired = root.appendingPathComponent("expired.log")
        try "a 10\nx 5\n".write(to: log, atomically: true, encoding: .utf8)
        try "b 1\nx 2\n".write(to: expired, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: log.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-UsageLedger.retention - 86400)], ofItemAtPath: expired.path)
        _ = await TailLogStore<Requests>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }.index(since: .distantPast, timeBudget: 5)
        var total = try await tokens(ledger)
        XCTAssertEqual(total, 18)

        let upgraded = TailLogStore<RequestsWithoutX>(roots: [root], ledger: ledger, watchesChanges: false) { _ in true }
        let pass = await upgraded.index(since: now.addingTimeInterval(-7 * 86400), timeBudget: 5)
        XCTAssertEqual(pass.logs.count, 0, "both logs are older than the cutoff")
        XCTAssertEqual(pass.filesRead, 1, "a log the ledger no longer holds usage of is left as it is")
        total = try await tokens(ledger)
        XCTAssertEqual(total, 13, "the log was read again from the start and replaced what the other version counted")
        let again = await upgraded.index(since: now.addingTimeInterval(-7 * 86400), timeBudget: 5)
        XCTAssertEqual(again.filesRead, 0)
    }

    func testAListingStoppedByItsLimitKeepsTheFilesItDidNotReach() throws {
        let root = try directory()
        for name in ["a", "b", "c"] { try "a 1\n".write(to: root.appendingPathComponent("\(name).log"), atomically: true, encoding: .utf8) }
        let files = LogFiles(roots: [root], watchesChanges: false, limit: 3) { _ in true }
        XCTAssertFalse(files.refresh(now: Date()).truncated)
        for name in ["d", "e"] { try "a 1\n".write(to: root.appendingPathComponent("\(name).log"), atomically: true, encoding: .utf8) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.log"))
        XCTAssertTrue(files.refresh(now: Date()).truncated)
        let names = Set(files.files.keys.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertTrue(names.isSuperset(of: ["b.log", "c.log"]), "a file past the limit is not gone")
        XCTAssertFalse(names.contains("a.log"), "a file that is gone leaves")
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
