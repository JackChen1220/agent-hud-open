import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

final class PaletteTests: XCTestCase {
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
