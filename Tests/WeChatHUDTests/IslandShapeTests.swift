import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// The island silhouette where it meets the top of the screen.
///
/// The pill used to fill its top corners — a rectangle pasted onto the screen
/// edge. It now gives them away with a concave fillet, so the body meets the
/// top edge with a curve and reads as hung from it. These tests ask the drawn
/// path, in the same top-left point space SwiftUI lays it out in: whether a
/// point is inside the shape is exactly whether the user sees black there.
@MainActor
final class IslandShapeTests: XCTestCase {
    private func path(
        topCornerRadius: CGFloat,
        width: CGFloat = 560,
        height: CGFloat = 200,
        notchWidth: CGFloat = 200,
        notchHeight: CGFloat = 32
    ) -> Path {
        IslandShape(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            pillCornerRadius: 22,
            notchCornerRadius: 10,
            topCornerRadius: topCornerRadius
        ).path(in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func inside(_ path: Path, _ x: Double, _ y: Double) -> Bool {
        path.contains(CGPoint(x: x, y: y))
    }

    /// The body must clear the very top corners: that gap is the outward curve.
    func testTopCornersAreGivenAwayToTheFillet() {
        let filleted = path(topCornerRadius: 16)
        XCTAssertFalse(inside(filleted, 0.5, 0.5), "the top-left corner must not be filled")
        XCTAssertFalse(inside(filleted, 559.5, 0.5), "the top-right corner must not be filled")

        // The same points are solid without the fillet — this is a change to
        // the corner, not to the pill's extent.
        let sharp = path(topCornerRadius: 0)
        XCTAssertTrue(inside(sharp, 0.5, 0.5))
        XCTAssertTrue(inside(sharp, 559.5, 0.5))
    }

    /// The fillet is concave, not a rounded corner: the body creeps in from the
    /// side as it descends, and only reaches x = 0 about one radius down.
    func testFilletIsConcave_soTheBodyMeetsTheTopEdgeTangentially() {
        let filleted = path(topCornerRadius: 16)
        // The boundary is the quarter arc of radius 16 centred at (16, 16):
        //   x(y) = 16 - sqrt(256 - (16 - y)^2)
        // which is 12.0 at the top edge, 5.4 four points down, 2.1 halfway, and
        // vertical (x = 0) at y = 16 — the tangent point where the body takes
        // over the screen edge.
        // At the very top the curve is nearly horizontal, so a fraction of a
        // point of sampling error moves the measured boundary several points;
        // the deeper samples follow the arc closely.
        let topInset = boundary(of: filleted, atY: 0.5)
        XCTAssertGreaterThan(topInset, 9, "the top edge must be inset by about the radius")
        XCTAssertLessThanOrEqual(topInset, 16.1, "and never by more than that")
        for (y, expected) in [(4.0, 5.4), (8.0, 2.1), (12.0, 0.5)] {
            let edge = boundary(of: filleted, atY: y)
            XCTAssertEqual(edge, expected, accuracy: 1.2,
                           "the fillet boundary at y=\(y) should follow the radius-16 arc")
        }
        XCTAssertEqual(boundary(of: filleted, atY: 17), 0, accuracy: 0.1,
                       "about one radius down the edge is body again")

        // Concave, not convex: the gap narrows on the way down, never reopens.
        let depths = [0.5, 4.0, 8.0, 12.0, 15.0, 17.0]
        let widths = depths.map { boundary(of: filleted, atY: $0) }
        for (previous, next) in zip(widths, widths.dropFirst()) {
            XCTAssertGreaterThanOrEqual(previous, next - 0.1,
                                        "the fillet widened again: \(widths)")
        }
    }

    /// Horizontal distance from the left edge to the shape's boundary at a height.
    private func boundary(of shape: Path, atY y: Double) -> Double {
        for tenth in 0...300 {
            let x = Double(tenth) / 10
            if inside(shape, x, y) { return x }
        }
        return 30
    }

    /// Nothing outside the two top corners moves: same notch, same bottom.
    func testNotchAndBottomAreUnchangedByTheFillet() {
        let sharp = path(topCornerRadius: 0)
        let filleted = path(topCornerRadius: 16)

        for x in stride(from: 40.0, through: 520.0, by: 20) {
            for y in stride(from: 40.0, through: 180.0, by: 20) {
                XCTAssertEqual(inside(sharp, x, y), inside(filleted, x, y),
                               "the fillet changed the shape at (\(x), \(y))")
            }
        }

        // The notch cutout, and the bar under it.
        for candidate in [sharp, filleted] {
            XCTAssertFalse(inside(candidate, 280, 16), "the notch must stay cut out")
            XCTAssertTrue(inside(candidate, 280, 40), "the pill under the notch must stay solid")
            XCTAssertTrue(inside(candidate, 100, 1), "the top edge beside the notch is untouched")
        }
    }

    /// A fillet can never exceed the pill's half-height or the gap beside the
    /// notch, whichever is smaller — so a compact pill (32 pt tall, 297 pt wide)
    /// gets a shallower curve instead of a broken silhouette.
    func testFilletClampsToTheSpaceAvailable() {
        let compact = path(topCornerRadius: 40, width: 297, height: 32, notchWidth: 200)
        XCTAssertTrue(inside(compact, 0.5, 16.5), "past the halfway point the edge is body again")
        XCTAssertGreaterThan(
            (0..<24).filter { inside(compact, 0.5, Double($0) + 0.5) }.count, 0,
            "the compact pill must still have a left edge"
        )
        XCTAssertTrue(inside(compact, 46.5, 1), "the notch lip stays attached to the top edge")
        XCTAssertFalse(inside(compact, 148.5, 1), "the notch itself is still a cutout")
    }

    /// A zero radius keeps the historical hard corner available.
    func testZeroRadiusFillsTheCorners() {
        let sharp = path(topCornerRadius: 0)
        XCTAssertTrue(inside(sharp, 0.5, 0.5))
        XCTAssertTrue(inside(sharp, 559.5, 0.5))
    }
}
