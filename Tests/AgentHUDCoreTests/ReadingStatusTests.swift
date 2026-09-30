import XCTest
@testable import AgentHUDCore

/// One status and one assessment answer for every surface that weighs a reading. The grid compares them with the rules
/// each surface applied on its own: the row's level, the quota alerts' baseline, the reset credits' baseline, the account
/// header and the balance events.
final class ReadingStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = ProviderAccount.identified(provider: "Codex", user: "a@example.com", workspace: nil)!
    private let pool = BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "scope", evidence: .account, entitlement: "kimi-code")

    /// Where a window's notice comes from.
    private enum Notice: CaseIterable {
        case none, account, vendorQuota, vendorDisplay, legacyVendor, poolAccount, poolVendor
    }

    func testTheAssessmentAgreesWithEachSurfacesRuleOverAGrid() {
        var checked = 0
        for notice in Notice.allCases {
            for isCurrent in [true, false] {
                for age: TimeInterval in [60, 1799, 1800, -60] {
                    for resetIn: TimeInterval? in [nil, -60, 7200] {
                        for remaining in [100, 50, 10, 0.5, 0] {
                            let (report, agent, observation) = reading(notice, isCurrent: isCurrent, age: age, resetIn: resetIn,
                                                                       remaining: remaining)
                            let name = "\(notice) current \(isCurrent) age \(age) reset \(resetIn.map { "\($0)" } ?? "none") remaining \(remaining)"
                            let snapshot = report.snapshot(for: agent.id)!
                            let quotaNotice = Self.quotaNotice(report, agent)
                            let window = report.assess(.window(agent), now: now)
                            XCTAssertEqual(window.status.reason, quotaNotice, name)
                            XCTAssertEqual(window.isCurrentAccount, report.isCurrent(agent), name)
                            // The row's level.
                            let level = report.isCurrent(agent) && quotaNotice == nil
                                && (snapshot.resetAt ?? .distantFuture) > now && now.timeIntervalSince(snapshot.updatedAt) < 1800
                                ? AlertPolicy.quotaLevel(remaining: snapshot.remainingPct) : nil
                            XCTAssertEqual(window.showsLevel ? AlertPolicy.quotaLevel(remaining: snapshot.remainingPct) : nil, level, name)
                            // The quota alerts' baseline, before their own checks of the reset, a full window and a newer reading.
                            let alerts = report.isCurrent(agent) && quotaNotice == nil && snapshot.updatedAt <= now
                                && now.timeIntervalSince(snapshot.updatedAt) < 1800 && !(snapshot.resetAt.map { $0 <= now } ?? false)
                            XCTAssertEqual(window.confirmsEvents, alerts, name)
                            // The reset credits' baseline, before their own check of the provider's notices.
                            let credits = observation.isCurrent && observation.quotaNotice == nil && observation.observedAt <= now
                                && now.timeIntervalSince(observation.observedAt) < 1800
                            let accountReading = report.assess(.account(observation), now: now)
                            XCTAssertEqual(accountReading.confirmsEvents, credits, name)
                            // The account header.
                            XCTAssertEqual(accountReading.isCurrentAccount && accountReading.status.isNormal,
                                           observation.isCurrent && observation.quotaNotice == nil, name)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, Notice.allCases.count * 2 * 4 * 3 * 5)
    }

    func testABalanceConfirmsEventsOnlyWhenItsFreshReadSucceeded() {
        for notice in [nil, "offline"] {
            for age: TimeInterval? in [nil, 60, 1799, 1800, -60] {
                let billing = APIBilling(vendor: "DeepSeek", balances: [AccountBalance(currency: "CNY", total: 5, granted: 0, toppedUp: 5)],
                                         isAvailable: true, updatedAt: age.map { now.addingTimeInterval(-$0) }, notice: notice)
                let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], billing: [billing])
                let reading = report.assess(.balance(billing), now: now)
                let events = billing.notice == nil && billing.updatedAt.map { $0 <= now && now.timeIntervalSince($0) < 1800 } == true
                XCTAssertEqual(reading.confirmsEvents, events, "\(notice ?? "no notice") age \(age.map { "\($0)" } ?? "none")")
                XCTAssertEqual(reading.status.reason, notice)
                XCTAssertTrue(reading.isCurrentAccount)
            }
        }
    }

    func testAnIssueOfAnUnknownKindOrWithoutAReasonReadsAsAFailedRead() throws {
        let decoded = try JSONDecoder().decode([ReadingIssue].self, from: Data(#"""
            [{"kind":"unverified","reason":"identity"},{"kind":"expired","reason":"later"},{"reason":"no kind"},{"kind":"readFailed"}]
            """#.utf8))
        XCTAssertEqual(decoded.map(\.status), [.unverified(reason: "identity"), .readFailed(reason: "later"), .readFailed(reason: "no kind"),
                                              .readFailed(reason: "")])
        let issue = ReadingIssue.unverified("identity")
        XCTAssertEqual(try JSONDecoder().decode(ReadingIssue.self, from: JSONEncoder().encode(issue)), issue)
    }

    // MARK: Fixtures

    /// A window's notice as the surfaces read it before they asked the assessment.
    private static func quotaNotice(_ report: UsageReport, _ agent: AgentDescriptor) -> String? {
        let account = agent.account.flatMap { report.observation(accountID: $0.id) }
        if agent.billingPool != nil { return account?.quotaNotice }
        return account?.quotaNotice ?? (report.quotaNotices ?? report.sourceNotices)[agent.vendor]
    }

    /// One window's reading with its account, `age` old, and the notice the case names.
    private func reading(_ notice: Notice, isCurrent: Bool, age: TimeInterval, resetIn: TimeInterval?,
                         remaining: Double) -> (UsageReport, AgentDescriptor, AccountObservation) {
        let pooled = [.poolAccount, .poolVendor].contains(notice)
        let vendor = pooled ? "Kimi" : "Codex"
        let owner = pooled ? ProviderAccount(pool: pool) : account
        let agent = AgentDescriptor(id: owner.windowID("5h"), vendor: vendor, model: "5h", source: "", enabled: true,
                                    billingPool: pooled ? pool : nil, account: owner)
        let at = now.addingTimeInterval(-age)
        let observation = AccountObservation(account: owner, observedAt: at, isCurrent: isCurrent,
                                             quotaNotice: [.account, .poolAccount].contains(notice) ? "account failed" : nil)
        let vendorNotice = [.vendorQuota, .vendorDisplay, .legacyVendor, .poolVendor].contains(notice) ? [vendor: "vendor notice"] : [:]
        return (UsageReport(generatedAt: now, snapshots: [UsageSnapshot(agentId: agent.id, remainingPct: remaining,
                                                                          resetAt: resetIn.map(now.addingTimeInterval),
                                                                          windowDuration: 5 * 3600, updatedAt: at)],
                            sessions: [], discoveredAgents: [agent], sourceNotices: vendorNotice,
                            quotaNotices: notice == .legacyVendor ? nil : notice == .vendorDisplay ? [:] : vendorNotice,
                            accounts: [vendor: [observation]]),
                agent, observation)
    }
}
