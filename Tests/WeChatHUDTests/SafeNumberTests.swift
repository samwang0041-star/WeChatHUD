import XCTest
@testable import WeChatHUD

/// Numbers that arrive from outside the process must be clamped before any
/// integer conversion.
///
/// `Int(1e30)` is a `_precondition`, not a throw: it traps in release builds
/// too, and no `catch` sees it. A model that answers `"msg": 1e30`, a summary
/// reporting `"noise_ratio": 1e400` or a window mid-relayout was therefore
/// enough to end the process.
final class SafeNumberTests: XCTestCase {

    func testOutOfRangeDoubleSaturatesInsteadOfTrapping() {
        XCTAssertEqual(SafeNumber.clampedInt(1e30, in: 0...100), 100)
        XCTAssertEqual(SafeNumber.clampedInt(-1e30, in: 0...100), 0)
        XCTAssertEqual(SafeNumber.clampedInt(.infinity, in: 0...100), 100)
        XCTAssertEqual(SafeNumber.clampedInt(-.infinity, in: 0...100), 0)
        XCTAssertEqual(SafeNumber.clampedInt(.nan, in: 0...100), 0)
    }

    /// The upper bound itself must not step over `Int.max`: `Double(Int.max)`
    /// is one past the largest `Int`, so the comparison has to happen in
    /// `Double`.
    func testClampedIntHandlesIntMaxBoundary() {
        XCTAssertEqual(SafeNumber.clampedInt(Double(Int.max), in: 0...Int.max), Int.max)
        XCTAssertEqual(SafeNumber.clampedInt(1e300, in: 0...Int.max), Int.max)
    }

    func testClampedKeepsRatiosInsideTheirRange() {
        XCTAssertEqual(SafeNumber.clamped(0.4, to: 0...1), 0.4)
        XCTAssertEqual(SafeNumber.clamped(1e400, to: 0...1), 1)
        XCTAssertEqual(SafeNumber.clamped(-3, to: 0...1), 0)
        XCTAssertEqual(SafeNumber.clamped(.nan, to: 0...1), 0)
    }

    func testExactIntRejectsFractionsAndOutOfRangeValues() {
        XCTAssertEqual(SafeNumber.exactInt(3.0, in: 0...10), 3)
        XCTAssertNil(SafeNumber.exactInt(3.5))
        XCTAssertNil(SafeNumber.exactInt(1e30))
        XCTAssertNil(SafeNumber.exactInt(11.0, in: 1...10))
        XCTAssertNil(SafeNumber.exactInt(0.0, in: 1...10))
    }

    /// The shape a model actually sends for an index: `3`, `3.0` or `"3"`.
    func testJSONIntAcceptsEveryModelShapeAndBoundsIt() {
        XCTAssertEqual(SafeNumber.jsonInt(3, in: 1...5), 3)
        XCTAssertEqual(SafeNumber.jsonInt(3.0, in: 1...5), 3)
        XCTAssertEqual(SafeNumber.jsonInt(" 3 ", in: 1...5), 3)
        XCTAssertNil(SafeNumber.jsonInt(1e30, in: 1...5), "a hostile index must not reach Int(_:)")
        XCTAssertNil(SafeNumber.jsonInt(0, in: 1...5))
        XCTAssertNil(SafeNumber.jsonInt(nil))
        XCTAssertNil(SafeNumber.jsonInt("not a number"))
        XCTAssertNil(SafeNumber.jsonInt(3.5, in: 1...5))
    }
}
