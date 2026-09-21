import XCTest
import AppKit
import SwiftUI
@testable import WeChatHUD

/// The compositor mask clips whatever the content layer paints, so "may the
/// content be visible right now" is the difference between an island that
/// opens and one that opens onto half a timestamp.
final class IslandContentChoreographyTests: XCTestCase {

    private func restoreMotion() {
        CompanionMotion.reduceMotionProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private func visible(presented: HUDState, current: HUDState, revealed: Bool = true) -> Bool {
        IslandContentChoreography.isVisible(
            family: IslandContentChoreography.family(of: presented),
            midFlight: presented != current,
            revealed: revealed)
    }

    func testBodyContentWaitsForTheSilhouetteToOpen() {
        XCTAssertFalse(visible(presented: .extended, current: .extended, revealed: false),
                       "展开刚开始时收件箱不能出现，否则右列时间会被轮廓切掉一半")
        XCTAssertTrue(visible(presented: .extended, current: .extended, revealed: true))
    }

    func testOutgoingBodyLeavesBeforeTheMaskCutsIt() {
        // A collapse keeps the body mounted so the covering window stays
        // painted; the content itself has to be gone before the mask narrows.
        XCTAssertFalse(visible(presented: .extended, current: .compact, revealed: true))
        XCTAssertFalse(visible(presented: .detail, current: .compact, revealed: true))
    }

    func testAmbientWingsNeverWait() {
        // Hover is compact → peek on the same surface. If the ambient family
        // waited for the reveal, every hover-in would blink.
        XCTAssertTrue(visible(presented: .peek, current: .peek, revealed: false))
        XCTAssertTrue(visible(presented: .compact, current: .compact, revealed: false))
        XCTAssertEqual(IslandContentChoreography.family(of: .compact),
                       IslandContentChoreography.family(of: .peek),
                       "悬停不得换族，否则形变会被重播成一次淡入")
    }

    func testLandingOnAmbientIsInstantSoTheClosedIslandIsNeverEmpty() {
        defer { restoreMotion() }
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNil(IslandContentChoreography.animation(family: .ambient, visible: true),
                     "落回紧凑态要立刻出点，晚 200ms 就是一段空壳")
        XCTAssertNotNil(IslandContentChoreography.animation(family: .body, visible: true))
        XCTAssertNotNil(IslandContentChoreography.animation(family: .body, visible: false))
    }

    func testReduceMotionRemovesEveryCurveButKeepsTheOrdering() {
        defer { restoreMotion() }
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(IslandContentChoreography.animation(family: .body, visible: true))
        XCTAssertNil(IslandContentChoreography.animation(family: .body, visible: false))
        // The rule is still a rule: with no animation the content simply is or
        // isn't, and mid-flight it isn't.
        XCTAssertFalse(visible(presented: .notification, current: .compact, revealed: true))
        XCTAssertFalse(IslandContentChoreography.stagesBodyReveal(reduceMotion: true),
                       "减少动态时不能先藏一帧再放出来，那是一次闪白")
        XCTAssertTrue(IslandContentChoreography.stagesBodyReveal(reduceMotion: false))
    }
}
