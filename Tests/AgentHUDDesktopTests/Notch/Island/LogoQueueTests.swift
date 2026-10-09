import AppKit
import XCTest
@testable import AgentHUDDesktop

final class LogoQueueTests: XCTestCase {
    @MainActor
    func testGrokClientsUseDifferentMarksAndKeepTheirOwnWorkingState() throws {
        let cli = try XCTUnwrap(AgentArtwork.image(for: "Grok CLI", dark: true))
        let bot = try XCTUnwrap(AgentArtwork.image(for: "Grok Bot", dark: true))
        XCTAssertTrue(cli.isTemplate)
        XCTAssertFalse(bot.isTemplate)
        XCTAssertEqual(AgentArtwork.markKey("Grok CLI"), AgentArtwork.markKey("Grok"))
        XCTAssertNotEqual(AgentArtwork.markKey("Grok CLI"), AgentArtwork.markKey("Grok Bot"))
        XCTAssertFalse(AgentArtwork.isTemplate("Grok Bot"))
        XCTAssertFalse(try XCTUnwrap(AgentArtwork.original(for: "Grok Bot")).isTemplate)

        let items = LogoQueueItem.queue(rows: [("Grok CLI", false), ("Grok Bot", true), ("Grok CLI", false)])
        XCTAssertEqual(items.map(\.vendor), ["Grok CLI", "Grok Bot"])
        XCTAssertEqual(items.map(\.isWorking), [false, true])
    }
}
