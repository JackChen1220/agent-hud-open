import XCTest
@testable import AgentHUDCore

final class ResetCreditGrantTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = ProviderAccount.identified(provider: "Codex", user: "me@example.com", workspace: "personal")!

    func testFirstReadingIsSilentAndARiseNotifiesOnceWithTheNewCredit() {
        var tracker = ResetCreditTracker()
        XCTAssertTrue(feed(&tracker, ids: ["a"], elapsed: 0).isEmpty)
        let grants = feed(&tracker, ids: ["a", "b"], elapsed: 300)
        XCTAssertEqual(grants.map(\.added), [1])
        XCTAssertEqual(grants.first?.newCredits.map(\.id), ["b"])
        XCTAssertEqual(grants.first?.credits.availableCount, 2)
        XCTAssertTrue(feed(&tracker, ids: ["a", "b"], elapsed: 600).isEmpty)
    }

    func testUsingOrLosingAResetIsNotAnEventAndTheNextRiseStillIs() {
        var tracker = ResetCreditTracker()
        _ = feed(&tracker, ids: ["a", "b"], elapsed: 0)
        XCTAssertTrue(feed(&tracker, ids: ["b"], elapsed: 300).isEmpty)
        XCTAssertEqual(feed(&tracker, ids: ["b", "c", "d"], elapsed: 600).map(\.added), [2])
    }

    func testCountOnlyReadingsNotifyWithoutNamingCreditsAndKeepTheEarlierList() {
        var tracker = ResetCreditTracker()
        _ = feed(&tracker, ids: ["a"], elapsed: 0)
        let countOnly = feed(&tracker, count: 2, elapsed: 300)
        XCTAssertEqual(countOnly.map(\.added), [1])
        XCTAssertEqual(countOnly.first?.newCredits, [])
        XCTAssertEqual(feed(&tracker, ids: ["a", "b", "c"], elapsed: 600).first?.newCredits.map(\.id), ["b", "c"])
    }

    func testFailedStaleRepeatedAndFutureReadingsConfirmNothing() {
        var tracker = ResetCreditTracker()
        _ = feed(&tracker, ids: [], elapsed: 0)
        XCTAssertTrue(feed(&tracker, ids: ["a"], elapsed: 300, notice: "failed").isEmpty)
        XCTAssertTrue(tracker.update(report: report(ids: ["a"], count: 1, elapsed: 300, notices: ["Codex": "failed"]),
                                     now: start.addingTimeInterval(300)).isEmpty)
        XCTAssertTrue(feed(&tracker, ids: ["a"], elapsed: 300, now: 2400).isEmpty)
        XCTAssertTrue(feed(&tracker, ids: ["a"], elapsed: 300, now: 120).isEmpty, "a reading from the future is not a grant")
        XCTAssertTrue(feed(&tracker, ids: ["a"], elapsed: 0).isEmpty)
        XCTAssertEqual(feed(&tracker, ids: ["a"], elapsed: 2520).map(\.added), [1])
    }

    func testSigningBackInStartsWithANewBaseline() {
        var tracker = ResetCreditTracker()
        _ = feed(&tracker, ids: [], elapsed: 0)
        XCTAssertTrue(feed(&tracker, ids: [], elapsed: 300, isCurrent: false).isEmpty)
        XCTAssertTrue(feed(&tracker, ids: ["a"], elapsed: 600).isEmpty)
    }

    func testIslandUpdateCarriesTheGrantAndPreviewHasFreshIdentity() {
        var island = IslandEventTracker(startedAt: start)
        _ = island.update(report: report(ids: [], count: 0, elapsed: 0), agents: [], now: start)
        let update = island.update(report: report(ids: ["a"], count: 1, elapsed: 300), agents: [], now: start.addingTimeInterval(300))
        XCTAssertEqual(update.resetCreditGrants.map(\.account.account.id), [account.id])
        let preview = ResetCreditGrant.preview(now: start)
        XCTAssertTrue(preview.isPreview)
        XCTAssertEqual(preview.newCredits.count, preview.added)
        XCTAssertNotEqual(preview.id, ResetCreditGrant.preview(now: start).id)
    }

    private func report(ids: [String]?, count: Int, elapsed: Double, isCurrent: Bool = true, notice: String? = nil,
                        notices: [String: String] = [:]) -> UsageReport {
        let credits = CodexResetCredits(availableCount: count, credits: ids?.enumerated().map { index, id in
            .init(id: id, expiresAt: start.addingTimeInterval(Double(index + 1) * 86400).timeIntervalSince1970)
        })
        let observation = AccountObservation(account: account, observedAt: start.addingTimeInterval(elapsed), isCurrent: isCurrent,
                                             quotaNotice: notice, resetCredits: credits)
        return UsageReport(generatedAt: start.addingTimeInterval(elapsed), snapshots: [], sessions: [],
                           sourceNotices: notices, accounts: ["Codex": [observation]])
    }

    private func feed(_ tracker: inout ResetCreditTracker, ids: [String]? = nil, count: Int? = nil, elapsed: Double,
                      now: Double? = nil, isCurrent: Bool = true, notice: String? = nil) -> [ResetCreditGrant] {
        tracker.update(report: report(ids: ids, count: count ?? ids?.count ?? 0, elapsed: elapsed, isCurrent: isCurrent, notice: notice),
                       now: start.addingTimeInterval(now ?? elapsed))
    }
}
