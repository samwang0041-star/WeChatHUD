import XCTest
@testable import WeChatHUD

/// Regression cover for the "pops open at the top edge, then collapses by
/// itself" report: the expanded panel used to settle with `mouseInside ==
/// false` while the cursor was parked on the display's top scanline, because
/// `NSRect.contains` excludes the `maxY` edge the panel is pinned to.
final class IslandHitTestTests: XCTestCase {

    /// The panel's frame in the reported scenario: top edge flush with the
    /// top of a 1080 pt display, 580 × 247 after expanding from compact.
    private let frame = NSRect(x: -1154, y: 833, width: 580, height: 247)

    func testCursorOnTopEdgeCountsAsInside() {
        let topEdge = NSPoint(x: frame.midX, y: frame.maxY)
        XCTAssertFalse(frame.contains(topEdge), "precondition: the raw rect excludes its maxY edge")
        XCTAssertTrue(IslandHitTest.contains(frame: frame, point: topEdge))
    }

    func testCursorJustOutsideTopEdgeIsAbsorbedByTolerance() {
        let justAbove = NSPoint(x: frame.midX, y: frame.maxY + 1)
        XCTAssertTrue(IslandHitTest.contains(frame: frame, point: justAbove))
    }

    func testDeliberateMoveAwayStillReadsAsOutside() {
        XCTAssertFalse(IslandHitTest.contains(frame: frame, point: NSPoint(x: frame.midX, y: frame.maxY + 40)))
        XCTAssertFalse(IslandHitTest.contains(frame: frame, point: NSPoint(x: frame.minX - 40, y: frame.midY)))
        XCTAssertFalse(IslandHitTest.contains(frame: frame, point: NSPoint(x: frame.maxX + 40, y: frame.midY)))
        XCTAssertFalse(IslandHitTest.contains(frame: frame, point: NSPoint(x: frame.midX, y: frame.minY - 40)))
    }

    func testInteriorPointsStayInside() {
        XCTAssertTrue(IslandHitTest.contains(frame: frame, point: NSPoint(x: frame.midX, y: frame.midY)))
        XCTAssertTrue(IslandHitTest.contains(frame: frame, point: NSPoint(x: frame.minX, y: frame.minY)))
    }

    func testCompactPillTopEdgeAlsoCountsAsInside() {
        // The collapse direction has the same hazard: the compact frame is
        // also pinned to the top edge, and `frameAnimationEnded` fires with
        // a resampled `mouseInside` for it.
        let compact = NSRect(x: -1013, y: 1048, width: 297, height: 32)
        XCTAssertTrue(IslandHitTest.contains(frame: compact, point: NSPoint(x: compact.midX, y: compact.maxY)))
    }
}
