import Foundation
import XCTest
@testable import AgentHUDDesktop

final class AntigravityNavigationTests: XCTestCase {
    private let conversationID = "74c0183c-4100-4cf0-a7ff-2ff51a8e6d54"
    private let otherID = "f6ac62b4-15bb-44e9-9d27-3eccd43e1424"
    private let port = 55524

    func testConversationRouteRequiresUUIDAndClearsPreviousTabState() throws {
        let destination = try XCTUnwrap(AntigravityNavigation.destination(
            conversationID: conversationID,
            page: page(url: "https://127.0.0.1:55526/c/\(otherID)?tab=overview#section"), port: port))
        XCTAssertEqual(destination.url.absoluteString, "https://127.0.0.1:55526/c/" + conversationID)
        XCTAssertNil(AntigravityNavigation.destination(conversationID: "../other", page: page(), port: port))
        XCTAssertNil(AntigravityNavigation.destination(conversationID: "", page: page(), port: port))
    }

    func testOnlyDesktopLoopbackPagesAreEligible() {
        for candidate in [page(type: "worker"), page(url: ""), page(url: "https://example.com/c/" + otherID),
                          page(url: "http://127.0.0.1:55526/c/" + otherID),
                          page(url: "https://localhost:55526/c/" + otherID)] {
            XCTAssertNil(AntigravityNavigation.destination(conversationID: conversationID, page: candidate, port: port))
        }
    }

    func testRemoteOrUnrelatedDebuggerSocketsAreRejected() {
        for socket in ["ws://example.com:55524/devtools/page/page-1",
                       "wss://127.0.0.1:55524/devtools/page/page-1",
                       "ws://127.0.0.1:55525/devtools/page/page-1",
                       "ws://127.0.0.1:55524/devtools/page/other-page",
                       "ws://127.0.0.1:55524/devtools/browser/browser-1"] {
            XCTAssertNil(AntigravityNavigation.destination(
                conversationID: conversationID, page: page(socket: socket), port: port))
        }
        XCTAssertNil(AntigravityNavigation.destination(
            conversationID: conversationID, page: page(socket: nil), port: port))
    }

    func testMultipleWindowsPreferTheRequestedConversationAndFailIfAmbiguous() throws {
        let first = page(id: "first")
        let existing = page(id: "existing", url: "https://127.0.0.1:55526/c/" + conversationID)
        let selected = try XCTUnwrap(AntigravityNavigation.destination(
            conversationID: conversationID, pages: [first, existing], port: port))
        XCTAssertEqual(selected.id, "existing")
        XCTAssertNil(AntigravityNavigation.destination(
            conversationID: conversationID, pages: [first, page(id: "second")], port: port))
        XCTAssertNil(AntigravityNavigation.destination(
            conversationID: conversationID, pages: [existing, page(id: "duplicate", url: existing.url)], port: port))
        XCTAssertEqual(AntigravityNavigation.destination(
            conversationID: conversationID, pages: [page(type: "worker"), first], port: port)?.id, "first")
    }

    func testPageInventoryAcceptsWorkersAndReloadsWithEmptyURLs() throws {
        let data = Data(#"[{"id":"page","type":"page","url":""},{"id":"worker","type":"worker","url":""}]"#.utf8)
        let pages = try JSONDecoder().decode([AntigravityNavigation.Page].self, from: data)
        XCTAssertEqual(pages.count, 2)
        XCTAssertNil(AntigravityNavigation.destination(conversationID: conversationID, pages: pages, port: port))
    }

    private func page(id: String = "page-1", type: String = "page", url: String? = nil,
                      socket: String? = "default") -> AntigravityNavigation.Page {
        AntigravityNavigation.Page(id: id, type: type,
                                   url: url ?? "https://127.0.0.1:55526/c/" + otherID,
                                   webSocketDebuggerUrl: socket.flatMap {
                                       URL(string: $0 == "default" ? "ws://127.0.0.1:\(port)/devtools/page/\(id)" : $0)
                                   })
    }
}
