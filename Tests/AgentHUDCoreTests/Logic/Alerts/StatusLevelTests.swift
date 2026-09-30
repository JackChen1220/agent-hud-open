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

    func testPaletteHexValues() {
        XCTAssertEqual(StatusPalette.color(for: .ok).hexString, "#3ddc84")
        XCTAssertEqual(StatusPalette.color(for: .warning).hexString, "#ffd23f")
        XCTAssertEqual(StatusPalette.color(for: .critical).hexString, "#ff453a")
        XCTAssertEqual(StatusPalette.color(for: .ok, light: true).hexString, "#30d158")
        XCTAssertEqual(StatusPalette.textColor(for: .warning, light: true).hexString, "#c7a100")
        XCTAssertEqual(StatusPalette.textColor(for: .warning, light: false).hexString, "#ffd23f")
        XCTAssertEqual(StatusPalette.idle.hexString, "#9a9aa0")
    }

    func testAgentPaletteWraps() {
        XCTAssertEqual(AgentPalette.color(index: 0).hexString, "#c084fc")
        XCTAssertEqual(AgentPalette.color(index: 3).hexString, "#fb923c")
        XCTAssertEqual(AgentPalette.color(index: 6).hexString, AgentPalette.color(index: 0).hexString)
    }
}
