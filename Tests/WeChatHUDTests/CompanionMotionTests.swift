import XCTest
@testable import WeChatHUD

final class CompanionMotionTests: XCTestCase {

    override func tearDown() {
        CompanionMotion.reduceMotionProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        CompanionMotion.reduceTransparencyProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        super.tearDown()
    }

    func testAllAnimationsNilWhenReduceMotion() {
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertTrue(CompanionMotion.reduceMotion)
        XCTAssertNil(CompanionMotion.ease(0.2))
        XCTAssertNil(CompanionMotion.ease())
        XCTAssertNil(CompanionMotion.easeIn(0.2))
        XCTAssertNil(CompanionMotion.easeOut(0.25))
        XCTAssertNil(CompanionMotion.spring)
        XCTAssertNil(CompanionMotion.springResponse(response: 0.6, dampingFraction: 0.8))
        XCTAssertNil(CompanionMotion.press())
        XCTAssertNil(CompanionMotion.systemDefault)
        XCTAssertNil(CompanionMotion.hover())
        XCTAssertNil(CompanionMotion.islandExpand())
        XCTAssertNil(CompanionMotion.islandCollapse())
        XCTAssertNil(CompanionMotion.pageChange())
        XCTAssertNil(CompanionMotion.rowExpand())
        XCTAssertNil(CompanionMotion.drawer())
        XCTAssertNil(CompanionMotion.dialog())
        XCTAssertNil(CompanionMotion.complete())
        XCTAssertNil(CompanionMotion.saveReceipt())
    }

    func testAllAnimationsNonNilWhenMotionEnabled() {
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertFalse(CompanionMotion.reduceMotion)
        XCTAssertNotNil(CompanionMotion.ease(0.2))
        XCTAssertNotNil(CompanionMotion.ease())
        XCTAssertNotNil(CompanionMotion.easeIn(0.2))
        XCTAssertNotNil(CompanionMotion.easeOut(0.25))
        XCTAssertNotNil(CompanionMotion.spring)
        XCTAssertNotNil(CompanionMotion.springResponse(response: 0.6, dampingFraction: 0.8))
        XCTAssertNotNil(CompanionMotion.press())
        XCTAssertNotNil(CompanionMotion.systemDefault)
        XCTAssertNotNil(CompanionMotion.hover())
        XCTAssertNotNil(CompanionMotion.islandExpand())
        XCTAssertNotNil(CompanionMotion.islandCollapse())
        XCTAssertNotNil(CompanionMotion.rowExpand())
        XCTAssertNotNil(CompanionMotion.drawer())
        XCTAssertNotNil(CompanionMotion.dialog())
        XCTAssertNotNil(CompanionMotion.complete())
        XCTAssertNotNil(CompanionMotion.saveReceipt())
        XCTAssertNotNil(CompanionMotion.pageChange())
    }

    func testIslandFrameTimingReportsSixtyHertzCadence() {
        IslandFrameTiming.begin()
        var t = 100.0
        IslandFrameTiming.tick(uptime: t)
        for _ in 0..<12 {
            t += 1.0 / 60.0
            IslandFrameTiming.tick(uptime: t)
        }
        IslandFrameTiming.finish(duration: 0.23)
        XCTAssertEqual(IslandFrameTiming.lastDuration, 0.23, accuracy: 0.001)
        XCTAssertGreaterThan(IslandFrameTiming.estimatedFPS, 58)
        XCTAssertLessThan(IslandFrameTiming.estimatedFPS, 62)
        IslandFrameTiming.recordInstant()
        XCTAssertTrue(IslandFrameTiming.lastWasInstant)
    }

    func testWithMotionRunsBodyWithoutAnimationWhenNil() {
        var executed = false
        withMotion(nil) { executed = true }
        XCTAssertTrue(executed)
    }

    func testReduceTransparencyIsReadableIndependentlyOfMotion() {
        CompanionMotion.reduceTransparencyProvider = { true }
        XCTAssertTrue(CompanionMotion.reduceTransparency)
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNotNil(CompanionMotion.pageChange())
        CompanionMotion.reduceTransparencyProvider = { false }
        XCTAssertFalse(CompanionMotion.reduceTransparency)
    }

    func testIslandExpandProgressPopsOutThenSettles() {
        XCTAssertEqual(IslandMotion.expandProgress(0), 0, accuracy: 0.01)
        XCTAssertEqual(IslandMotion.expandProgress(1), 1, accuracy: 0.02)
        XCTAssertGreaterThan(IslandMotion.expandProgress(0.62), 1.0)
        XCTAssertGreaterThan(IslandMotion.expandDuration, IslandMotion.collapseDuration)
        XCTAssertEqual(IslandChrome.expandedWidth, 560)
    }

    func testIslandCollapseProgressAcceleratesIntoTheNotch() {
        XCTAssertEqual(IslandMotion.collapseProgress(0), 0, accuracy: 0.001)
        XCTAssertEqual(IslandMotion.collapseProgress(1), 1, accuracy: 0.001)
        XCTAssertLessThan(IslandMotion.collapseProgress(0.5), 0.2)
        XCTAssertTrue(IslandMotion.isExpanding(
            from: NSRect(x: 0, y: 0, width: 200, height: 32),
            to: NSRect(x: 0, y: 0, width: 560, height: 320)
        ))
        XCTAssertFalse(IslandMotion.isExpanding(
            from: NSRect(x: 0, y: 0, width: 560, height: 320),
            to: NSRect(x: 0, y: 0, width: 200, height: 32)
        ))
    }

    func testWithMotionRunsBodyWithAnimationWhenProvided() {
        CompanionMotion.reduceMotionProvider = { false }
        var executed = false
        withMotion(CompanionMotion.ease(0.2)) { executed = true }
        XCTAssertTrue(executed)
    }

    func testRetargetToleranceIgnoresLayoutJitterMidFlight() {
        // At rest the panel hugs measurements tightly; mid-flight only a
        // genuine content change (row expand, snooze menu — all 50 pt+)
        // may bend the trajectory, never 1–3 pt of text-settling jitter.
        XCTAssertEqual(IslandMotion.retargetTolerance(isAnimating: false), 2)
        XCTAssertEqual(IslandMotion.retargetTolerance(isAnimating: true), 6)
        XCTAssertGreaterThan(IslandMotion.retargetTolerance(isAnimating: true), 3)
        XCTAssertLessThan(IslandMotion.retargetTolerance(isAnimating: true), 50)
    }

    func testMaskCornerRadiusCapsulesTheCompactBar() {
        XCTAssertEqual(IslandMotion.maskCornerRadius(width: 297, height: 32), 16)
        XCTAssertEqual(IslandMotion.maskCornerRadius(width: 560, height: 252), 22)
    }

    func testStrongEaseOutRespectsReduceMotion() {
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNotNil(CompanionMotion.strongEaseOut())
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(CompanionMotion.strongEaseOut())
    }

    /// A press has to be visible. 1.0 is a no-op and anything at or below
    /// 0.92 reads as rubber, so the token is pinned inside the usable band.
    func testPressScaleIsInsideTheVisibleButNotRubberyBand() {
        XCTAssertGreaterThanOrEqual(CompanionMotion.pressScale, 0.92)
        XCTAssertLessThanOrEqual(CompanionMotion.pressScale, 0.97)
        XCTAssertLessThan(CompanionMotion.pressScale, 1)
    }
}
