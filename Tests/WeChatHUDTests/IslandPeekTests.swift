import XCTest
import AppKit
@testable import WeChatHUD

final class IslandPeekTests: XCTestCase {
    override func tearDown() {
        CompanionMotion.hoverExpandDelayProvider = { 0.18 }
        CompanionMotion.reduceMotionProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        super.tearDown()
    }

    @MainActor
    func testHoverFromCompactLandsOnPeekNotInbox() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        XCTAssertEqual(state.currentState, .peek)
        XCTAssertEqual(state.presentedState, .peek)
        state.collapse()
    }

    @MainActor
    func testPeekDwellOpensTheInboxWhilePointerStays() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        XCTAssertEqual(state.currentState, .peek)
        state.finishHoverExpandIfPending()
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testLeavingPeekBeforeDwellDoesNotOpenInbox() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        XCTAssertEqual(state.currentState, .peek)
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(state.currentState, .compact)
        state.collapse()
    }

    @MainActor
    func testClickDuringPeekOpensInboxImmediately() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        XCTAssertEqual(state.currentState, .peek)
        state.goExtended()
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testReduceMotionSkipsPeekAndOpensInbox() {
        CompanionMotion.reduceMotionProvider = { true }
        let state = PanelState()
        state.mouseEntered()
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testNotificationMayReplacePeek() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        XCTAssertEqual(state.currentState, .peek)
        state.showNotification(duration: 3)
        XCTAssertEqual(state.currentState, .notification)
        state.collapse()
    }

    @MainActor
    func testReenteringPeekResumesInboxDwell() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        state.mouseExited()
        XCTAssertEqual(state.currentState, .peek)
        state.mouseEntered()
        state.finishHoverExpandIfPending()
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testGoExtendedStillSkipsPeek() {
        let state = PanelState()
        CompactWingRouter.activate(.openInbox, panelState: state)
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testPeekKeepsOutgoingSurfaceUntilTheSpringLands() {
        CompanionMotion.hoverExpandDelayProvider = { 30 }
        let state = PanelState()
        state.mouseEntered()
        state.frameAnimationStarted()
        state.currentState = .compact
        XCTAssertEqual(state.presentedState, .peek,
                       "peek chrome must stay mounted while the mask shrinks")
        state.frameAnimationEnded(mouseInside: false)
        XCTAssertEqual(state.presentedState, .compact)
    }

    func testPeekSlotIsFixedAndWiderThanAWing() {
        XCTAssertEqual(IslandChrome.peekSlotWidth, 78)
        XCTAssertGreaterThan(IslandChrome.peekSlotWidth, CompactInboxMetrics.wingWidth)
        let notch: CGFloat = 180
        let compact = notch + CompactInboxMetrics.wingWidth * 2
        let peek = compact + IslandChrome.peekSlotWidth * 2
        XCTAssertEqual(peek - compact, 156)
    }

    func testOpenAndCloseMorphAreAsymmetric() {
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNotNil(CompanionMotion.openMorph)
        XCTAssertNotNil(CompanionMotion.closeMorph)
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(CompanionMotion.openMorph)
        XCTAssertNil(CompanionMotion.closeMorph)
    }

    func testMaskUsesContinuousCorners() {
        XCTAssertEqual(IslandMaskGeometry.cornerCurve, .continuous)
    }
}
