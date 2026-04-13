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
}
