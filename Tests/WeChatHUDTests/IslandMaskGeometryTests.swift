import XCTest
import AppKit
@testable import WeChatHUD

final class IslandMaskGeometryTests: XCTestCase {

    func testCoveringIsTheUnionRoundedTheWayAppKitStoresWindows() {
        let compact = NSRect(x: 896, y: 1048, width: 297, height: 32)
        let expanded = NSRect(x: 680, y: 828, width: 560, height: 252)
        let cover = IslandMaskGeometry.covering(compact, expanded)
        XCTAssertEqual(cover, FloatingPanel.rect(from: FloatingPanel.landing(compact.union(expanded))))
        XCTAssertGreaterThanOrEqual(cover.width, expanded.width)
        XCTAssertGreaterThanOrEqual(cover.height, expanded.height)
    }

    func testLayerFramePinsTheIslandToTheTopOfAnUnflippedCover() {
        let cover = NSRect(x: 680, y: 828, width: 560, height: 252)
        let compact = NSRect(x: 811.5, y: 1048, width: 297, height: 32)
        let layer = IslandMaskGeometry.layerFrame(painted: compact, in: cover)
        XCTAssertEqual(layer.minX, compact.minX - cover.minX, accuracy: 0.001)
        XCTAssertEqual(layer.minY, compact.minY - cover.minY, accuracy: 0.001)
        XCTAssertEqual(layer.maxY, cover.height, accuracy: 0.001)
        XCTAssertEqual(layer.height, 32, accuracy: 0.001)
    }

    func testExpandedLayerFrameFillsTheCover() {
        let cover = NSRect(x: 680, y: 828, width: 560, height: 252)
        let layer = IslandMaskGeometry.layerFrame(painted: cover, in: cover)
        XCTAssertEqual(layer, CGRect(x: 0, y: 0, width: 560, height: 252))
    }

    func testCompactMaskIsACapsuleAndExpandedMaskKeepsThePillRadius() {
        XCTAssertEqual(IslandMaskGeometry.cornerRadius(for: CGSize(width: 297, height: 32)), 16)
        XCTAssertEqual(IslandMaskGeometry.cornerRadius(for: CGSize(width: 560, height: 252)), 22)
        XCTAssertEqual(IslandMotion.maskCornerRadius(width: 40, height: 32), 16)
    }

    func testHitTestingUsesThePaintedIslandNotTheCover() {
        let painted = NSRect(x: 811, y: 1048, width: 297, height: 32)
        XCTAssertTrue(IslandMaskGeometry.containsMouse(painted: painted, point: NSPoint(x: 960, y: 1060)))
        XCTAssertFalse(IslandMaskGeometry.containsMouse(painted: painted, point: NSPoint(x: 700, y: 900)))
    }
}
