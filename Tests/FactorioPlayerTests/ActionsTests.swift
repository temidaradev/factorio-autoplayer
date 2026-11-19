import CoreGraphics
import Foundation
import XCTest
@testable import FactorioPlayer

final class ActionsTests: XCTestCase {
    private let geometry = FrameGeometry(
        bounds: CGRect(x: -1_280, y: 25, width: 1_280, height: 720),
        width: 1_920,
        height: 1_080
    )

    func testMapsScreenshotCoordinatesToGlobalPointsOnRetinaAndSecondaryDisplay() throws {
        let point = try geometry.desktopPoint(for: Pixel(x: 960, y: 540))
        XCTAssertEqual(point.x, -639.666_667, accuracy: 0.001)
        XCTAssertEqual(point.y, 385.333_333, accuracy: 0.001)
    }

    func testRejectsPointsOutsideTheFrameOrTooCloseToAnEdge() {
        for point in [Pixel(x: -1, y: 700), Pixel(x: 1_920, y: 700), Pixel(x: 960, y: 0)] {
            XCTAssertThrowsError(try geometry.desktopPoint(for: point))
        }
    }

    func testPreparesRightMouseHoldAndDiagonalMovement() throws {
        let actions = try prepare("""
        [
          {"type":"click","at":{"x":800,"y":600},"button":"right","durationMs":900},
          {"type":"key","key":"w+d","durationMs":500}
        ]
        """)
        if case .click(_, .right) = actions[0].operation {
            XCTAssertEqual(actions[0].durationMs, 900)
        } else {
            XCTFail("Expected a right mouse hold")
        }
        if case .key(let keys) = actions[1].operation {
            XCTAssertEqual(keys.count, 2)
        } else {
            XCTFail("Expected simultaneous movement keys")
        }
    }

    func testRejectsWholeBatchWhenAnyActionIsInvalid() {
        XCTAssertThrowsError(try prepare("""
        [{"type":"key","key":"e"},{"type":"drag","at":{"x":300,"y":400}}]
        """))
        XCTAssertThrowsError(try prepare("""
        [{"type":"key","key":"left","modifiers":["control"]}]
        """))
        XCTAssertThrowsError(try prepare("""
        [{"type":"key","key":"w+w"}]
        """))
        XCTAssertThrowsError(try prepare("""
        [{"type":"click","at":{"x":300,"y":400},"durationMs":0}]
        """))
    }

    func testRejectsEmptyAndOverlongBatches() {
        XCTAssertThrowsError(try prepare("[]"))
        XCTAssertThrowsError(try prepare("""
        [{"type":"wait","durationMs":1500},{"type":"wait","durationMs":1500},{"type":"wait","durationMs":1000}]
        """))
    }

    func testPlainTextSupportsRecipeAndSaveNamesButNoConsoleSyntax() throws {
        XCTAssertEqual(try prepare("""
        [{"type":"text","text":"Iron_plate 2"}]
        """).first?.durationMs, 12 * 18)
        XCTAssertThrowsError(try prepare("""
        [{"type":"text","text":"/silent-command"}]
        """))
    }

    private func prepare(_ json: String) throws -> [PreparedAction] {
        let requests = try JSONDecoder().decode([ActionRequest].self, from: Data(json.utf8))
        return try PreparedAction.prepare(requests, geometry: geometry)
    }
}
