import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

final class TokenLegendTests: XCTestCase {
    func testIslandShowsTheTenLargestModelsWithStableTiesAndOriginalPalette() {
        let consumers = (0..<13).map {
            AgentDescriptor(id: "model-\($0)", vendor: "Codex", model: "Model \($0)", source: "", enabled: true)
        }
        let tokens = [10, 40, 0, 20, 40, 30, 1, 10, 50, 30, 20, 10, 10]
        let columns = [TokenColumn(interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600), tokens: tokens)]
        let legend = TokenConsumptionChart.islandLegend(consumers: consumers, columns: columns)
        XCTAssertEqual(legend.shown.map(\.paletteIndex), [8, 1, 4, 5, 9, 3, 10, 0, 7, 11])
        XCTAssertEqual(legend.shown.map(\.id), [8, 1, 4, 5, 9, 3, 10, 0, 7, 11].map { "model-\($0)" })
        XCTAssertEqual(legend.more, 2)
        XCTAssertEqual(columns.first?.total, 271, "The legend cap does not trim the chart's model stacks or total")
        XCTAssertEqual(TokenConsumptionChart.modelTotals(consumers: consumers, columns: columns).count, 13,
                       "The statistics filter keeps every model, including those currently at zero")
    }
}
