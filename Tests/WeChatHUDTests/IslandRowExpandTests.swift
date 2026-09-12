import XCTest
import AppKit
@testable import WeChatHUD

final class IslandRowExpandTests: XCTestCase {

    func testCoveringStageMeasurementIsTheWindowNotTheInbox() {
        let content = CGSize(width: 560, height: 188)
        let cover = CGSize(width: 700, height: 500)
        XCTAssertTrue(IslandMeasurement.isCoveringStage(cover, cover: cover, lastContent: content),
                      "a report that matches the grow-only stage is the proposal, not the list")
        XCTAssertFalse(IslandMeasurement.isCoveringStage(content, cover: cover, lastContent: content))
        XCTAssertFalse(IslandMeasurement.isCoveringStage(CGSize(width: 560, height: 260), cover: cover, lastContent: content),
                       "a real row expand is taller than the last list but is not the stage")
    }

    func testFirstMeasurementIsNeverTreatedAsTheStage() {
        let cover = CGSize(width: 700, height: 500)
        XCTAssertFalse(IslandMeasurement.isCoveringStage(cover, cover: cover, lastContent: .zero))
    }

    func testClampedHeightNeverExceedsTheInboxCeiling() {
        let huge = IslandMeasurement.clamped(CGSize(width: 560, height: 4000))
        XCTAssertEqual(huge.height, IslandMeasurement.maxExtendedHeight)
        XCTAssertEqual(IslandMeasurement.clamped(.zero), .zero)
    }

    func testRowExpandUsesTheIslandOpenSpring() {
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNotNil(CompanionMotion.rowExpand())
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(CompanionMotion.rowExpand())
        CompanionMotion.reduceMotionProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    @MainActor
    func testClickingARowExpandsOnlyThatRow() {
        let state = PanelState()
        state.goExtended()
        state.expandedInboxItemID = "chat-a"
        XCTAssertEqual(state.expandedInboxItemID, "chat-a")
        state.expandedInboxItemID = "chat-b"
        XCTAssertEqual(state.expandedInboxItemID, "chat-b")
        state.collapse()
        XCTAssertNil(state.expandedInboxItemID)
    }

    @MainActor
    func testLeavingExtendedClearsTheOpenRow() {
        let state = PanelState()
        state.goExtended()
        state.expandedInboxItemID = "chat-a"
        state.showChatDetail(chatUsername: "chat-a", chatName: "A")
        XCTAssertEqual(state.currentState, .detail)
        XCTAssertNil(state.expandedInboxItemID)
        state.collapse()
    }

    // MARK: - The measurement sink's snap-vs-animate decision

    /// Peek is the same-height width morph (compact + two outboard slots).
    /// A wider report arriving mid-hover MUST animate: snapping calls
    /// `setFrameInstantly`, which cancels the mask spring the morph is riding,
    /// and the pill visibly jumps.
    func testPeekWideningMidAnimationAnimates() {
        let action = IslandMeasurement.sizeAction(
            state: .peek,
            visible: CGSize(width: 412, height: 32),
            target: CGSize(width: 568, height: 32),
            isAnimating: true
        )
        XCTAssertEqual(action, .animate)
    }

    /// The same-height width morph still animates when nothing is in flight
    /// (e.g. the peek slot measurement lands on the first layout pass).
    func testPeekWidthChangeAtRestAnimatesRatherThanSnapping() {
        let action = IslandMeasurement.sizeAction(
            state: .peek,
            visible: CGSize(width: 412, height: 32),
            target: CGSize(width: 568, height: 32),
            isAnimating: false
        )
        XCTAssertEqual(action, .animate)
    }

    func testPeekAlreadyAtTargetIsIgnored() {
        let action = IslandMeasurement.sizeAction(
            state: .peek,
            visible: CGSize(width: 568, height: 32),
            target: CGSize(width: 568, height: 32),
            isAnimating: true
        )
        XCTAssertEqual(action, .ignore)
    }

    /// Sub-pixel jitter at rest is filtered by the 2 pt resting tolerance.
    func testRestingJitterIsIgnored() {
        let action = IslandMeasurement.sizeAction(
            state: .extended,
            visible: CGSize(width: 560, height: 188),
            target: CGSize(width: 561, height: 189),
            isAnimating: false
        )
        XCTAssertEqual(action, .ignore)
    }

    /// While a spring is running the bar rises to 6 pt: layout-pass text
    /// settling must not bend the trajectory.
    func testMidFlightJitterUpToTheAnimatingToleranceIsIgnored() {
        let action = IslandMeasurement.sizeAction(
            state: .extended,
            visible: CGSize(width: 560, height: 188),
            target: CGSize(width: 565, height: 192),
            isAnimating: true
        )
        XCTAssertEqual(action, .ignore)
    }

    /// A compact-only width change (idle → pending → urgent wing relayout) is
    /// layout jitter, not motion: it snaps back to the notch center.
    func testCompactWidthOnlyChangeSnaps() {
        let action = IslandMeasurement.sizeAction(
            state: .compact,
            visible: CGSize(width: 312, height: 32),
            target: CGSize(width: 336, height: 32),
            isAnimating: false
        )
        XCTAssertEqual(action, .snapInstantly)
    }

    /// Peek → compact is the same-height width morph in reverse. A mid-flight
    /// snap would cancel the mask spring and jump the pill back into the notch.
    func testCompactCollapseFromPeekWidthDoesNotSnap() {
        let action = IslandMeasurement.sizeAction(
            state: .compact,
            visible: CGSize(width: 568, height: 32),
            target: CGSize(width: 412, height: 32),
            isAnimating: true
        )
        XCTAssertEqual(action, .ignore,
                       "the currentState-driven spring already owns this morph")
    }

    /// If the peek-width measurement lands before the spring starts, still
    /// animate — never snap a 156 pt silhouette change.
    func testCompactCollapseFromPeekWidthAtRestAnimates() {
        let action = IslandMeasurement.sizeAction(
            state: .compact,
            visible: CGSize(width: 568, height: 32),
            target: CGSize(width: 412, height: 32),
            isAnimating: false
        )
        XCTAssertEqual(action, .animate)
    }

    /// Compact collapsing out of a taller island (a real leave) animates.
    func testCompactCollapseFromTallerIslandAnimates() {
        let action = IslandMeasurement.sizeAction(
            state: .compact,
            visible: CGSize(width: 560, height: 200),
            target: CGSize(width: 312, height: 32),
            isAnimating: true
        )
        XCTAssertEqual(action, .animate)
    }

    /// The 8 pt band: a compact target a hair taller than the visible bar is
    /// still a width relayout, not a collapse.
    func testCompactShallowHeightChangeStillSnaps() {
        let action = IslandMeasurement.sizeAction(
            state: .compact,
            visible: CGSize(width: 312, height: 36),
            target: CGSize(width: 336, height: 32),
            isAnimating: false
        )
        XCTAssertEqual(action, .snapInstantly)
    }

    /// Every state that has left the notch animates, because the covering
    /// window is already at the destination and only the mask moves.
    func testExpandedStatesAnimate() {
        for state: HUDState in [.extended, .notification, .detail] {
            XCTAssertEqual(
                IslandMeasurement.sizeAction(
                    state: state,
                    visible: CGSize(width: 560, height: 200),
                    target: CGSize(width: 600, height: 340),
                    isAnimating: true
                ),
                .animate,
                "\(state) must ride the spring, never snap"
            )
        }
    }
}
