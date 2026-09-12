import XCTest
@testable import WeChatHUD

final class IslandInteractionTests: XCTestCase {
    @MainActor
    func testHoverPreservesNotificationAndItsControlsPastTimeout() {
        let state = PanelState()
        state.showNotification(duration: 0.1)
        state.mouseEntered()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.currentState, .notification)
        state.collapse()
    }

    @MainActor
    func testIncomingNotificationNeverInterruptsOpenInbox() {
        let state = PanelState()
        state.goExtended()
        state.showNotification(duration: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testIncomingNotificationDoesNotDismissPopover() {
        let state = PanelState()
        state.currentState = .notification
        state.popoverOpen = true
        state.showNotification(duration: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.currentState, .notification)
        XCTAssertTrue(state.popoverOpen)
        state.collapse()
    }

    @MainActor
    func testPreviousNotificationTimeoutCannotCollapseConversation() {
        let state = PanelState()
        state.showNotification(duration: 0.1)
        state.showChatDetail(chatUsername: "test-chat", chatName: "Test")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.currentState, .detail)
        XCTAssertEqual(state.selectedChatUsername, "test-chat")
        state.collapse()
        XCTAssertNil(state.detailKind)
    }

    @MainActor
    func testNewNotificationCancelsOldExitDebounce() {
        let state = PanelState()
        state.goExtended()
        state.mouseExited()
        state.collapse()
        state.showNotification(duration: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .notification)
        state.collapse()
    }

    @MainActor
    func testAnimationRetargetMouseReentryPreventsCollapse() {
        let state = PanelState()
        state.goExtended()
        state.frameAnimationStarted()
        state.mouseExited()
        state.frameAnimationStarted()
        state.mouseEntered()
        state.frameAnimationEnded(mouseInside: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testAutomaticNotificationKeepsDurationAfterFrameAnimationEndsOutside() {
        let state = PanelState()
        state.showNotification(duration: 1.0)
        state.frameAnimationStarted()
        state.frameAnimationEnded(mouseInside: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .notification, "frame completion must not replace the banner timer with 0.4s collapse")
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .compact, "an untouched banner still respects its configured duration")
    }

    @MainActor
    func testAutomaticNotificationIgnoresSyntheticExitDuringExpansion() {
        let state = PanelState()
        state.showNotification(duration: 3)
        state.frameAnimationStarted()
        state.mouseExited()
        state.frameAnimationEnded(mouseInside: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .notification)
        state.collapse()
    }

    @MainActor
    func testRealHoverThenExitDuringAnimationCollapsesAfterDebounce() {
        let state = PanelState()
        state.showNotification(duration: 12)
        state.frameAnimationStarted()
        state.mouseEntered()
        state.mouseExited()
        state.frameAnimationEnded(mouseInside: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testReducedMotionSynchronousCompletionDoesNotShortenNotification() {
        let state = PanelState()
        // AppDelegate's @Published sink can finish a reduced-motion resize
        // before the new state has been assigned by showNotification.
        state.frameAnimationStarted()
        state.frameAnimationEnded(mouseInside: false)
        state.showNotification(duration: 3)
        state.frameAnimationStarted()
        state.frameAnimationEnded(mouseInside: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .notification)
        state.collapse()
    }

    @MainActor
    func testRapidEnterExitTenTimesDoesNotCollapseUntilLeaveSettles() {
        let state = PanelState()
        state.goExtended()
        for _ in 0..<10 {
            state.mouseEntered()
            state.mouseExited()
            state.mouseEntered()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .compact)
        state.collapse()
    }

    @MainActor
    func testSnoozeMenuKeepsNotificationOpenAndGrows() {
        let state = PanelState()
        state.showNotification(duration: 0.2)
        state.setSnoozeMenuExpanded(true)
        XCTAssertTrue(state.snoozeMenuExpanded)
        XCTAssertTrue(state.popoverOpen)
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .notification)
        state.setSnoozeMenuExpanded(false)
        state.collapse()
        XCTAssertFalse(state.snoozeMenuExpanded)
    }

    @MainActor
    func testCollapseClearsTransientIslandHolds() {
        let state = PanelState()
        state.goExtended()
        state.popoverOpen = true
        state.menuTrackingOpen = true
        state.setSnoozeMenuExpanded(true)
        state.islandTextInputActive = true
        state.collapse()
        XCTAssertFalse(state.popoverOpen)
        XCTAssertFalse(state.menuTrackingOpen)
        XCTAssertFalse(state.snoozeMenuExpanded)
        XCTAssertFalse(state.islandTextInputActive)
        XCTAssertEqual(state.currentState, .compact)
    }

    @MainActor
    func testClosingSnoozeDoesNotClearAutopilotHold() {
        let state = PanelState()
        state.goExtended()
        state.setAutopilotPopoverOpen(true)
        XCTAssertTrue(state.popoverOpen)
        state.setSnoozeMenuExpanded(true)
        state.setSnoozeMenuExpanded(false)
        XCTAssertTrue(state.autopilotPopoverOpen)
        XCTAssertTrue(state.popoverOpen)
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testRenameSheetHoldsIslandOpen() {
        let state = PanelState()
        state.goExtended()
        state.islandTextInputActive = true
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        XCTAssertTrue(state.islandTextInputActive)
        state.islandTextInputActive = false
        state.collapse()
    }

    @MainActor
    func testMenuTrackingDoesNotClearAutopilotPopoverLatch() {
        let state = PanelState()
        state.goExtended()
        state.popoverOpen = true
        state.menuTrackingOpen = true
        state.menuTrackingOpen = false
        XCTAssertTrue(state.popoverOpen)
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        state.collapse()
    }

    @MainActor
    func testSnoozePopoverKeepsIslandOpen() {
        let state = PanelState()
        state.goExtended()
        state.popoverOpen = true
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        state.popoverOpen = false
        state.collapse()
    }

    @MainActor
    func testNewNotificationClearsPreviousSnoozeReceipt() {
        let state = PanelState()
        let item = InboxItem(
            id: "preview-project", chatUsername: "preview-project", chatName: "项目协作群",
            senderName: "林晓", preview: "评审", isGroup: true, timestamp: Date(),
            actionRequired: true, priority: .p1, isVIP: false, isWhitelisted: true,
            unreadCount: 1, isAtMention: true, askType: .yesNo, reasons: [], suggestedReplyMinutes: 60,
            status: .active, aiSummary: nil, moodEmoji: nil
        )
        state.islandSnoozeUndo = (item, Date().addingTimeInterval(1800))
        state.toastMessage = CompanionProductCopy.snoozeReceipt(until: Date().addingTimeInterval(1800))
        state.showNotification(duration: 0.2)
        XCTAssertEqual(state.currentState, .notification)
        XCTAssertNil(state.islandSnoozeUndo)
        XCTAssertNil(state.toastMessage)
        state.collapse()
    }

    @MainActor
    func testIncomingNotificationDoesNotStealConversationDetail() {
        let state = PanelState()
        state.showChatDetail(chatUsername: "preview-colleague", chatName: "林晓")
        state.showNotification(duration: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.currentState, .detail)
        XCTAssertEqual(state.selectedChatUsername, "preview-colleague")
        state.collapse()
    }

    @MainActor
    func testConversationDetailDoesNotCollapseOnMouseLeave() {
        let state = PanelState()
        state.showChatDetail(chatUsername: "preview-colleague", chatName: "林晓")
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .detail)
        state.collapse()
    }

    @MainActor
    func testTaskPreviewDoesNotCollapseWhenMouseLeaves() {
        let state = PanelState()
        state.goExtended()
        state.islandSurface = .tasks
        state.mouseEntered()
        state.mouseExited()
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        XCTAssertEqual(state.currentState, .extended)
        XCTAssertEqual(state.islandSurface, .tasks)
        state.collapse()
        XCTAssertEqual(state.islandSurface, .inbox)
    }

    func testIslandScreenPolicyPrefersNotchedBuiltInAndSeparateExternal() {
        let builtIn = IslandScreenPolicy.Candidate(id: 1, isBuiltIn: true, hasNotch: true, name: "Built-in Retina Display")
        let external = IslandScreenPolicy.Candidate(id: 2, isBuiltIn: false, hasNotch: false, name: "U2790B")
        XCTAssertEqual(IslandScreenPolicy.pick(preference: .builtIn, screens: [external, builtIn]), builtIn)
        XCTAssertEqual(IslandScreenPolicy.pick(preference: .external, screens: [builtIn, external]), external)
        XCTAssertEqual(IslandScreenPolicy.pick(preference: .external, screens: [builtIn]), builtIn)
        XCTAssertNil(IslandScreenPolicy.pick(preference: .builtIn, screens: []))
    }

    func testCompactWingsStayOutsideTheNotchVoid() {
        let wing = CompactInboxMetrics.wingWidth
        XCTAssertEqual(wing, CompactInboxMetrics.wingWidth)
        XCTAssertGreaterThanOrEqual(wing, 52)
        let realNotch: CGFloat = 180
        let bar = wing + realNotch + wing
        XCTAssertEqual(bar - realNotch, wing * 2)
        let fake = NotchGeometry(hasRealNotch: false, notchWidth: 16, notchHeight: 32, notchCenterX: 720)
        XCTAssertFalse(fake.hasRealNotch)
        XCTAssertLessThan(fake.notchWidth, wing)
        XCTAssertGreaterThan(fake.notchHeight, 0)
    }

    @MainActor
    func testCollapseKeepsOutgoingSurfaceUntilTheSpringLands() {
        let state = PanelState()
        state.goExtended()
        XCTAssertEqual(state.presentedState, .extended)
        state.frameAnimationStarted()
        state.currentState = .compact
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(state.presentedState, .extended,
                       "the inbox must stay mounted while the mask shrinks")
        state.frameAnimationEnded(mouseInside: false)
        XCTAssertEqual(state.presentedState, .compact)
    }

    @MainActor
    func testExpandPaintsTheInboxImmediately() {
        let state = PanelState()
        state.currentState = .extended
        XCTAssertEqual(state.presentedState, .extended)
    }

}
