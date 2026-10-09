import XCTest
@testable import AgentHUDCore

final class CountdownTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.zhHans)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(Countdown.format(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(Countdown.format(4 * 3600 + 2 * 60), "4h 02m")
        XCTAssertEqual(Countdown.format(6 * 3600 + 40 * 60), "6h 40m")
    }

    func testMinutesOnlyUnderAnHour() {
        XCTAssertEqual(Countdown.format(51 * 60), "51m")
        XCTAssertEqual(Countdown.format(59 * 60 + 30), "59m")
        XCTAssertEqual(Countdown.format(0), "0m")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(Countdown.format(-500), "0m")
    }

    func testCompactDropsSpaces() {
        XCTAssertEqual(Countdown.compact(2 * 3600 + 14 * 60), "2h14m")
        XCTAssertEqual(Countdown.compact(51 * 60), "51m")
    }

    func testUntilHandlesUnknown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Countdown.until(nil, now: now), "—")
        XCTAssertEqual(Countdown.until(now.addingTimeInterval(3600), now: now), "1h 00m")
    }

    func testSessionLabels() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let live = LiveSession(id: "a", agentId: "x", task: "t", terminal: nil, startedAt: now.addingTimeInterval(-27 * 60), pctOfWindow: 1, tokensIn: 0, tokensOut: 0)
        XCTAssertEqual(Countdown.sessionLabel(live, now: now), "27m 进行中")
        let ended = LiveSession(id: "b", agentId: "x", task: "t", terminal: nil, startedAt: now.addingTimeInterval(-7200), endedAt: now.addingTimeInterval(-51 * 60), pctOfWindow: 1, tokensIn: 0, tokensOut: 0)
        XCTAssertEqual(Countdown.sessionLabel(ended, now: now), "结束于 51m 前")
        let endedHoursAgo = LiveSession(id: "c", agentId: "x", task: "t", terminal: nil, startedAt: now.addingTimeInterval(-9000), endedAt: now.addingTimeInterval(-7200), pctOfWindow: 1, tokensIn: 0, tokensOut: 0)
        XCTAssertEqual(Countdown.sessionLabel(endedHoursAgo, now: now), "结束于 2h 前")
    }

    func testFormatRough() {
        XCTAssertEqual(Countdown.formatRough(7200), "2h")
        XCTAssertEqual(Countdown.formatRough(7260), "2h 01m")
        XCTAssertEqual(Countdown.formatRough(1800), "30m")
    }

    func testAgeAndWaitEachKeepOneUnit() {
        let ages: [TimeInterval] = [42, 300, 14_340, 172_805], waits: [TimeInterval] = [42, 180, 3900]
        XCTAssertEqual(ages.map(Countdown.age), ["42s 前", "5m 前", "3h 前", "2d 前"])
        XCTAssertEqual(waits.map(Countdown.waited), ["42s", "3m", "1h05m"])
    }
}

final class TokenFormatTests: XCTestCase {
    func testShort() {
        XCTAssertEqual(TokenFormat.short(48_000), "48k")
        XCTAssertEqual(TokenFormat.short(1_260), "1.3k")
        XCTAssertEqual(TokenFormat.short(950), "950")
        XCTAssertEqual(TokenFormat.short(2_400_000), "2.4M")
        XCTAssertEqual(TokenFormat.short(84_000), "84k")
        XCTAssertEqual(TokenFormat.short(5_036_000_000), "5.0B")
    }

    func testInOut() {
        XCTAssertEqual(TokenFormat.inOut(in: 48_000, out: 12_000), "48k ↓ 12k ↑")
    }

    func testPercent() {
        XCTAssertEqual(TokenFormat.percent(72), "72%")
        XCTAssertEqual(TokenFormat.percent(6.6), "7%")
        XCTAssertEqual(TokenFormat.percent1(6.2), "6.2%")
    }

    /// A share reads "<1%" only where it would round to nothing without being nothing.
    func testShare() {
        XCTAssertEqual([0, 3, 7, 12, 1000].map { TokenFormat.share($0, of: 1000) }, ["0%", "<1%", "1%", "1%", "100%"])
        XCTAssertEqual(TokenFormat.share(0, of: 0), "0%")
    }
}

final class MoneyFormatTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// A price is written with its ISO code in both languages, as the website writes it; an estimate keeps the symbol.
    func testPricesCarryTheirCodeAndEstimatesTheSymbol() {
        for language in [AppLanguage.zhHans, .en] {
            L10n.setLanguage(language)
            XCTAssertEqual(MoneyFormat.price(Decimal(string: "2.99")!, currency: "USD"), "USD 2.99")
            XCTAssertEqual(MoneyFormat.price(Decimal(string: "29.99")!, currency: "USD"), "USD 29.99")
            XCTAssertEqual(MoneyFormat.price(1299, currency: "USD"), "USD 1,299.00")
            XCTAssertEqual(MoneyFormat.price(Decimal(string: "2.985")!, currency: "USD"), "USD 2.99")
            XCTAssertEqual(MoneyFormat.amount(Decimal(string: "12.99")!, currency: "USD"), "$12.99")
        }
    }
}

final class ResetLabelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.zhHans)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    func testCountdownInsideADayWeekdayBeyond() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 15, minute: 0))! // Monday
        XCTAssertEqual(Countdown.resetLabel(now.addingTimeInterval(3 * 3600 + 10 * 60), now: now, calendar: calendar), "3h 10m")
        XCTAssertEqual(Countdown.resetLabelCompact(now.addingTimeInterval(3 * 3600 + 10 * 60), now: now, calendar: calendar), "3h10m")
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 2, minute: 0))!
        XCTAssertEqual(Countdown.resetLabel(sunday, now: now, calendar: calendar), "周日 02:00")
        XCTAssertEqual(Countdown.resetLabel(nil, now: now, calendar: calendar), "—")
    }

    func testQuotaWindowRowsFollowUsageScreenOrder() {
        let usage = ClaudeUsage(
            fiveHour: ClaudeUsageWindow(utilizationPct: 23, resetsAt: nil),
            sevenDay: ClaudeUsageWindow(utilizationPct: 71, resetsAt: nil),
            modelWeekly: ["fable": ClaudeUsageWindow(utilizationPct: 45, resetsAt: nil)]
        )
        XCTAssertEqual(usage.rows.map(\.id), ["claude-session", "claude-weekly", "claude-weekly-fable"])
        XCTAssertEqual(usage.rows.map(\.label), ["window.session", "window.weekly", "window.weekly.Fable"], "labels are persisted as language-neutral keys")
        XCTAssertEqual(usage.rows.map { L10n.modelLabel($0.label) }, ["当前会话", "每周限制 · 所有模型", "每周限制 · Fable"])
        XCTAssertEqual(usage.rows.map(\.descriptor.shortName), ["5h", "每周", "Fable"])
        XCTAssertEqual(usage.rows.map { Int($0.window.remainingPct) }, [77, 29, 55])
        XCTAssertEqual(usage.rows.first?.descriptor.vendor, "Claude")
        XCTAssertEqual(usage.rows.map(\.descriptor.allModels), [true, true, false], "a family's weekly window limits that family alone")
    }
}
