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

    /// A banner's in-place surfaces belong to that banner.
    ///
    /// Expanding the briefing card and then receiving the next notification
    /// used to leave `briefingExpanded` set — nothing resets it between two
    /// banners, because `currentState` never leaves `.notification` and the
    /// `didSet` that clears it early-returns on an unchanged value. The banner
    /// that arrived second then rendered the *first* message's briefing card,
    /// so its own text never appeared at all; and because a latched briefing
    /// also latches `popoverOpen`, `showNotification` rejected the new
    /// notification outright — no timer, no auto-dismiss.
    @MainActor
    func testNewNotificationClearsThePreviousBannersInPlaceSurfaces() {
        let state = PanelState()
        state.currentState = .notification
        state.setBriefingExpanded(true)
        XCTAssertTrue(state.briefingExpanded)
        XCTAssertTrue(state.popoverOpen)

        state.showNotification(duration: 30)

        XCTAssertFalse(state.briefingExpanded, "the next banner must not inherit the previous one's briefing card")
        XCTAssertFalse(state.popoverOpen, "the latched popover must not survive into the next banner")
        XCTAssertEqual(state.currentState, .notification)
    }

    /// …but the same card inside the detail view is part of the page, not a
    /// transient surface: a notification arriving behind it must not close
    /// what the user is reading (and the notification is dropped anyway).
    @MainActor
    func testNotificationDoesNotClearABriefingOpenedInsideTheDetailView() {
        let state = PanelState()
        state.currentState = .detail
        state.setBriefingExpanded(true)

        state.showNotification(duration: 30)

        XCTAssertTrue(state.briefingExpanded, "the detail view's own briefing card is not a banner surface")
        XCTAssertEqual(state.currentState, .detail, "a notification must not replace the open detail view")
    }

    /// An open snooze menu is also banner-scoped, and it holds the panel open
    /// the same way.
    @MainActor
    func testNewNotificationClearsAnOpenSnoozeMenu() {
        let state = PanelState()
        state.currentState = .notification
        state.setSnoozeMenuExpanded(true)
        XCTAssertTrue(state.popoverOpen)

        state.showNotification(duration: 30)

        XCTAssertFalse(state.snoozeMenuExpanded)
        XCTAssertFalse(state.popoverOpen)
    }

    /// …but a popover that is *not* one of the banner's surfaces keeps holding
    /// the notification off. Clearing only what a previous banner latched is
    /// what makes this safe; the autopilot review popover is the standing case
    /// for it, and `IslandInteractionTests` pins the plain-popover variant.
    @MainActor
    func testNewNotificationStillYieldsToANonBannerPopover() {
        let state = PanelState()
        state.currentState = .notification
        state.setAutopilotPopoverOpen(true)
        XCTAssertTrue(state.popoverOpen)

        state.showNotification(duration: 30)

        XCTAssertTrue(state.autopilotPopoverOpen, "the autopilot popover is not a banner surface")
        XCTAssertTrue(state.popoverOpen)
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
