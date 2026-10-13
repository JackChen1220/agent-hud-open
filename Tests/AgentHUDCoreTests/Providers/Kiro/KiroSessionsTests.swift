import Foundation
import XCTest
@testable import AgentHUDCore

final class KiroSessionsTests: XCTestCase, @unchecked Sendable {
    private let start = Date(timeIntervalSince1970: 1790658000) // 2026-09-29 05:00 UTC

    private func snapshot(_ turns: String) -> String {
        """
        {"session_id":"fixture-session","cwd":"/fixture/project","title":"CLI fixture",
         "created_at":"2026-09-29T05:00:00Z","updated_at":"2026-09-29T06:00:00Z",
         "session_state":{"conversation_metadata":{"user_turn_metadatas":[\(turns)]}}}
        """
    }

    private func turn(time: String = "2026-09-29T05:30:00Z", input: Int = 0, credits: String = "[{\"value\":0.4,\"unit\":\"credit\"},{\"value\":0.2,\"unit\":\"credit\"}]") -> String {
        """
        {"end_timestamp":"\(time)","model":"claude-sonnet-4.6","input_token_count":\(input),
         "output_token_count":0,"cache_read_input_token_count":0,"cache_write_input_token_count":0,
         "context_usage_percentage":50,"metering_usage":\(credits),"turn_duration":{"secs":10},
         "end_reason":"UserTurnEnd","result":{"Ok":{"id":"response"}}}
        """
    }

    private func parse(_ text: String) throws -> ProviderSessions {
        try KiroSessions.parse(ProviderJSON.read(Data(text.utf8)), path: "/fixture/session.json")
    }

    func testZeroCountersPreserveCreditsAndCompletionsWithoutInventingTokens() throws {
        let result = try parse(snapshot(turn() + "," + turn()))
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertTrue(session.events.isEmpty)
        XCTAssertEqual(session.localUsage.count, 1)
        XCTAssertEqual(try XCTUnwrap(session.localUsage.first?.credits), 0.6, accuracy: 0.000001)
        XCTAssertFalse(session.localUsage[0].hasTokenCounts)
        XCTAssertEqual(session.completions.count, 1)
        XCTAssertEqual(session.turns.first?.state, .completed)
        XCTAssertNil(result.notice)
        XCTAssertFalse(KiroSessions.accepts(URL(fileURLWithPath: "/fixture/session.jsonl")))
    }

    func testReportedTokensSeparateCacheReadsAndIncludeCacheWrites() throws {
        let text = turn(input: 100).replacingOccurrences(of: "\"output_token_count\":0", with: "\"output_token_count\":30")
            .replacingOccurrences(of: "\"cache_read_input_token_count\":0", with: "\"cache_read_input_token_count\":500")
            .replacingOccurrences(of: "\"cache_write_input_token_count\":0", with: "\"cache_write_input_token_count\":20")
        let event = try XCTUnwrap(parse(snapshot(text)).sessions.first?.events.first)
        XCTAssertEqual(event.input, 120)
        XCTAssertEqual(event.output, 30)
        XCTAssertEqual(event.cacheRead, 500)
        XCTAssertEqual(event.cacheWrite, 20)
    }

    func testAbsentAndInvalidCreditsAreUnknownNotZero() throws {
        for value in ["[]", "[{\"unit\":\"credit\",\"value\":-1}]", "[{\"unit\":\"credit\",\"value\":0.4},{\"unit\":\"credit\"}]"] {
            let result = try parse(snapshot(turn(credits: value)))
            XCTAssertNil(result.sessions[0].localUsage[0].credits)
        }
        let zero = try parse(snapshot(turn(credits: "[{\"unit\":\"credit\",\"value\":0}]")))
        XCTAssertEqual(zero.sessions[0].localUsage[0].credits, 0)
        let invalid = try parse(snapshot(turn(input: -1)))
        XCTAssertTrue(invalid.sessions[0].events.isEmpty)
        XCTAssertNotNil(invalid.notice)
    }

    func testFileUpdatesRefreshReportAndLedgerWithoutDoubleCounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        try Data(snapshot(turn(input: 100)).utf8).write(to: file)
        let local = AdditionalLocalStore(source: .kiro, roots: [root])
        let ledger = UsageLedger.inMemory()
        let now = start.addingTimeInterval(7200)
        let provider = AdditionalUsageProvider(source: .kiro, readQuota: { ProviderQuota() },
            readSessions: { await local.index(since: $0) }, history: QuotaHistoryStore(), clock: { now },
            watchedDirectories: [root], ledger: ledger)
        let first = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(first.sessions[0].localUsage?.count, 1)
        XCTAssertEqual(first.consumers.first?.vendor, "Kiro")
        try Data(snapshot(turn(input: 100) + "," + turn(time: "2026-09-29T05:50:00Z", input: 200)).utf8).write(to: file, options: .atomic)
        let second = try await provider.fetchUsage(agents: [], historyHours: 24)
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(second.sessions[0].localUsage?.count, 2)
        let buckets = await provider.usage(since: start)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.tokensIn }, 300)
        XCTAssertEqual(UsageChanges(from: first, to: second).sessions, ["kiro:fixture-session"])
        let records = LocalUsageRecord.records(in: second.sessions + second.sessions,
            during: DateInterval(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3000)))
        XCTAssertEqual(records.count, 1, "Half-open range and deduplication")
        let decoded = try JSONDecoder().decode(UsageReport.self, from: JSONEncoder().encode(second.restartCopy))
        XCTAssertEqual(decoded.sessions.first?.localUsage, second.sessions.first?.localUsage)
    }

    func testLocalCLIMetadataProbe() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUD_KIRO_CLI_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only local CLI metadata probe")
        }
        let local = AdditionalLocalStore(source: .kiro)
        var result = await local.index(since: Date().addingTimeInterval(-30 * 86400))
        for _ in 0..<20 where result.indexing != nil {
            result = await local.index(since: Date().addingTimeInterval(-30 * 86400))
        }
        XCTAssertNil(result.indexing)
        XCTAssertNil(result.notice)
        XCTAssertFalse(result.sessions.isEmpty)
        let records = result.sessions.flatMap(\.localUsage)
        XCTAssertFalse(records.isEmpty)
        print("Kiro CLI metadata probe: \(result.sessions.count) sessions, \(records.count) completed turns, \(records.filter(\.hasTokenCounts).count) turns with tokens, \(records.compactMap(\.credits).reduce(0, +)) recorded credits")
    }

    func testCreditsRemainAvailableForThirtyDaySelector() async throws {
        let now = start.addingTimeInterval(7200)
        let old = now.addingTimeInterval(-20 * 86400)
        var session = ProviderSession(id: "kiro:older", title: "Older local turn", client: "Kiro CLI", startedAt: old, lastActivity: old)
        session.localUsage = [.init(id: "older-turn", timestamp: old, model: "model", credits: 2, hasTokenCounts: false)]
        let fixture = session
        let provider = AdditionalUsageProvider(source: .kiro, readQuota: { ProviderQuota() },
            readSessions: { since in
                XCTAssertLessThan(since, old)
                return ProviderSessions(sessions: [fixture])
            }, history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchUsage(agents: [], historyHours: 169)
        XCTAssertEqual(LocalUsageRecord.records(in: report.sessions,
            during: DateInterval(start: now.addingTimeInterval(-30 * 86400), end: now)).first?.credits, 2)
    }
}
