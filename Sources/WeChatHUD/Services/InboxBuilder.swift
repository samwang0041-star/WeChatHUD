import Foundation

enum InboxBuilder {

    /// Merge reply-debt items and whitelist notifications into a single
    /// priority-sorted inbox. Deduplicates by chatUsername — debt items
    /// take precedence over pure notifications.
    static func build(
        replyDebtItems: [ReplyDebtItem],
        notifications: [HUDNotification],
        dismissed: [String: Int64]
    ) -> [InboxItem] {
        var seen = Set<String>()
        var actionItems: [InboxItem] = []
        var infoItems: [InboxItem] = []

        // 1. ReplyDebtItems → always actionRequired, always reactivate
        for debt in replyDebtItems {
            seen.insert(debt.chatUsername)
            let item = InboxItem(
                id: debt.chatUsername,
                chatUsername: debt.chatUsername,
                chatName: debt.chatName,
                senderName: debt.senderName,
                preview: debt.preview,
                isGroup: debt.isGroup,
                timestamp: debt.timestamp,
                actionRequired: true,
                priority: mapPriority(debt.priority),
                isVIP: debt.isVIP,
                isWhitelisted: debt.isWhitelisted,
                unreadCount: debt.unreadCount,
                isAtMention: debt.isAtMention,
                askType: .none,
                reasons: debt.reasons,
                suggestedReplyMinutes: debt.suggestedReplyMinutes ?? 0,
                status: .active,
                dismissedAtMsgId: nil
            )
            actionItems.append(item)
        }

        // 2. Notifications not already covered by debt items
        for notif in notifications {
            guard !seen.contains(notif.chatUsername) else { continue }
            seen.insert(notif.chatUsername)

            // Skip dismissed pure notifications
            if dismissed[notif.chatUsername] != nil { continue }

            let isAction = notif.isAtMention
            let priority: InboxPriority
            if notif.isAtMention && notif.attentionLevel == .vip {
                priority = .p0
            } else if notif.isAtMention {
                priority = .p1
            } else {
                priority = .p2
            }

            let item = InboxItem(
                id: notif.chatUsername,
                chatUsername: notif.chatUsername,
                chatName: notif.chatName,
                senderName: notif.senderName,
                preview: notif.snippet,
                isGroup: notif.kind == .groupAt || notif.kind == .groupMessage,
                timestamp: notif.timestamp,
                actionRequired: isAction,
                priority: priority,
                isVIP: notif.attentionLevel == .vip,
                isWhitelisted: notif.attentionLevel == .vip || notif.attentionLevel == .watch,
                unreadCount: 0,
                isAtMention: notif.isAtMention,
                askType: .none,
                reasons: [],
                suggestedReplyMinutes: 0,
                status: .active,
                dismissedAtMsgId: nil
            )

            if isAction {
                actionItems.append(item)
            } else {
                infoItems.append(item)
            }
        }

        // 3. Sort: action items by priority then timestamp
        actionItems.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.timestamp > rhs.timestamp
        }

        // 4. Cap info items at 5, sorted by timestamp
        infoItems.sort { $0.timestamp > $1.timestamp }
        let cappedInfo = Array(infoItems.prefix(5))

        return actionItems + cappedInfo
    }

    private static func mapPriority(_ p: ReplyDebtPriority) -> InboxPriority {
        switch p {
        case .p0: return .p0
        case .p1: return .p1
        case .p2: return .p2
        }
    }
}
