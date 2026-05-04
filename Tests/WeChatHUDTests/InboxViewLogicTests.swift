import XCTest
@testable import WeChatHUD

final class InboxViewLogicTests: XCTestCase {

    private func makeItem(
        chatUsername: String,
        actionRequired: Bool,
        priority: InboxPriority = .p2,
        isGroup: Bool = false,
        isAtMention: Bool = false,
        isVIP: Bool = false,
        reasons: [ReplyDebtReason] = []
    ) -> InboxItem {
        InboxItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatUsername,
            senderName: "Sender",
            preview: "Preview",
            isGroup: isGroup,
            timestamp: Date(),
            actionRequired: actionRequired,
            priority: priority,
            isVIP: isVIP,
            isWhitelisted: true,
            unreadCount: 0,
            isAtMention: isAtMention,
            askType: .none,
            reasons: reasons,
            suggestedReplyMinutes: 0,
            status: .active,
            dismissedAtMsgId: nil
        )
    }

    private func compactTopItem(_ items: [InboxItem]) -> InboxItem? {
        let surfaced = items.filter { $0.surfacesInCompact }
        let actionItems = surfaced.filter { $0.participatesInActionQueue }
        let p0p1 = actionItems.filter { $0.priority != .p2 }
        guard !p0p1.isEmpty else { return surfaced.first }
        return p0p1.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.isVIP != $1.isVIP { return $0.isVIP }
            return $0.timestamp > $1.timestamp
        }.first
    }

    func testInfoOnlyItemsStillProduceVisibleRows() {
        let items = [
            makeItem(chatUsername: "wxid_1", actionRequired: false),
            makeItem(chatUsername: "wxid_2", actionRequired: false)
        ]

        let visible = visibleInboxItems(items)

        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.map(\.chatUsername), ["wxid_1", "wxid_2"])
    }

    func testPassiveItemsAreCappedWithHiddenCount() {
        let items = (0..<5).map { i in
            makeItem(chatUsername: "wxid_\(i)", actionRequired: false)
        }

        let visible = visibleInboxItems(items)

        XCTAssertEqual(visible.count, 3)
        XCTAssertEqual(hiddenPassiveUpdateCount(items), 2)
    }

    func testFYIItemsAreNotHiddenBehindPassiveAggregate() {
        let passive = (0..<5).map { i in
            makeItem(chatUsername: "wxid_\(i)", actionRequired: false)
        }
        let fyi = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: true,
            isGroup: true,
            isAtMention: true
        )

        let visible = visibleInboxItems([fyi] + passive)

        XCTAssertTrue(visible.contains { $0.chatUsername == "room@chatroom" })
        XCTAssertEqual(hiddenPassiveUpdateCount([fyi] + passive), 2)
    }

    func testPassiveItemsCanExpand() {
        let items = (0..<5).map { i in
            makeItem(chatUsername: "wxid_\(i)", actionRequired: false)
        }

        let visible = visibleInboxItems(items, showAllPassive: true)

        XCTAssertEqual(visible.count, 5)
        XCTAssertEqual(hiddenPassiveUpdateCount(items, showAllPassive: true), 0)
    }

    func testPassiveHiddenByGlobalLimitStillUsesPassiveAggregate() {
        let actions = (0..<10).map { i in
            makeItem(
                chatUsername: "action_\(i)",
                actionRequired: true,
                priority: .p1,
                isGroup: true,
                isAtMention: true,
                reasons: [ReplyDebtReason(code: .askSignal)]
            )
        }
        let passive = (0..<2).map { i in
            makeItem(chatUsername: "passive_\(i)", actionRequired: false)
        }

        let items = actions + passive
        let visible = visibleInboxItems(items)

        XCTAssertEqual(visible.count, 10)
        XCTAssertFalse(visible.contains { $0.chatUsername.hasPrefix("passive_") })
        XCTAssertEqual(hiddenPassiveUpdateCount(items), 2)
    }

    func testHeaderShowsUpdatesWhenOnlyPassiveItemsExist() {
        let items = [
            makeItem(chatUsername: "wxid_1", actionRequired: false),
            makeItem(chatUsername: "wxid_2", actionRequired: false)
        ]

        XCTAssertEqual(inboxHeaderState(items), .updates(2))
    }

    func testHeaderPrefersUrgentActionItemsOverPassiveUpdates() {
        let items = [
            makeItem(chatUsername: "wxid_info", actionRequired: false),
            makeItem(chatUsername: "wxid_urgent", actionRequired: true, priority: .p0)
        ]

        XCTAssertEqual(inboxHeaderState(items), .urgent(1))
    }

    func testHeaderDoesNotTreatBareGroupMentionAsPendingAction() {
        let items = [
            makeItem(
                chatUsername: "room@chatroom",
                actionRequired: true,
                priority: .p1,
                isGroup: true,
                isAtMention: true
            )
        ]

        XCTAssertEqual(items[0].semanticState, .groupMentionFYI)
        XCTAssertEqual(inboxHeaderState(items), .updates(1))
    }

    func testGroupMentionWithAskEvidenceCountsAsAction() {
        let items = [
            makeItem(
                chatUsername: "room@chatroom",
                actionRequired: true,
                priority: .p1,
                isGroup: true,
                isAtMention: true,
                reasons: [ReplyDebtReason(code: .askSignal)]
            )
        ]

        XCTAssertEqual(items[0].semanticState, .groupActionRequired)
        XCTAssertEqual(inboxHeaderState(items), .urgent(1))
    }

    func testGroupMentionWithOnlyUrgencyStaysFYI() {
        let item = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: true,
            priority: .p1,
            isGroup: true,
            isAtMention: true,
            reasons: [ReplyDebtReason(code: .urgentKeyword)]
        )

        XCTAssertEqual(item.semanticState, .groupMentionFYI)
        XCTAssertFalse(item.participatesInActionQueue)
    }

    func testCompactSurfacesHighPriorityOrVIPGroupFYI() {
        let highPriorityFYI = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: false,
            priority: .p1,
            isGroup: true,
            isAtMention: true
        )
        let vipFYI = makeItem(
            chatUsername: "vip-room@chatroom",
            actionRequired: false,
            priority: .p2,
            isGroup: true,
            isAtMention: true,
            isVIP: true
        )
        let ordinaryFYI = makeItem(
            chatUsername: "quiet-room@chatroom",
            actionRequired: false,
            priority: .p2,
            isGroup: true,
            isAtMention: true
        )

        XCTAssertTrue(highPriorityFYI.surfacesInCompact)
        XCTAssertTrue(vipFYI.surfacesInCompact)
        XCTAssertFalse(ordinaryFYI.surfacesInCompact)
    }

    func testCompactTopPrefersLaterHighPriorityActionOverFirstLowPriorityItem() {
        let lowPriorityVIP = makeItem(
            chatUsername: "vip-low",
            actionRequired: false,
            priority: .p2,
            isVIP: true
        )
        let highPriorityAction = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: true,
            priority: .p1,
            isGroup: true,
            isAtMention: true,
            reasons: [ReplyDebtReason(code: .askSignal)]
        )

        XCTAssertEqual(compactTopItem([lowPriorityVIP, highPriorityAction])?.chatUsername, "room@chatroom")
    }

    func testCompactTopDoesNotPromoteHighPriorityFYIAsUrgentAction() {
        let highPriorityFYI = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: false,
            priority: .p1,
            isGroup: true,
            isAtMention: true
        )

        XCTAssertFalse(highPriorityFYI.participatesInActionQueue)
        XCTAssertEqual(compactTopItem([highPriorityFYI])?.chatUsername, "room@chatroom")
    }

    func testCompactMoodDoesNotTreatP0FYIAsUrgentOrPending() {
        let vipFYI = makeItem(
            chatUsername: "vip-room@chatroom",
            actionRequired: false,
            priority: .p0,
            isGroup: true,
            isAtMention: true,
            isVIP: true
        )
        let surfaced = [vipFYI].filter { $0.surfacesInCompact }
        let actionItems = surfaced.filter { $0.participatesInActionQueue }

        let mood = deriveCompactMood(
            syncStatus: .ok,
            hasUrgent: actionItems.contains { $0.priority == .p0 },
            hasPending: !actionItems.isEmpty,
            idleMinutes: 0
        )

        XCTAssertEqual(vipFYI.semanticState, .groupMentionFYI)
        XCTAssertTrue(vipFYI.surfacesInCompact)
        XCTAssertFalse(vipFYI.participatesInActionQueue)
        XCTAssertEqual(mood, .idle)
    }

    func testVIPPrivateNotificationIsSemanticRiskEvenWithoutActionEvidence() {
        let item = makeItem(
            chatUsername: "vip-private",
            actionRequired: false,
            priority: .p2,
            isVIP: true
        )

        XCTAssertEqual(item.semanticState, .privateVIPRisk)
        XCTAssertTrue(item.surfacesInCompact)
    }

    func testReplySuggestionModesFollowSemanticState() {
        let groupInfo = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: false,
            isGroup: true
        )
        let groupFYI = makeItem(
            chatUsername: "room2@chatroom",
            actionRequired: true,
            isGroup: true,
            isAtMention: true
        )
        let groupAction = makeItem(
            chatUsername: "room3@chatroom",
            actionRequired: true,
            priority: .p1,
            isGroup: true,
            isAtMention: true,
            reasons: [ReplyDebtReason(code: .askSignal)]
        )

        XCTAssertEqual(groupInfo.replySuggestionMode, .hidden)
        XCTAssertEqual(groupFYI.replySuggestionMode, .manual)
        XCTAssertEqual(groupAction.replySuggestionMode, .automatic)
    }
}
