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

            // Check dismissed. A debt item stays dismissed as long
            // as the dismissal timestamp is >= the debt's own
            // timestamp — i.e. nothing newer has arrived since the
            // user clicked X. When a newer inbound arrives, the
            // debt timestamp advances past the dismissal mark and
            // the item reactivates. Previously debt items ignored
            // dismiss entirely, making the X button feel broken
            // ("I clicked X and it's still there 2s later").
            if let dismissTs = dismissed[debt.chatUsername] {
                let debtTs = Int64(debt.timestamp.timeIntervalSince1970)
                if dismissTs >= debtTs {
                    item.status = .dismissed
                    handledItems.append(item)
                    continue
                }
            }

            actionItems.append(item)
        }

        // 2. Notifications not already covered by debt items
        for notif in notifications {
            guard !seen.contains(notif.chatUsername) else { continue }
            seen.insert(notif.chatUsername)

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
                // A bare whitelist notification is not action evidence.
                // Stage 1 renders group @ without stored ask/action
                // evidence as group_mention_fyi, not "需要你处理".
                actionRequired: false,
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

            // Check dismissed. Match the debt-item reactivation rule:
            // a dismissal only suppresses future notifications whose
            // timestamp is <= the dismissal mark. A newer inbound wakes
            // the chat back up — without this, one "忽略" click
            // silenced the chat forever and new messages vanished
            // straight into the handled section.
            if let dismissTs = dismissed[notif.chatUsername] {
                let notifTs = Int64(notif.timestamp.timeIntervalSince1970)
                if dismissTs >= notifTs {
                    item.status = .dismissed
                    handledItems.append(item)
                    continue
                }
            }

            infoItems.append(item)
        }

        // 3. Sort: action items by priority then timestamp
        actionItems.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.timestamp > rhs.timestamp
        }

        // 4. Preserve non-action updates so the UI can render the
        // "还有 N 条普通更新" aggregate row instead of silently
        // dropping state.
        infoItems.sort { $0.timestamp > $1.timestamp }

        // 5. Sort handled items by timestamp (most recent first)
        handledItems.sort { $0.timestamp > $1.timestamp }

        return BuildResult(active: actionItems + infoItems, handled: handledItems)
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
