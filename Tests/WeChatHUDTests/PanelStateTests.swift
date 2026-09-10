import XCTest
@testable import WeChatHUD

final class PanelStateTests: XCTestCase {
    @MainActor
    func testClosingPopoverAfterMouseExitSchedulesCollapse() {
        let state = PanelState()
        state.currentState = .extended
        state.popoverOpen = true

        state.mouseExited()
        XCTAssertEqual(state.currentState, .extended)

        state.popoverOpen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testClosingMenuAfterStaleMouseInsideResampleCanCollapse() {
        let state = PanelState()
        state.currentState = .extended
        state.updateMouseInside(true)
        state.popoverOpen = true

        state.updateMouseInside(false)
        state.popoverOpen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testBriefingExpansionLatchesPopoverOpenInNotificationAndResetsWhenLeaving() {
        let state = PanelState()
        state.currentState = .notification

        state.setBriefingExpanded(true)
        XCTAssertTrue(state.briefingExpanded)
        XCTAssertTrue(state.popoverOpen)

        state.currentState = .extended
        XCTAssertFalse(state.briefingExpanded)
        XCTAssertFalse(state.popoverOpen)
    }

    @MainActor
    func testBriefingExpansionInDetailDoesNotLatchPopoverOpen() {
        let state = PanelState()
        state.currentState = .detail

        state.setBriefingExpanded(true)
        XCTAssertTrue(state.briefingExpanded)
        XCTAssertFalse(state.popoverOpen)

        state.currentState = .compact
        XCTAssertFalse(state.briefingExpanded)
    }

    @MainActor
    func testNotificationCollapsesOnMouseExit() {
        let state = PanelState()
        state.currentState = .notification
        state.updateMouseInside(true)

        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))

        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testReplyDraftContinuationIsConsumedForMatchingChat() {
        let state = PanelState()
        state.requestReplyDraftContinuation(chatUsername: "alice", text: "已保存的回复")

        XCTAssertNil(state.consumeReplyDraftContinuation(for: "bob"))
        XCTAssertEqual(state.consumeReplyDraftContinuation(for: "alice"), "已保存的回复")
        XCTAssertNil(state.pendingReplyDraftContinuation)
    }

    @MainActor
    func testReplyDraftContinuationReplacesPriorRequestWithFreshIntent() {
        let state = PanelState()
        state.requestReplyDraftContinuation(chatUsername: "alice", text: "旧内容")
        state.requestReplyDraftContinuation(chatUsername: "alice", text: "更新后的内容")

        XCTAssertEqual(state.consumeReplyDraftContinuation(for: "alice"), "更新后的内容")
    }

    @MainActor
    func testReplyDraftContinuationCarriesSavedIdentityOnlyForMatchingChat() {
        let state = PanelState()
        state.requestReplyDraftContinuation(chatUsername: "alice", text: "继续", savedDraftID: 42)

        XCTAssertNil(state.consumeReplyDraftContinuationRequest(for: "bob"))
        let continuation = state.consumeReplyDraftContinuationRequest(for: "alice")
        XCTAssertEqual(continuation?.savedDraftID, 42)
        XCTAssertEqual(continuation?.text, "继续")
    }

    @MainActor
    func testPlainComposerContinuationHasNoSavedIdentity() {
        let state = PanelState()
        state.requestReplyDraftContinuation(chatUsername: "alice", text: "新回复")

        XCTAssertNil(state.consumeReplyDraftContinuationRequest(for: "bob"))
        let continuation = state.consumeReplyDraftContinuationRequest(for: "alice")
        XCTAssertNotNil(continuation)
        XCTAssertNil(continuation?.savedDraftID)
        XCTAssertEqual(continuation?.text, "新回复")
    }

    @MainActor
    func testLastExtendedSizeSurvivesInvalidate() {
        let state = PanelState()
        state.currentState = .extended
        state.reportExtendedSize(CGSize(width: 420, height: 280))
        XCTAssertEqual(state.lastExtendedSize.height, 280)
        state.invalidateMeasuredSize()
        XCTAssertEqual(state.measuredExtendedSize, .zero)
        XCTAssertEqual(state.lastExtendedSize.height, 280)
    }
}
