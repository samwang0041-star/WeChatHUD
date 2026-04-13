import Foundation

/// Unified inbox entry. One per chat (deduped by chatUsername).
struct InboxItem: Identifiable {
    let id: String                  // == chatUsername
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String
    let isGroup: Bool
    let timestamp: Date

    let actionRequired: Bool
    let priority: InboxPriority
    let isVIP: Bool
    let isWhitelisted: Bool
    let unreadCount: Int
    let isAtMention: Bool
    let askType: AskType
    let reasons: [ReplyDebtReason]
    let suggestedReplyMinutes: Int

    var status: InboxStatus
    var dismissedAtMsgId: Int64?

    // Enhanced fields for Plan C
    var aiSummary: String?           // AI summary (Plan B populates, UI displays)
    var moodEmoji: String?           // VIP mood (Plan B populates)
    var isOverdue: Bool = false      // overdue based on reply window
    var overdueMinutes: Int = 0      // how many minutes overdue
    var replied: Bool = false        // user already replied (pending removal)
    var snoozedUntil: Date?          // snooze expiry
    var silenced: Bool = false       // permanently muted
}

enum InboxPriority: Int, Comparable {
    case p0 = 0
    case p1 = 1
    case p2 = 2

    static func < (lhs: InboxPriority, rhs: InboxPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum InboxStatus {
    case active
    case dismissed
    case snoozed
    case silenced
}

/// AI-generated briefing for an expanded inbox item.
/// Contains situation analysis, recommended action, and reply suggestions.
struct InboxBriefing: Decodable {
    let situation: String
    let suggestion: String
    let replies: [SuggestedReply]
}

/// One reply suggestion within an InboxBriefing.
struct SuggestedReply: Decodable, Identifiable {
    let text: String
    let tone: String
    let recommended: Bool

    var id: String { text }
}

extension InboxItem {
    /// Convert to ReplyDebtItem for compatibility with ReplyDebtExpandedView.
    func toReplyDebtItem() -> ReplyDebtItem {
        ReplyDebtItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: senderName,
            preview: preview,
            latestOutboundPreview: nil,
            timestamp: timestamp,
            priority: {
                switch priority {
                case .p0: return .p0
                case .p1: return .p1
                case .p2: return .p2
                }
            }(),
            score: priority == .p0 ? 9 : priority == .p1 ? 6 : 3,
            unreadCount: unreadCount,
            isGroup: isGroup,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            isAtMention: isAtMention,
            inboundCountSinceLastOutbound: 1,
            reasons: reasons,
            suggestedReplyMinutes: suggestedReplyMinutes
        )
    }
}
