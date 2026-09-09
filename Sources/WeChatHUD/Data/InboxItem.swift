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
    var contextNotification: HUDNotification? = nil
    var silenced: Bool = false       // permanently muted

    /// Stable enough identity for UI/AI caches. WeChat timestamps are
    /// second-resolution, so chat + timestamp alone can mix two different
    /// triggers that arrive in the same second.
    var generationKey: String {
        "\(chatUsername)_\(Int(timestamp.timeIntervalSince1970))_\(Self.fingerprint(preview))"
    }

    private static func fingerprint(_ text: String) -> UInt64 {
        text.unicodeScalars.reduce(UInt64(5381)) { hash, scalar in
            ((hash &* 33) &+ UInt64(scalar.value)) & 0x7FFF_FFFF_FFFF_FFFF
        }
    }
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

/// The intrinsic message classification derived from content,
/// independent of user disposition (active/snoozed/dismissed/silenced).
enum InboxMessageType: String, Codable, Equatable {
    case idle = "idle"
    case syncIssue = "sync_issue"
    case privateInfoOnly = "private_info_only"
    case privateActionRequired = "private_action_required"
    case privateVIPRisk = "private_vip_risk"
    case groupInfoOnly = "group_info_only"
    case groupMentionFYI = "group_mention_fyi"
    case groupActionRequired = "group_action_required"
    case groupDecisionOnly = "group_decision_only"
    case replyOptional = "reply_optional"
    case commitmentDue = "commitment_due"
    case autopilotReview = "autopilot_review"
    case aiLoading = "ai_loading"
    case aiFailed = "ai_failed"
}

/// Effective state combining message type + user disposition.
/// Kept for backward compatibility; new code should prefer
/// `messageType` + `status`/`replied`/`silenced` directly.
enum InboxSemanticState: String, Codable, Equatable {
    case idle = "idle"
    case syncIssue = "sync_issue"
    case privateInfoOnly = "private_info_only"
    case privateActionRequired = "private_action_required"
    case privateVIPRisk = "private_vip_risk"
    case groupInfoOnly = "group_info_only"
    case groupMentionFYI = "group_mention_fyi"
    case groupActionRequired = "group_action_required"
    case groupDecisionOnly = "group_decision_only"
    case replyOptional = "reply_optional"
    case commitmentDue = "commitment_due"
    case autopilotReview = "autopilot_review"
    case aiLoading = "ai_loading"
    case aiFailed = "ai_failed"
    case handled = "handled"
}

enum ReplySuggestionMode: Equatable {
    case hidden
    case manual
    case automatic
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
    let rationale: String?

    var id: String { text }

    init(text: String, tone: String, recommended: Bool, rationale: String? = nil) {
        self.text = text
        self.tone = tone
        self.recommended = recommended
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey {
        case text, tone, recommended, rationale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        tone = try c.decode(String.self, forKey: .tone)
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
    }
}

extension InboxItem {
    // MARK: - Message Type (content-derived, immutable)

    /// The intrinsic classification of this message based solely on
    /// content and metadata. Never affected by user disposition.
    var messageType: InboxMessageType {
        if isGroup {
            if isAtMention {
                return hasStoredGroupActionEvidence ? .groupActionRequired : .groupMentionFYI
            }
            return .groupInfoOnly
        }
        if isVIP {
            return .privateVIPRisk
        }
        if actionRequired {
            return .privateActionRequired
        }
        return .privateInfoOnly
    }

    /// One-line reason why this item surfaces in the inbox.
    /// Based on `messageType`, independent of user disposition.
    var displayReason: String {
        switch messageType {
        case .privateActionRequired: return "等你回复"
        case .privateVIPRisk: return "重要联系人"
        case .groupActionRequired: return "需要你处理"
        case .groupMentionFYI: return "@了你"
        case .groupInfoOnly: return "群聊更新"
        case .privateInfoOnly: return "私聊更新"
        case .groupDecisionOnly: return "已有决议"
        case .replyOptional: return "可以回一句"
        case .commitmentDue: return isOverdue ? "承诺已到期" : "承诺快到期"
        case .autopilotReview: return "待确认回复"
        case .aiLoading: return "AI 正在整理"
        case .aiFailed: return "分析暂不可用"
        case .syncIssue: return "同步异常"
        case .idle: return ""
        }
    }

    // MARK: - Semantic State (message type + user disposition)

    /// Effective state for backward compatibility. Prefer `messageType`
    /// for pure message semantics and `status`/`replied`/`silenced` for
    /// user disposition in new code.
    var semanticState: InboxSemanticState {
        if status != .active || replied || silenced {
            return .handled
        }
        switch messageType {
        case .privateInfoOnly: return .privateInfoOnly
        case .privateActionRequired: return .privateActionRequired
        case .privateVIPRisk: return .privateVIPRisk
        case .groupInfoOnly: return .groupInfoOnly
        case .groupMentionFYI: return .groupMentionFYI
        case .groupActionRequired: return .groupActionRequired
        case .groupDecisionOnly: return .groupDecisionOnly
        case .replyOptional: return .replyOptional
        case .commitmentDue: return .commitmentDue
        case .autopilotReview: return .autopilotReview
        case .aiLoading: return .aiLoading
        case .aiFailed: return .aiFailed
        case .syncIssue: return .syncIssue
        case .idle: return .idle
        }
    }

    // MARK: - UI Helpers

    var replySuggestionMode: ReplySuggestionMode {
        switch messageType {
        case .privateActionRequired, .groupActionRequired:
            return .automatic
        case .privateVIPRisk:
            return (isOverdue || priority != .p2 || actionRequired) ? .automatic : .manual
        case .privateInfoOnly, .groupMentionFYI, .replyOptional:
            return .manual
        default:
            return .hidden
        }
    }

    var participatesInActionQueue: Bool {
        guard status == .active && !replied && !silenced else { return false }
        switch messageType {
        case .privateActionRequired, .privateVIPRisk, .groupActionRequired:
            return true
        default:
            return false
        }
    }

    var isAggregatablePassiveUpdate: Bool {
        switch messageType {
        case .privateInfoOnly, .groupInfoOnly, .groupDecisionOnly, .replyOptional:
            return true
        default:
            return false
        }
    }

    var surfacesInCompact: Bool {
        participatesInActionQueue || (messageType == .groupMentionFYI && (isVIP || priority != .p2))
    }

    var actionPanelTitle: String {
        switch messageType {
        case .privateVIPRisk:
            return isOverdue || priority == .p0 ? "需要尽快回复" : "重要联系人消息"
        case .privateActionRequired:
            return "他想要什么"
        case .privateInfoOnly:
            return "对话更新"
        case .replyOptional:
            return "可以回一句"
        case .groupInfoOnly:
            return "群里在聊什么"
        case .groupMentionFYI:
            return "为什么@你"
        case .groupActionRequired:
            return "需要你处理"
        case .groupDecisionOnly:
            return "已有决议"
        case .commitmentDue:
            return isOverdue ? "承诺已到期" : "承诺快到期"
        case .autopilotReview:
            return "待确认回复"
        case .aiLoading:
            return "AI 正在整理重点"
        case .aiFailed:
            return "分析暂不可用"
        case .idle, .syncIssue:
            return ""
        }
    }

    var primaryCTATitle: String {
        switch messageType {
        case .privateActionRequired:
            return "打开微信回复"
        case .privateVIPRisk:
            return "立即回复"
        case .groupActionRequired:
            return "打开群聊回复"
        case .groupMentionFYI:
            return "查看上下文"
        case .groupInfoOnly:
            return "打开群聊查看"
        case .groupDecisionOnly:
            return "打开查看"
        case .replyOptional:
            return "想回一句"
        case .aiFailed, .aiLoading, .privateInfoOnly:
            return "打开微信查看"
        case .commitmentDue, .autopilotReview:
            return "打开微信查看"
        case .idle, .syncIssue:
            return "打开微信查看"
        }
    }

    var automaticReplySuggestionsAllowed: Bool {
        replySuggestionMode == .automatic
    }

    var replySuggestionButtonTitle: String {
        switch replySuggestionMode {
        case .automatic:
            return "回复建议"
        case .manual:
            return messageType == .replyOptional ? "想回一句" : "生成回复"
        case .hidden:
            return ""
        }
    }

    private var hasStoredGroupActionEvidence: Bool {
        guard actionRequired else { return false }
        let actionCodes: Set<ReplyDebtReasonCode> = [.askSignal]
        return reasons.contains { actionCodes.contains($0.code) }
    }

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
            suggestedReplyMinutes: suggestedReplyMinutes,
            contextNotification: contextNotification
        )
    }
}
