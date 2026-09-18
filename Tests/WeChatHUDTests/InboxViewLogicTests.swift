import XCTest
@testable import WeChatHUD

final class InboxViewLogicTests: XCTestCase {

    func testGenerationKeySeparatesSameSecondDifferentPreview() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var first = makeItem(chatUsername: "alice", actionRequired: true)
        first = InboxItem(
            id: first.id,
            chatUsername: first.chatUsername,
            chatName: first.chatName,
            senderName: first.senderName,
            preview: "明天三点方便",
            isGroup: first.isGroup,
            timestamp: timestamp,
            actionRequired: first.actionRequired,
            priority: first.priority,
            isVIP: first.isVIP,
            isWhitelisted: first.isWhitelisted,
            unreadCount: first.unreadCount,
            isAtMention: first.isAtMention,
            askType: first.askType,
            reasons: first.reasons,
            overdueThresholdMinutes: first.overdueThresholdMinutes,
            status: first.status,
            dismissedAtMsgId: first.dismissedAtMsgId
        )
        let second = InboxItem(
            id: first.id,
            chatUsername: first.chatUsername,
            chatName: first.chatName,
            senderName: first.senderName,
            preview: "要不要走这个方案",
            isGroup: first.isGroup,
            timestamp: timestamp,
            actionRequired: first.actionRequired,
            priority: first.priority,
            isVIP: first.isVIP,
            isWhitelisted: first.isWhitelisted,
            unreadCount: first.unreadCount,
            isAtMention: first.isAtMention,
            askType: first.askType,
            reasons: first.reasons,
            overdueThresholdMinutes: first.overdueThresholdMinutes,
            status: first.status,
            dismissedAtMsgId: first.dismissedAtMsgId
        )

        XCTAssertNotEqual(first.generationKey, second.generationKey)
    }

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
            overdueThresholdMinutes: 0,
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

    func testVisiblePassiveUpdatesAreSummaryCandidates() {
        let passive = (0..<5).map { i in
            makeItem(chatUsername: "passive_\(i)", actionRequired: false, isGroup: true)
        }

        let candidates = InboxPresentationPolicy.summaryCandidates(passive)

        XCTAssertEqual(candidates.map(\.chatUsername), ["passive_0", "passive_1", "passive_2"])
    }

    func testGroupFYIIsSummaryCandidateEvenWhenNotActionable() {
        let fyi = makeItem(
            chatUsername: "room@chatroom",
            actionRequired: true,
            priority: .p1,
            isGroup: true,
            isAtMention: true
        )

        XCTAssertEqual(fyi.semanticState, .groupMentionFYI)
        XCTAssertTrue(InboxPresentationPolicy.shouldGenerateRowSummary(for: fyi))
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

        XCTAssertEqual(inboxHeaderState(items), .updates)
    }

    func testHeaderPrefersUrgentActionItemsOverPassiveUpdates() {
        let items = [
            makeItem(chatUsername: "wxid_info", actionRequired: false),
            makeItem(chatUsername: "wxid_urgent", actionRequired: true, priority: .p0)
        ]

        XCTAssertEqual(inboxHeaderState(items), .urgent)
    }

    /// The number the list header prints is the total the list stands for, not
    /// the size of the category that won. A panel of one reply-needed row and
    /// two group @s used to be headed 「待处理 (1)」 over three rows.
    func testHeaderCountCoversEveryRowTheListShows() {
        let items = [
            makeItem(chatUsername: "wxid_p1", actionRequired: true, priority: .p1),
            makeItem(chatUsername: "room_a@chatroom", actionRequired: true, isGroup: true, isAtMention: true),
            makeItem(chatUsername: "room_b@chatroom", actionRequired: true, isGroup: true, isAtMention: true)
        ]

        XCTAssertEqual(inboxHeaderState(items), .replyNeeded)
        XCTAssertEqual(InboxPresentationPolicy.pendingCount(items), 3)
        XCTAssertEqual(
            InboxPresentationPolicy.pendingCount(items),
            InboxPresentationPolicy.visibleItems(items).count
        )
    }

    func testHeaderCountIncludesTheFoldedPassiveTail() {
        var items = [makeItem(chatUsername: "wxid_p1", actionRequired: true, priority: .p1)]
        items += (0..<5).map { makeItem(chatUsername: "passive_\($0)", actionRequired: false) }

        let visible = InboxPresentationPolicy.visibleItems(items)
        XCTAssertLessThan(visible.count, items.count)
        XCTAssertEqual(
            InboxPresentationPolicy.pendingCount(items),
            visible.count + InboxPresentationPolicy.hiddenPassiveUpdateCount(items)
        )
    }

    /// A bare @ the user already dealt with is not in the list, so the band may
    /// not claim the list is about it.
    func testHandledMentionDoesNotDriveTheBand() {
        var handled = makeItem(
            chatUsername: "room@chatroom", actionRequired: true, isGroup: true, isAtMention: true
        )
        handled.replied = true
        let passive = makeItem(chatUsername: "wxid_info", actionRequired: false)

        XCTAssertEqual(handled.messageType, .groupMentionFYI)
        XCTAssertEqual(inboxHeaderState([handled, passive]), .updates)
        XCTAssertEqual(InboxPresentationPolicy.pendingCount([handled, passive]), 1)
    }

    func testIdleHeaderCountsNothing() {
        XCTAssertEqual(InboxPresentationPolicy.pendingCount([]), 0)
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
        // 4b1dc44 header now distinguishes bare @mentions (.mentioned)
        // from passive updates (.updates). Intent unchanged: not an action.
        XCTAssertEqual(inboxHeaderState(items), .mentioned)
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
        // .urgent is p0-only since 4b1dc44; p1 action items surface as
        // .replyNeeded. Intent unchanged: still counts as an action.
        XCTAssertEqual(inboxHeaderState(items), .replyNeeded)
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
