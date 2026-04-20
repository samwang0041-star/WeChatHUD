import XCTest
@testable import WeChatHUD

final class InboxBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func makeDebtItem(
        chatUsername: String = "wxid_test",
        chatName: String = "Test",
        senderName: String = "Sender",
        preview: String = "Hello",
        isGroup: Bool = false,
        isVIP: Bool = false,
        isWhitelisted: Bool = true,
        isAtMention: Bool = false,
        priority: ReplyDebtPriority = .p1,
        score: Int = 6,
        unreadCount: Int = 1,
        timestamp: Date = Date()
    ) -> ReplyDebtItem {
        ReplyDebtItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: senderName,
            preview: preview,
            latestOutboundPreview: nil,
            timestamp: timestamp,
            priority: priority,
            score: score,
            unreadCount: unreadCount,
            isGroup: isGroup,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            isAtMention: isAtMention,
            inboundCountSinceLastOutbound: 1,
            reasons: [],
            suggestedReplyMinutes: 30
        )
    }

    private func makeNotification(
        chatUsername: String = "wxid_vip",
        chatName: String = "VIP",
        senderName: String = "Boss",
        snippet: String = "FYI info",
        attentionLevel: WhitelistAttentionLevel = .vip,
        isAtMention: Bool = false,
        timestamp: Date = Date()
    ) -> HUDNotification {
        HUDNotification(
            chatUsername: chatUsername,
            chatName: chatName,
            senderUsername: "sender_u",
            senderName: senderName,
            attentionLevel: attentionLevel,
            messageID: "1",
            rawText: snippet,
            snippet: snippet,
            isAtMention: isAtMention,
            timestamp: timestamp,
            kind: .privateChat
        )
    }

    // MARK: - Tests

    func testDebtItemBecomesActionRequired() {
        let debt = makeDebtItem(priority: .p0)
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].actionRequired)
        XCTAssertEqual(items[0].priority, .p0)
    }

    func testNotificationOnlyBecomesInfoItem() {
        let notif = makeNotification(chatUsername: "wxid_info", attentionLevel: .watch, isAtMention: false)
        let items = InboxBuilder.build(replyDebtItems: [], notifications: [notif], dismissed: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].actionRequired)
        XCTAssertEqual(items[0].priority, .p2)
    }

    func testDebtAndNotificationSameChatDeduplicates() {
        let debt = makeDebtItem(chatUsername: "wxid_shared")
        let notif = makeNotification(chatUsername: "wxid_shared")
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [notif], dismissed: [:])
        XCTAssertEqual(items.count, 1, "same chatUsername should dedup to 1 item")
        XCTAssertTrue(items[0].actionRequired, "debt takes precedence")
    }

    func testSortOrderPriorityThenTime() {
        let old = makeDebtItem(chatUsername: "wxid_old", priority: .p1, score: 6, timestamp: Date().addingTimeInterval(-600))
        let urgent = makeDebtItem(chatUsername: "wxid_urgent", priority: .p0, score: 9, timestamp: Date().addingTimeInterval(-60))
        let items = InboxBuilder.build(replyDebtItems: [old, urgent], notifications: [], dismissed: [:])
        XCTAssertEqual(items[0].chatUsername, "wxid_urgent", "p0 should come first")
        XCTAssertEqual(items[1].chatUsername, "wxid_old")
    }

    func testActionRequiredBeforeInfoOnly() {
        let action = makeDebtItem(chatUsername: "wxid_action", priority: .p1)
        let info = makeNotification(chatUsername: "wxid_info", attentionLevel: .watch)
        let items = InboxBuilder.build(replyDebtItems: [action], notifications: [info], dismissed: [:])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].actionRequired)
        XCTAssertFalse(items[1].actionRequired)
    }

    func testDismissedItemFiltered() {
        let debt = makeDebtItem(chatUsername: "wxid_dismissed")
        let dismissed: [String: Int64] = ["wxid_dismissed": 999]
        let items = InboxBuilder.build(replyDebtItems: [debt], notifications: [], dismissed: dismissed)
        // ReplyDebtItems always reactivate (debt existing = newer message)
        XCTAssertEqual(items.count, 1, "debt items always reactivate regardless of dismiss")
    }

    func testDismissedNotificationReactivatesOnNewerInbound() {
        // Notification timestamp is "now"; dismiss mark is far in the
        // past → the dismissal is stale and the chat should surface.
        // Mirrors the debt-item reactivation rule. Fixes the bug where
        // one "忽略" click silenced a chat forever.
        let notif = makeNotification(chatUsername: "wxid_reactivated", attentionLevel: .watch)
        let dismissed: [String: Int64] = ["wxid_reactivated": 999]
        let items = InboxBuilder.build(replyDebtItems: [], notifications: [notif], dismissed: dismissed)
        XCTAssertEqual(items.count, 1, "notification newer than dismiss mark should resurface")
    }

    func testDismissedNotificationStaysHandledWhenOlderThanDismissMark() {
        // Dismissal mark "now", notification "old" → still dismissed.
        // Confirms the dismiss-then-show-stale-notif path.
        let staleNotif = makeNotification(
            chatUsername: "wxid_stale",
            attentionLevel: .watch,
            timestamp: Date(timeIntervalSince1970: 1000)
        )
        let dismissed: [String: Int64] = ["wxid_stale": Int64(Date().timeIntervalSince1970)]
        let items = InboxBuilder.build(replyDebtItems: [], notifications: [staleNotif], dismissed: dismissed)
        XCTAssertTrue(items.isEmpty, "stale notification (timestamp < dismissTs) stays handled")
    }

    func testInfoItemsCappedAtFive() {
        let notifs = (0..<10).map { i in
            makeNotification(chatUsername: "wxid_\(i)", chatName: "Chat\(i)", attentionLevel: .watch)
        }
        let items = InboxBuilder.build(replyDebtItems: [], notifications: notifs, dismissed: [:])
        let infoItems = items.filter { !$0.actionRequired }
        XCTAssertEqual(infoItems.count, 5, "info-only items capped at 5")
    }

    func testVIPNotificationWithAtMentionIsActionRequired() {
        let notif = makeNotification(chatUsername: "wxid_vip_at", attentionLevel: .vip, isAtMention: true)
        let items = InboxBuilder.build(replyDebtItems: [], notifications: [notif], dismissed: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].actionRequired, "@mention from VIP is action-required")
        XCTAssertEqual(items[0].priority, .p0)
    }
}
