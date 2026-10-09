import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class NotchGeometryTests: XCTestCase {
    private let screen = CGRect(x: -1600, y: -200, width: 1600, height: 900)

    func testExpandedPanelStaysInsideEachEdgeAtBothCorners() {
        for edge in HUDEdge.allCases {
            for offset in [0.0, 1.0] {
                let geometry = makeGeometry(edge: edge, offset: offset)
                let expanded = geometry.expandedFrame(size: CGSize(width: 440, height: 300))
                XCTAssertTrue(screen.contains(expanded), "\(edge), offset \(offset): \(expanded)")
                switch edge {
                case .top: XCTAssertEqual(expanded.maxY, screen.maxY)
                case .bottom: XCTAssertEqual(expanded.minY, screen.minY)
                case .left: XCTAssertEqual(expanded.minX, screen.minX)
                case .right: XCTAssertEqual(expanded.maxX, screen.maxX)
                }
            }
        }
    }

    func testOversizedPanelFitsTheDisplay() {
        for edge in HUDEdge.allCases {
            let geometry = makeGeometry(edge: edge, offset: 0.5)
            XCTAssertEqual(geometry.expandedFrame(size: CGSize(width: 2400, height: 1500)), screen)
        }
    }

    func testDragPlacementRoundTripsQueueCentresIncludingTravelEndpoints() {
        for edge in HUDEdge.allCases {
            for offset in [0.0, 0.2, 0.5, 0.8, 1.0] {
                let geometry = makeGeometry(edge: edge, offset: offset)
                let initial = ScreenPlacement(edge: edge, showsLogos: false)
                let queue = queueSize(for: edge)
                let point = CGPoint(x: geometry.rect.midX, y: geometry.rect.midY)
                let result = NotchGeometry.dragPlacement(at: point, screenFrame: screen, queue: queue, placement: initial)
                XCTAssertEqual(result.edge, edge)
                XCTAssertEqual(result.offset, offset, accuracy: 0.000001)
                XCTAssertFalse(result.showsLogos, "Moving the HUD preserves the logo visibility setting")
            }
        }
    }

    func testTurningQueueOntoASideUsesTheRunRatherThanItsThickness() {
        let point = CGPoint(x: screen.minX + 5, y: screen.maxY - 260)
        let original = ScreenPlacement(mode: .notch, edge: .top, logoSize: 18, gapScale: 0.2, showsLogos: false)
        let result = NotchGeometry.dragPlacement(at: point, screenFrame: screen,
                                                queue: CGSize(width: 216, height: 20), placement: original)
        XCTAssertEqual(result.mode, .logos)
        XCTAssertEqual(result.edge, .left)
        let rect = NotchGeometry.stripRect(queue: CGSize(width: 20, height: 216), frame: screen,
                                          menuBar: 32, placement: result)
        XCTAssertEqual(rect.midY, point.y, accuracy: 0.000001)
        XCTAssertEqual(result.logoSize, original.logoSize)
        XCTAssertEqual(result.gapScale, original.gapScale)
        XCTAssertEqual(result.showsLogos, original.showsLogos)
    }

    func testNoncentralGrabKeepsTheQueueUnderThePointerWhileMovingAlongEveryEdge() {
        for edge in HUDEdge.allCases {
            for fraction in [CGFloat(0.15), 0.8] {
                let initial = ScreenPlacement(edge: edge, offset: 0.35)
                let original = makeGeometry(edge: edge, offset: initial.offset).rect
                let down = point(in: original, edge: edge, fraction: fraction)
                let stationary = NotchGeometry.dragPlacement(at: down, screenFrame: screen, queue: queueSize(for: edge),
                                                             placement: initial, grabFraction: fraction)
                XCTAssertEqual(stationary.offset, initial.offset, accuracy: 0.000001,
                               "\(edge): grabbing away from the centre must not reposition the queue")
                for delta in [CGFloat(-61), 61] {
                    let moved = CGPoint(x: down.x + (edge.isHorizontal ? delta : 0),
                                        y: down.y - (edge.isHorizontal ? 0 : delta))
                    let placement = NotchGeometry.dragPlacement(at: moved, screenFrame: screen, queue: queueSize(for: edge),
                                                                 placement: initial, grabFraction: fraction)
                    let rect = NotchGeometry.stripRect(queue: queueSize(for: edge), frame: screen, menuBar: 32,
                                                       placement: placement)
                    XCTAssertEqual(placement.edge, edge)
                    XCTAssertEqual(edge.isHorizontal ? rect.minX - original.minX : original.maxY - rect.maxY,
                                   delta, accuracy: 0.000001, "\(edge): queue movement follows pointer movement")
                    let grabbedPoint = point(in: rect, edge: edge, fraction: fraction)
                    XCTAssertEqual(grabbedPoint.x, moved.x, accuracy: 0.000001)
                    XCTAssertEqual(grabbedPoint.y, moved.y, accuracy: 0.000001)
                }
            }
        }
    }

    func testTurningOntoAnotherEdgePreservesTheGrabbedFractionOfTheRun() {
        for source in HUDEdge.allCases {
            for target in HUDEdge.allCases where target != source {
                for fraction in [CGFloat(0.2), 0.85] {
                    let targetRect = makeGeometry(edge: target, offset: 0.45).rect
                    let pointer = point(in: targetRect, edge: target, fraction: fraction)
                    let placement = NotchGeometry.dragPlacement(at: pointer, screenFrame: screen, queue: queueSize(for: source),
                                                                 placement: ScreenPlacement(edge: source), grabFraction: fraction)
                    let rect = NotchGeometry.stripRect(queue: queueSize(for: target), frame: screen, menuBar: 32,
                                                       placement: placement)
                    XCTAssertEqual(placement.edge, target)
                    XCTAssertEqual(placement.offset, 0.45, accuracy: 0.000001)
                    let grabbedPoint = point(in: rect, edge: target, fraction: fraction)
                    XCTAssertEqual(grabbedPoint.x, pointer.x, accuracy: 0.000001, "\(source) → \(target)")
                    XCTAssertEqual(grabbedPoint.y, pointer.y, accuracy: 0.000001, "\(source) → \(target)")
                }
            }
        }
    }

    func testDraggingBeyondTheRunEndpointsClampsAndDiagonalTieKeepsCurrentEdge() {
        let top = ScreenPlacement(edge: .top)
        let leftEnd = NotchGeometry.dragPlacement(at: CGPoint(x: screen.minX + 4, y: screen.maxY - 1),
                                                  screenFrame: screen, queue: queueSize(for: .top), placement: top)
        XCTAssertEqual(leftEnd.edge, .top)
        XCTAssertEqual(leftEnd.offset, 0)
        let rightEnd = NotchGeometry.dragPlacement(at: CGPoint(x: screen.maxX - 4, y: screen.maxY - 1),
                                                   screenFrame: screen, queue: queueSize(for: .top), placement: top)
        XCTAssertEqual(rightEnd.offset, 1)
        let tie = CGPoint(x: screen.minX + 10, y: screen.maxY - 10)
        XCTAssertEqual(NotchGeometry.dragPlacement(at: tie, screenFrame: screen,
                                                   queue: queueSize(for: .top), placement: top).edge, .top)
        XCTAssertEqual(NotchGeometry.dragPlacement(at: tie, screenFrame: screen, queue: queueSize(for: .left),
                                                   placement: ScreenPlacement(edge: .left)).edge, .left)
    }

    func testQueueThatFillsTheEdgeHasNoTravel() {
        let result = NotchGeometry.dragPlacement(at: CGPoint(x: screen.midX, y: screen.maxY), screenFrame: screen,
                                                queue: CGSize(width: 2000, height: 20), placement: ScreenPlacement())
        XCTAssertEqual(result.offset, 0.5)
    }

    private func queueSize(for edge: HUDEdge) -> CGSize {
        edge.isHorizontal ? CGSize(width: 216, height: 20) : CGSize(width: 20, height: 216)
    }

    private func point(in rect: CGRect, edge: HUDEdge, fraction: CGFloat) -> CGPoint {
        edge.isHorizontal
            ? CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
            : CGPoint(x: rect.midX, y: rect.maxY - rect.height * fraction)
    }

    private func makeGeometry(edge: HUDEdge, offset: Double) -> NotchGeometry {
        let placement = ScreenPlacement(edge: edge, offset: offset)
        let rect = NotchGeometry.stripRect(queue: queueSize(for: edge), frame: screen, menuBar: 32, placement: placement)
        return NotchGeometry(screenFrame: screen, mode: .logos, edge: edge, hasNotch: false,
                             rect: rect, cornerRadius: 10, backingScale: 2, menuBarHeight: 32)
    }
}

final class DockGlowOrientationTests: XCTestCase {
    func testEachEdgeMapsItsBackdropLipToTheSameTopEdgeCoordinateSpace() {
        let screen = CGRect(x: -1600, y: -200, width: 1600, height: 900)
        let cases: [(HUDEdge, CGRect, CGRect)] = [
            (.top, CGRect(x: -1100, y: 700, width: 300, height: 2),
             CGRect(x: 500, y: 900, width: 300, height: 2)),
            (.bottom, CGRect(x: -1100, y: -202, width: 300, height: 2),
             CGRect(x: 500, y: 900, width: 300, height: 2)),
            (.left, CGRect(x: -1602, y: 100, width: 2, height: 300),
             CGRect(x: 300, y: 1600, width: 300, height: 2)),
            (.right, CGRect(x: 0, y: 100, width: 2, height: 300),
             CGRect(x: 300, y: 1600, width: 300, height: 2)),
        ]
        for (edge, island, expected) in cases {
            XCTAssertEqual(GlowWindowController.canonicalIslandFrame(island, panel: screen, edge: edge), expected)
        }
    }

    func testSideQueueColoursFollowMarksFromTopToBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for edge in [HUDEdge.left, .right] {
            let x: CGFloat = edge == .left ? 0 : 1580
            let upper = CGRect(x: x, y: 850, width: 20, height: 20)
            let lower = upper.offsetBy(dx: 0, dy: -28)
            let upperCanonical = GlowWindowController.canonicalIslandFrame(upper, panel: screen, edge: edge)
            let lowerCanonical = GlowWindowController.canonicalIslandFrame(lower, panel: screen, edge: edge)
            XCTAssertEqual(lowerCanonical.minX - upperCanonical.minX, 28)
            XCTAssertEqual(lowerCanonical.minY, upperCanonical.minY)
        }
    }

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
