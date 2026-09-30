import XCTest
@testable import AgentHUDCore

final class BalanceTrendTests: XCTestCase {
    private let reading = Date(timeIntervalSince1970: 1_790_000_000)

    /// Readings as (hours before the reading, amount).
    private func samples(_ values: [(Double, String)]) -> [BalanceSample] {
        values.map { BalanceSample(timestamp: reading.addingTimeInterval(-$0.0 * 3600), amount: Decimal(string: $0.1)!) }
    }

    func testABalanceRunsOutAtThePaceItFellSinceItsLastTopUp() {
        let cases: [(String, [(Double, String)], Double?)] = [
            ("a steady fall over the day", [(24, "100"), (12, "88"), (0, "76")], 76),
            ("the pace from the first reading of the day to the last, whatever lies between", [(20, "50"), (19, "30"), (0, "30")], 30),
            ("readings older than a day are left out", [(30, "500"), (20, "100"), (0, "80")], 80),
            ("readings after the reading are left out", [(10, "20"), (0, "10"), (-2, "0")], 10),
            ("readings arrive in any order", [(0, "76"), (24, "100"), (12, "88")], 76),
            ("a top-up starts the trend again", [(20, "30"), (10, "5"), (8, "105"), (0, "101")], 202),
            ("three hours of trend are enough", [(3, "9"), (0, "6")], 6),
            ("a pace in cents", [(4, "8.85"), (0, "8.81")], 881),
            ("a top-up two hours ago leaves too little trend", [(20, "30"), (10, "5"), (2, "105"), (0, "101")], nil),
            ("two readings an hour apart", [(1, "10"), (0, "9")], nil),
            ("one reading", [(0, "9")], nil),
            ("no readings", [], nil),
            ("a balance that did not fall", [(24, "10"), (0, "10")], nil),
            ("a balance that only rose", [(24, "10"), (0, "12")], nil),
            ("a balance at zero", [(24, "10"), (0, "0")], nil),
            ("a balance below zero", [(24, "10"), (0, "-1")], nil),
        ]
        for (name, values, hours) in cases {
            let runsOut = BalanceTrend.runsOutAt(samples(values), at: reading)
            XCTAssertEqual(runsOut?.timeIntervalSince(reading) ?? -1, hours.map { $0 * 3600 } ?? -1, accuracy: 0.001, name)
        }
    }
}
