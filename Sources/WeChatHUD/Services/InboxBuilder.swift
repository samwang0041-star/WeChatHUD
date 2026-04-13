import Foundation

enum InboxBuilder {

    /// Result of building the inbox — separates active from handled items.
    struct BuildResult {
        let active: [InboxItem]     // items shown in main list
        let handled: [InboxItem]    // items in handled section (dismissed/snoozed/silenced)
    }

    /// Merge reply-debt items and whitelist notifications into a single
    /// priority-sorted inbox. Deduplicates by chatUsername — debt items
    /// take precedence over pure notifications.
    static func build(
        replyDebtItems: [ReplyDebtItem],
        notifications: [HUDNotification],
        dismissed: [String: Int64],
        snoozed: [String: Date] = [:],
        silenced: Set<String> = []
    ) -> BuildResult {
        let now = Date()
        // Notifications older than 4h are likely stale baseline artifacts.
        // ReplyDebtItems have their own outbound-check so they don't need age filtering.
        let notifMaxAge: TimeInterval = 4 * 60 * 60
        var seen = Set<String>()
        var actionItems: [InboxItem] = []
        var infoItems: [InboxItem] = []
        var handledItems: [InboxItem] = []

        // 1. ReplyDebtItems → always actionRequired
        for debt in replyDebtItems {
            seen.insert(debt.chatUsername)

            // Compute overdue status
            let suggestedMinutes = debt.suggestedReplyMinutes ?? 0
            let minutesSinceMessage = now.timeIntervalSince(debt.timestamp) / 60.0
            let isOverdue = suggestedMinutes > 0 && Int(minutesSinceMessage) > suggestedMinutes
            let overdueMinutes = isOverdue ? Int(minutesSinceMessage) - suggestedMinutes : 0

            var item = InboxItem(
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
                suggestedReplyMinutes: suggestedMinutes,
                status: .active,
                dismissedAtMsgId: nil,
                isOverdue: isOverdue,
                overdueMinutes: overdueMinutes
            )

            // Check silenced
            if silenced.contains(debt.chatUsername) {
                item.status = .silenced
                item.silenced = true
                handledItems.append(item)
                continue
            }

            // Check snoozed (only if snooze hasn't expired)
            if let snoozeExpiry = snoozed[debt.chatUsername], snoozeExpiry > now {
                item.status = .snoozed
                item.snoozedUntil = snoozeExpiry
                handledItems.append(item)
                continue
            }

            // Active debt item (reactivates even if dismissed — debt = newer message)
            actionItems.append(item)
        }

        // 2. Notifications not already covered by debt items
        for notif in notifications {
            guard !seen.contains(notif.chatUsername) else { continue }
            // Skip stale notifications (baseline resets can surface old messages)
            guard now.timeIntervalSince(notif.timestamp) < notifMaxAge else { continue }
            seen.insert(notif.chatUsername)

            let isAction = notif.isAtMention
            let priority: InboxPriority
            if notif.isAtMention && notif.attentionLevel == .vip {
                priority = .p0
            } else if notif.isAtMention {
                priority = .p1
            } else {
                priority = .p2
            }

            var item = InboxItem(
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

            // Check silenced
            if silenced.contains(notif.chatUsername) {
                item.status = .silenced
                item.silenced = true
                handledItems.append(item)
                continue
            }

            // Check snoozed (only if snooze hasn't expired)
            if let snoozeExpiry = snoozed[notif.chatUsername], snoozeExpiry > now {
                item.status = .snoozed
                item.snoozedUntil = snoozeExpiry
                handledItems.append(item)
                continue
            }

            // Check dismissed (only for notifications, not debt items)
            if dismissed[notif.chatUsername] != nil {
                item.status = .dismissed
                handledItems.append(item)
                continue
            }

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

        // 5. Sort handled items by timestamp (most recent first)
        handledItems.sort { $0.timestamp > $1.timestamp }

        return BuildResult(active: actionItems + cappedInfo, handled: handledItems)
    }

    // MARK: - Legacy convenience (returns only active items)

    /// Legacy overload for call sites that only need active items.
    static func build(
        replyDebtItems: [ReplyDebtItem],
        notifications: [HUDNotification],
        dismissed: [String: Int64]
    ) -> [InboxItem] {
        let result = build(
            replyDebtItems: replyDebtItems,
            notifications: notifications,
            dismissed: dismissed,
            snoozed: [:],
            silenced: []
        )
        return result.active
    }

    private static func mapPriority(_ p: ReplyDebtPriority) -> InboxPriority {
        switch p {
        case .p0: return .p0
        case .p1: return .p1
        case .p2: return .p2
        }
    }
}
