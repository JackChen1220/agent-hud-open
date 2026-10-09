import XCTest
@testable import AgentHUDCore

final class StatusLevelTests: XCTestCase {
    func testAboveWarnIsOk() {
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 72, warnPct: 30, critPct: 10), .ok)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 30.1, warnPct: 30, critPct: 10), .ok)
    }

    func testAtOrBelowWarnIsWarning() {
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 30, warnPct: 30, critPct: 10), .warning)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 24, warnPct: 30, critPct: 10), .warning)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 10.5, warnPct: 30, critPct: 10), .warning)
    }

    func testAtOrBelowCritIsCritical() {
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 10, warnPct: 30, critPct: 10), .critical)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 7, warnPct: 30, critPct: 10), .critical)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 0, warnPct: 30, critPct: 10), .critical)
    }

    func testChatGPTThresholds() {
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 58, warnPct: 40, critPct: 15), .ok)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 38, warnPct: 40, critPct: 15), .warning)
        XCTAssertEqual(StatusLevel.resolve(remainingPct: 15, warnPct: 40, critPct: 15), .critical)
    }

    func testFixedQuotaAndBalancePolicy() {
        XCTAssertEqual(AlertPolicy.quotaLevel(remaining: 31), .ok)
        XCTAssertEqual(AlertPolicy.quotaLevel(remaining: 30), .warning)
        XCTAssertEqual(AlertPolicy.quotaLevel(remaining: 11), .warning)
        XCTAssertEqual(AlertPolicy.quotaLevel(remaining: 10), .critical)
        XCTAssertEqual(AlertPolicy.balanceLevel(remaining: 10, currency: "CNY"), .warning)
        XCTAssertEqual(AlertPolicy.balanceLevel(remaining: 2, currency: "USD"), .warning)
        XCTAssertEqual(AlertPolicy.balanceLevel(remaining: 0, currency: "USD"), .critical)
        XCTAssertEqual(AlertPolicy.balanceLevel(remaining: 2, currency: "EUR"), .ok, "a currency without a line is fine until it runs out")
        XCTAssertEqual(AlertPolicy.balanceLevel(remaining: 0, currency: "EUR"), .critical)
    }
}
