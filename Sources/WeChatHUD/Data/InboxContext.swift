import Foundation

/// Structured data packet for a single inbox item.
/// Built by algorithms (precise DB extraction), consumed by AI (summary/briefing).
/// Every field is an objective fact — no AI inference at this level.
struct InboxContext {
    // 1. Trigger message
    let triggerMessage: MessageInfo
    let triggerMessageText: String

    // 2. Conversation window (dynamic size)
    let recentMessages: [MessageInfo]
    let myLastReply: MessageInfo?
    let myLastReplyText: String?
    let timeSinceMyLastReply: TimeInterval?

    // 3. Sender profile
    let senderRole: ContactRole
    let senderAttentionLevel: AttentionLevel
    let senderReplyWindow: Int
    let isOverdue: Bool
    let overdueMinutes: Int

    // 4. Interaction history
    let weeklyInteractionCount: Int
    let weeklyTrend: InteractionTrend
    let avgResponseTimeMinutes: Int

    // 5. Related data
    let pendingCommitments: [Commitment]
    let pendingAsks: [PendingAsk]

    // 6. Group-specific
    let isGroupChat: Bool
    let mentionedMe: Bool
    let groupRecentContext: [MessageInfo]?

    // 7. Message signals
    let hasUrgentKeyword: Bool
    let hasAskSignal: Bool
    let inboundCountSinceMyLastReply: Int

    // 8. Media content
    let mediaType: MediaContentType?
    let mediaFilePath: String?
    let mediaContextMessages: [MessageInfo]

    // 9. Link content (baseType=49)
    let linkTitle: String?
    let linkDescription: String?
    let linkURL: String?
    let linkBodyText: String?
}

enum InteractionTrend: String {
    case up
    case down
    case stable
}

/// Media type detected from message baseType.
/// Different from the existing DetectedMediaType in MessageFeatureExtractor
/// which detects from text prefixes like "[图片]".
enum MediaContentType: String {
    case image
    case video
    case voice
    case file
    case link
    case sticker
    case location
}
