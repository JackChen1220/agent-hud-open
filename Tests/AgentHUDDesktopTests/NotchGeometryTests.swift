import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class NotchGeometryTests: XCTestCase {
    func testShortCenteredLogoQueueClearsPhysicalNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let notch = CGRect(x: 646, y: 924, width: 179, height: 32)
        let queue = CGSize(width: 48, height: 20)
        let placement = ScreenPlacement(mode: .logos)

        let rect = NotchGeometry.stripRect(queue: queue, frame: frame, menuBar: 32,
                                           placement: placement, notch: notch)

        XCTAssertEqual(rect.width, 48)
        XCTAssertEqual(rect.midX, frame.midX)
        XCTAssertEqual(rect.maxY, notch.minY)
        XCTAssertFalse(rect.intersects(notch))
    }

    func testLogoQueueStaysCenteredWithoutNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let rect = NotchGeometry.stripRect(queue: CGSize(width: 48, height: 20), frame: frame,
                                           menuBar: 32, placement: ScreenPlacement(mode: .logos))

        XCTAssertEqual(rect.midX, frame.midX)
    }
}
