import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokBotSessionsTests: XCTestCase {
    func testRosterUsesAccountScopedIdentityNativeTargetAndOnlyMetadata() throws {
        let fixture = try fixture()
        _ = try fixture.writeRoster()
        try fixture.writeTranscript([fixture.prompt("p", sequence: 1)])
        let report = try GrokBotSessions.read(fixture.roster)
        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(session.id, fixture.sessionID)
        XCTAssertTrue(session.id.hasPrefix("grok-bot:"))
        XCTAssertEqual(session.title, "Synthetic conversation")
        XCTAssertEqual(session.client, "Grok Bot")
        XCTAssertEqual(session.path, fixture.transcript.path)
        XCTAssertEqual(session.navigationTarget, .grokBotAgent(id: fixture.agent))
        XCTAssertEqual(session.startedAt, fixture.now.addingTimeInterval(-60))
        XCTAssertEqual(session.lastActivity, fixture.now.addingTimeInterval(-10))
        XCTAssertNil(session.workspace)
        XCTAssertTrue(session.events.isEmpty)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertTrue(session.completions.isEmpty)
        XCTAssertNotNil(report.notice)
    }

    func testSwitchingOrSigningOutDoesNotReadPreviousAccountsRoster() throws {
        let fixture = try fixture()
        _ = try fixture.writeRoster()
        XCTAssertEqual(try GrokBotSessions.read(fixture.roster).sessions.count, 1)
        try fixture.writeAccount("fixture-other")
        XCTAssertTrue(try GrokBotSessions.read(fixture.roster).sessions.isEmpty)
        let other = try fixture.writeRoster(account: "fixture-other")
        XCTAssertNotEqual(try GrokBotSessions.read(other).sessions.first?.id, fixture.sessionID)
        try fixture.writeAccount(nil)
        XCTAssertTrue(try GrokBotSessions.read(other).sessions.isEmpty)
    }

    func testRelatedDirectoryInvalidatesRosterWhenReplicaAppearsAndAccountChanges() throws {
        let fixture = try fixture()
        _ = try fixture.writeRoster()
        var files = WholeFileStore<ProviderSessions>(listings: [.init(name: "Grok Bot", files: LogFiles(roots: [fixture.directory],
            watchesChanges: false, skips: { GrokBotSessions.skips($0) }, accepts: { GrokBotSessions.accepts($0) }),
            related: { GrokBotSessions.related($0) }, parse: { url, _ in try GrokBotSessions.read(url) })])
        XCTAssertNil(files.index(since: .distantPast).files.first?.parsed.sessions.first?.path)
        XCTAssertTrue(GrokBotSessions.related(fixture.roster).contains(fixture.directory))
        try fixture.writeTranscript([fixture.prompt("p", sequence: 1)])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: fixture.directory.path)
        let path = try XCTUnwrap(files.index(since: .distantPast).files.first?.parsed.sessions.first?.path)
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), fixture.transcript.resolvingSymlinksInPath())
        try fixture.writeAccount("fixture-other")
        XCTAssertTrue(files.index(since: .distantPast).files.flatMap(\.parsed.sessions).isEmpty)
    }

    func testLongKeysUseNativeKblobFramingAndTamperedHeaderIsRejected() throws {
        let fixture = try fixture()
        let account = String(repeating: "synthetic.account.", count: 20)
        try fixture.writeAccount(account)
        let roster = try fixture.writeRoster(account: account)
        XCTAssertEqual(roster.pathExtension, "kblob")
        XCTAssertTrue(GrokBotSessions.accepts(roster))
        XCTAssertEqual(try GrokBotSessions.read(roster).sessions.count, 1)
        var data = try Data(contentsOf: roster)
        let newline = try XCTUnwrap(data.firstIndex(of: 10))
        data.replaceSubrange(data.startIndex..<newline, with: Data("\"sand.wrong-key\"".utf8))
        try data.write(to: roster)
        XCTAssertFalse(GrokBotSessions.accepts(roster))
    }

    func testOnlyRosterFilesAreIndexedAndInvalidNativeIDsDoNotCreateTargets() throws {
        let fixture = try fixture()
        let roster = try fixture.writeRoster(rows: [["id": "invalid/id", "title": "Invalid"], ["id": fixture.agent, "name": "Fallback"]])
        try fixture.writeTranscript([])
        XCTAssertTrue(GrokBotSessions.accepts(roster))
        XCTAssertFalse(GrokBotSessions.accepts(fixture.transcript))
        XCTAssertFalse(GrokBotSessions.accepts(GrokBotCache.url(for: GrokBotCache.accountKey, in: fixture.directory)))
        XCTAssertEqual(try GrokBotSessions.read(roster).sessions.map(\.title), ["Fallback"])
        XCTAssertEqual(GrokBotCache.rosterKey(account: "fixture.account|one"), "sand.client.slice.account.fixture%2Eaccount%7Cone.roster.last-roster")
        XCTAssertEqual(GrokBotCache.url(for: "sand.a", in: fixture.directory).lastPathComponent, "onqw4zbome.blob")
    }

    private func fixture() throws -> GrokBotCacheFixture {
        let fixture = try GrokBotCacheFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }
}
