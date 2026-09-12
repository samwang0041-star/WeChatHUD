import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// The detail panel's dead end and its inline notice.
///
/// Two separate ways the panel could leave the user stuck: a conversation
/// routed without its chat name rendered a blank pane with no exit, and the
/// urgent-message notice that sits on top of every detail page could only be
/// acted on, never dismissed.
@MainActor
final class DetailNoticeTests: XCTestCase {

    // MARK: - The empty pane is a named exit, not a blank page

    func testTheEmptyDetailPaneOffersAWayBackToTheInbox() {
        let state = PanelState()
        state.showDetail(kind: .conversation(chatUsername: "peer"), chatName: nil)
        XCTAssertEqual(state.currentState, .detail)
        XCTAssertNotNil(state.detailKind)

        DetailPanelRouting.returnToInbox(state)

        XCTAssertNil(state.detailKind, "返回收件箱必须清掉详情目标")
        XCTAssertNil(state.selectedChatName)
        XCTAssertEqual(state.currentState, .extended, "返回收件箱必须真的回到收件箱")
    }

    func testTheEmptyPaneCopyNamesTheProblemAndTheExit() {
        XCTAssertTrue(MissingChatPaneCopy.title.contains("缺失"), "空态必须说出问题，实际 \(MissingChatPaneCopy.title)")
        XCTAssertFalse(MissingChatPaneCopy.detail.isEmpty)
        XCTAssertEqual(MissingChatPaneCopy.action, "返回收件箱")
    }

    // MARK: - The notice's suppression rule

    func testNoticeIsSuppressedOnlyForTheMessageThatWasClosed() {
        let item = noticeItem(chatUsername: "chat-b", messageID: "m1")

        XCTAssertNotNil(DetailPanelView.noticeItem(
            top: item, selectedChatUsername: "chat-a", isDetail: true, closedKey: nil
        ))
        XCTAssertNil(DetailPanelView.noticeItem(
            top: item, selectedChatUsername: "chat-a", isDetail: true, closedKey: "m1"
        ), "关掉的那条不能继续占住详情页顶部")
        XCTAssertNotNil(DetailPanelView.noticeItem(
            top: item, selectedChatUsername: "chat-a", isDetail: true, closedKey: "m0"
        ), "同会话的下一條消息必须重新出现")
        XCTAssertNil(DetailPanelView.noticeItem(
            top: item, selectedChatUsername: "chat-a", isDetail: false, closedKey: nil
        ), "只有详情页才显示这条提醒")
        XCTAssertNil(DetailPanelView.noticeItem(
            top: item, selectedChatUsername: "chat-b", isDetail: true, closedKey: nil
        ), "正在看的会话不该再被提醒一次")
    }

    func testQuietMessagesNeverGetANotice() {
        let quiet = noticeItem(chatUsername: "chat-b", messageID: "m1", priority: .p2)
        XCTAssertNil(DetailPanelView.noticeItem(
            top: quiet, selectedChatUsername: "chat-a", isDetail: true, closedKey: nil
        ))
    }

    func testClosingIsRememberedByTheViewsOwnState() {
        let notice = DetailNoticeState()
        XCTAssertTrue(notice.shows("m1"))

        notice.close("m1")

        XCTAssertFalse(notice.shows("m1"))
        XCTAssertTrue(notice.shows("m2"), "关掉一条不影响下一条")
        XCTAssertEqual(notice.closedKey, "m1")
    }

    // MARK: - The notice's real click contract

    func testClickingTheNoticeCloseOnlyCloses() {
        let state = PanelState()
        state.goExtended()
        var closed = 0
        let bar = noticeBar(chatUsername: "chat-b", messageID: "m1", state: state) { closed += 1 }
        let window = host(bar, state: state)
        defer { window.orderOut(nil) }

        click(window, at: closeSlotCenter)

        XCTAssertEqual(closed, 1, "关闭按钮必须调用关闭回调")
        XCTAssertEqual(state.currentState, .extended, "关闭不是查看：不能顺带跳转")
    }

    func testClickingTheNoticeViewStillOpensTheInbox() {
        let state = PanelState()
        state.goExtended()
        var closed = 0
        let bar = noticeBar(chatUsername: "chat-b", messageID: "m1", state: state) { closed += 1 }
        let window = host(bar, state: state)
        defer { window.orderOut(nil) }
        // Start somewhere the notice has to move from, so the click is the only
        // thing that can change the state.
        state.currentState = .detail

        click(window, at: viewSlotCenter)

        XCTAssertEqual(state.currentState, .extended, "[查看] 仍然回到收件箱")
        XCTAssertEqual(closed, 0, "[查看] 不是关闭")
    }

    // MARK: - Fixtures

    private let barWidth: CGFloat = 580
    private let barHeight: CGFloat = 36

    /// The 关闭 slot is the trailing 22 × 18 control, inset by the bar's own
    /// `sectionInset`. The 查看 label sits one 7 pt gap to its left.
    private var closeSlotCenter: NSPoint {
        NSPoint(x: barWidth - IslandMetrics.sectionInset - 11, y: barHeight / 2)
    }

    private var viewSlotCenter: NSPoint {
        NSPoint(x: barWidth - IslandMetrics.sectionInset - 22 - 7 - 12, y: barHeight / 2)
    }

    private func noticeItem(
        chatUsername: String,
        messageID: String,
        priority: InboxPriority = .p1
    ) -> InboxItem {
        let notification = HUDNotification(
            chatUsername: chatUsername,
            chatName: "项目协作群",
            senderUsername: "wxid-peer",
            senderName: "林晓",
            attentionLevel: .vip,
            messageID: messageID,
            rawText: "明天下午评审",
            snippet: "明天下午评审",
            isAtMention: true,
            timestamp: Date(),
            kind: .groupAt
        )
        return InboxItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: "项目协作群",
            senderName: "林晓",
            preview: "明天下午评审",
            isGroup: true,
            timestamp: Date(),
            actionRequired: true,
            priority: priority,
            isVIP: true,
            isWhitelisted: true,
            unreadCount: 1,
            isAtMention: true,
            askType: .none,
            reasons: [],
            suggestedReplyMinutes: 60,
            status: .active,
            dismissedAtMsgId: nil,
            aiSummary: "需要你确认评审时间",
            moodEmoji: nil,
            contextNotification: notification
        )
    }

    private func noticeBar(
        chatUsername: String,
        messageID: String,
        state: PanelState,
        onClose: @escaping () -> Void
    ) -> some View {
        DetailNoticeBar(
            item: noticeItem(chatUsername: chatUsername, messageID: messageID),
            onClose: onClose
        )
        .environmentObject(state)
    }

    private func host(_ bar: some View, state: PanelState) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: barHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: bar.frame(width: barWidth, height: barHeight))
        hosting.frame = NSRect(x: 0, y: 0, width: barWidth, height: barHeight)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                XCTFail("could not synthesise a mouse event")
                return
            }
            window.sendEvent(event)
            pump(0.03)
        }
        pump()
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
