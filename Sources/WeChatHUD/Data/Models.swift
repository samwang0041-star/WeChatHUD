import Foundation

// MARK: - Panel State

enum HUDState {
    case compact        // default — tiniest pill, passive glance
    case extended       // hover-expanded pill (same height, wider)
    case notification   // popup banner for important alerts
    case detail         // full-height panel (chat list, settings)
}

// MARK: - Stats (CompactBar)

struct HUDStats {
    /// Counter shown on the compact pill. Defined as:
    ///   (number of private chats with WeChat-side unread_count > 0)
    ///   + (number of @-you messages in groups not yet read in WeChat)
    /// Cleared only when WeChat's own session.unread_count drops to 0 —
    /// merely opening the HUD does not decrement.
    var unreadCount: Int = 0
    /// Split: how many of `unreadCount` are @ mentions. Shown as a sub-badge.
    var atMentionCount: Int = 0
    /// Tracked sources in the strong-reminder layer (VIP) that currently
    /// have fresh activity in the follow feed.
    var vipCount: Int = 0
    /// Chats where the latest meaningful inbound is newer than the
    /// user's latest outbound, after local suppression is applied.
    var replyDebtCount: Int = 0
    var syncStatus: SyncStatus = .idle
    var lastSyncAt: Date? = nil
}

enum SyncStatus {
    case idle
    case syncing
    case ok
    case stale              // >5 min since last sync
    case waitingForWeChat   // WeChat process not running
    case error(String)

    var dotColor: String {
        switch self {
        case .idle, .syncing: return "yellow"
        case .ok: return "green"
        case .stale: return "yellow"
        case .waitingForWeChat, .error: return "red"
        }
    }
}

// MARK: - Chat & Messages

struct ChatInfo: Identifiable, Hashable {
    let id: String           // username
    let displayName: String
    let isGroup: Bool

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ChatInfo, rhs: ChatInfo) -> Bool { lhs.id == rhs.id }
}

struct MessageInfo: Identifiable {
    let id: String           // message UID
    let chatUsername: String
    let chatName: String
    let senderUsername: String
    let senderName: String
    let text: String
    let baseType: Int
    let subType: Int
    let createTime: Int      // unix timestamp
    /// App message subtype from parseAppMsg (0 for non-appmsg).
    var appType: Int = 0

    var isAtMention: Bool { text.contains("@") }
    var relativeTime: String { Self.formatRelative(createTime) }

    static func formatRelative(_ ts: Int) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let diff = now - ts
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        if diff < 86400 { return "\(diff / 3600)小时前" }
        if diff < 172800 { return "昨天" }
        if diff < 604800 { return "\(diff / 86400)天前" }
        let date = Date(timeIntervalSince1970: Double(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - Session (per-chat WeChat state)

/// One row from `session/session.db` → `SessionTable`. WeChat itself
/// maintains `unread_count`; we don't touch it — we only read it.
struct SessionInfo {
    let username: String
    let isGroup: Bool
    let unreadCount: Int
    let lastTimestamp: Int
}

// MARK: - Unread item (for the 未读 tab inside extended view)

/// Triage state of an unread item, computed once per scan.
enum UnreadStatus {
    /// Unreplied, still within the per-chat timeout threshold. Normal look.
    case pending
    /// Unreplied, past the threshold. Rendered red — needs attention NOW.
    case overdue
    /// User has already sent a reply in-chat after this message, but
    /// WeChat hasn't zeroed the unread count yet. Transient state.
    case answered
}

struct UnreadItem: Identifiable {
    let id = UUID()
    let chatUsername: String
    let chatName: String
    let senderUsername: String
    let senderName: String
    let preview: String
    let timestamp: Date
    let kind: HUDNotificationKind
    /// True when the chat is in the tracked source list (白名单).
    let isWhitelisted: Bool
    /// True if the chat is in the strong-reminder subset of the tracked
    /// source list. Controls which timeout threshold applies.
    let isVIP: Bool
    /// True if the user has sent at least one message in the same chat
    /// with `create_time > timestamp` — the strict "already replied"
    /// definition. Note: a reply typically also clears WeChat's own
    /// unread state, so this is mostly observed as a transient sync lag.
    let replied: Bool
    /// Computed once per scan from `replied`, `timestamp`, `isVIP`, and
    /// the active timeout thresholds. Views consume this directly.
    let status: UnreadStatus
    /// True when the row is hidden by a sender-level ignore rule rather
    /// than a chat-level silence/snooze action.
    let isIgnored: Bool
}

/// Configurable thresholds for when an unreplied item becomes "已超时".
/// Not persisted yet — defaults live in `ChatMonitor`. Will be surfaced
/// in settings later.
struct UnreadThresholds {
    var vipMinutes: Int = 30
    var normalMinutes: Int = 120
}

// MARK: - Reply Debt

enum ReplyDebtPriority: String, Codable, CaseIterable {
    case p0
    case p1
    case p2

    var rank: Int {
        switch self {
        case .p0: return 0
        case .p1: return 1
        case .p2: return 2
        }
    }
}

enum ReplyDebtReasonCode: String, Codable, CaseIterable {
    case atMention
    case privateChat
    case whitelisted
    case urgentKeyword
    case askSignal
    case unread
    case overdue
    case repeatedInbound

    var label: String {
        switch self {
        case .atMention: return "@你"
        case .privateChat: return "私聊"
        case .whitelisted: return "白名单"
        case .urgentKeyword: return "紧急"
        case .askSignal: return "待确认"
        case .unread: return "未读"
        case .overdue: return "超时"
        case .repeatedInbound: return "连续催促"
        }
    }
}

struct ReplyDebtReason: Identifiable, Codable, Hashable {
    let code: ReplyDebtReasonCode
    let label: String

    init(code: ReplyDebtReasonCode, label: String? = nil) {
        self.code = code
        self.label = label ?? code.label
    }

    var id: String { code.rawValue }
}

struct ReplyDebtItem: Identifiable {
    let id: String           // chatUsername
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String
    let latestOutboundPreview: String?
    let timestamp: Date
    let priority: ReplyDebtPriority
    let score: Int
    let unreadCount: Int
    let isGroup: Bool
    let isWhitelisted: Bool
    let isVIP: Bool
    let isAtMention: Bool
    let inboundCountSinceLastOutbound: Int
    let reasons: [ReplyDebtReason]
    /// AI-suggested reply window in minutes. nil = no prediction available.
    let suggestedReplyMinutes: Int?
}

struct ReplyDebtConfig: Codable {
    var maxSessions: Int = 100
    var normalOverdueMinutes: Int = 120
    var vipOverdueMinutes: Int = 30
    var groupAtOverdueMinutes: Int = 30
}

struct ReplyDebtAIConfig: Codable {
    var enabled: Bool = false
    var shadowMode: Bool = true
    var maxCandidates: Int = 12
    var minRuleScore: Int = 4
    var requestTimeoutSeconds: Int = 20
}

// MARK: - Notification

enum HUDNotificationKind {
    /// 1-on-1 private chat.
    case privateChat
    /// Group chat where the user was explicitly @-mentioned (or @All/@所有人).
    case groupAt
    /// Group chat, regular message (not mentioning the user).
    case groupMessage
}

struct HUDNotification: Identifiable {
    let id = UUID()
    let chatUsername: String   // wxid / room id, used as dedup key
    let chatName: String
    let senderUsername: String
    let senderName: String
    let attentionLevel: WhitelistAttentionLevel
    let messageID: String
    let rawText: String
    let snippet: String
    let isAtMention: Bool
    let timestamp: Date
    let kind: HUDNotificationKind

    var canExplainContext: Bool {
        kind == .groupAt
    }

    var isVIP: Bool {
        attentionLevel == .vip
    }

    var briefingKey: String {
        if !messageID.isEmpty { return messageID }
        return "\(chatUsername):\(Int(timestamp.timeIntervalSince1970)):\(senderName)"
    }
}

struct IgnoredSenderRule: Identifiable, Equatable {
    let chatUsername: String
    let chatName: String
    let senderIdentifier: String
    let senderUsername: String
    let senderName: String
    let createdAt: Date

    var id: String { "\(chatUsername)|\(senderIdentifier)" }
}

struct GroupContextBriefing: Codable, Equatable {
    let situation: String
    let whyMentioned: String
    let currentStatus: String
    let nextStep: String
    let participants: [String]
    let confidence: Double
    let source: GroupContextBriefingSource
    let generatedAt: Date

    // Deep analysis (from ContextAnalyzer, loaded async after initial briefing)
    var deepBackground: String?
    var deepWhatTheyWant: String?
    var deepHiddenContext: String?
    var deepStakeholders: [String]?
    var deepYourPosition: String?
    var deepSuggestedAction: String?
    var deepSuggestedTiming: String?
    var deepRiskIfIgnore: String?
}

enum GroupContextBriefingSource: String, Codable {
    case ai
    case fallback

    var label: String {
        switch self {
        case .ai: return "AI"
        case .fallback: return "兜底"
        }
    }
}

struct GroupContextBriefingLoadState {
    var briefing: GroupContextBriefing?
    var isLoading: Bool = false
    var errorMessage: String?
    var updatedAt: Date?

    static let idle = GroupContextBriefingLoadState()
}

// MARK: - Whitelist

struct WhitelistEntry: Identifiable {
    let id: String           // username
    let displayName: String
    let isGroup: Bool
    let category: WhitelistCategory
    let attentionLevel: WhitelistAttentionLevel
    let addedAt: Date
    let autoSuggested: Bool
}

enum WhitelistAttentionLevel: String, CaseIterable, Codable {
    case watch
    case vip

    var label: String {
        switch self {
        case .watch: return "白名单"
        case .vip: return "VIP"
        }
    }

    var shortLabel: String {
        switch self {
        case .watch: return "关注"
        case .vip: return "VIP"
        }
    }
}

enum WhitelistCategory: String, CaseIterable {
    case work
    case life
    case other

    var label: String {
        switch self {
        case .work: return "工作"
        case .life: return "生活"
        case .other: return "其他"
        }
    }
}

// MARK: - Four-Tier Contact System

enum AttentionLevel: String, CaseIterable, Codable, Equatable {
    case vip
    case whitelist
    case greylist
    case stranger

    /// Lower rank = higher priority (vip=1, stranger=4)
    var rank: Int {
        switch self {
        case .vip:       return 1
        case .whitelist: return 2
        case .greylist:  return 3
        case .stranger:  return 4
        }
    }

    var label: String {
        switch self {
        case .vip:       return "VIP"
        case .whitelist: return "白名单"
        case .greylist:  return "灰名单"
        case .stranger:  return "陌生人"
        }
    }
}

enum NotifyLevel: String, CaseIterable, Codable, Equatable {
    case strong
    case standard
    case light
    case none
}

enum ReplyTone: String, CaseIterable, Codable, Equatable {
    case reporting
    case professional
    case collaborative
    case casual
    case polite
}

enum ContactRole: String, CaseIterable, Codable, Equatable {
    case boss         = "boss"
    case keyClient    = "key_client"
    case family       = "family"
    case partner      = "partner"
    case colleague    = "colleague"
    case client       = "client"
    case friend       = "friend"
    case supplier     = "supplier"
    case acquaintance = "acquaintance"
    case groupOnly    = "group_only"
    case service      = "service"

    var label: String {
        switch self {
        case .boss:         return "上级/老板"
        case .keyClient:    return "重要客户"
        case .family:       return "家人"
        case .partner:      return "合作伙伴"
        case .colleague:    return "同事"
        case .client:       return "普通客户"
        case .friend:       return "朋友"
        case .supplier:     return "供应商"
        case .acquaintance: return "泛泛之交"
        case .groupOnly:    return "群友"
        case .service:      return "服务号/助手"
        }
    }

    var icon: String {
        switch self {
        case .boss:         return "👔"
        case .keyClient:    return "🌟"
        case .family:       return "🏠"
        case .partner:      return "🤝"
        case .colleague:    return "💼"
        case .client:       return "👤"
        case .friend:       return "😊"
        case .supplier:     return "📦"
        case .acquaintance: return "👋"
        case .groupOnly:    return "👥"
        case .service:      return "🤖"
        }
    }

    var roleDescription: String {
        switch self {
        case .boss:
            return "上级或老板，AI 会高度关注决策指令、情绪变化和不满信号，优先提醒并建议汇报口吻回复。"
        case .keyClient:
            return "重要客户，AI 会跟踪投诉、需求、竞品提及和正面评价，保持专业及时的响应节奏。"
        case .family:
            return "家人，AI 关注健康、安全和生活安排，用关心的语气提醒，不过度打扰。"
        case .partner:
            return "长期合作伙伴，AI 跟踪项目进展和态度变化，以协作专业的方式维护关系。"
        case .colleague:
            return "同事，AI 以标准协作方式处理工作事务，合理排队提醒。"
        case .client:
            return "普通客户，AI 保持专业礼貌，关注需求和满意度。"
        case .friend:
            return "朋友，AI 使用轻松随意的语气，不强调紧急性，尊重私人时间。"
        case .supplier:
            return "供应商，AI 关注交付和价格谈判，协作处理业务事务。"
        case .acquaintance:
            return "泛泛之交，AI 轻量提醒，不深度分析，保持礼貌即可。"
        case .groupOnly:
            return "仅在群里交流，AI 不单独追踪，仅在群消息中低优先级提及。"
        case .service:
            return "服务号或助手，AI 通常静默处理，仅在需要操作时提示。"
        }
    }

    var defaultReplyWindowMinutes: Int {
        switch self {
        case .boss:         return 30
        case .keyClient:    return 60
        case .family:       return 120
        case .partner:      return 120
        case .colleague:    return 240
        case .client:       return 120
        case .friend:       return 240
        case .supplier:     return 480
        case .acquaintance: return 0
        case .groupOnly:    return 0
        case .service:      return 0
        }
    }

    var defaultNotifyLevel: NotifyLevel {
        switch self {
        case .boss, .keyClient:
            return .strong
        case .family, .partner, .client, .colleague, .friend, .supplier:
            return .standard
        case .acquaintance, .groupOnly:
            return .light
        case .service:
            return .none
        }
    }

    var defaultReplyTone: ReplyTone {
        switch self {
        case .boss:
            return .reporting
        case .keyClient, .client, .partner:
            return .professional
        case .colleague, .supplier:
            return .collaborative
        case .family, .friend:
            return .casual
        case .acquaintance, .groupOnly, .service:
            return .polite
        }
    }

    var vipTrackDimensions: [String] {
        switch self {
        case .boss:
            return ["decisions", "mood", "dissatisfaction", "directives"]
        case .keyClient:
            return ["complaints", "needs", "competitor_mentions", "praise"]
        case .family:
            return ["health", "safety", "life_arrangements", "emotions"]
        case .partner:
            return ["project_progress", "attitude_shifts", "competitor_activity"]
        default:
            return []
        }
    }
}

// MARK: - Settings

/// Configuration for the general chat-completions AI service.
///
/// **Source of truth at runtime is the `ai` row in the `settings` table.**
/// Field defaults are intentionally empty so source files never carry
/// "AI endpoint" or "model name" literals — the canonical values live
/// in `HUDStore.seedAISettingsIfMissing()`, which writes them on first
/// launch and never overwrites a user customization.
///
/// Always read this config via `HUDStore.loadAIConfig()` rather than
/// constructing it directly.
struct AIConfig: Codable {
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    var maxTokens: Int = 2048
    var temperature: Double = 0.3
}

struct SyncConfig: Codable {
    var intervalSeconds: Int = 30
    var wechatDBPath: String = "auto"
    var cacheStrategy: CacheStrategy = .temporary
}

/// Where decrypted WeChat DBs are cached.
enum CacheStrategy: String, Codable, CaseIterable {
    case persistent   // ~/.wechat-hud/cache/ — fast cold start, plaintext on disk
    case temporary    // /tmp/wechat_hud_cache/ — cleared on reboot
    case memory       // never touches disk — most secure, slowest cold start

    var label: String {
        switch self {
        case .persistent: return "持久磁盘"
        case .temporary:  return "临时磁盘"
        case .memory:     return "仅内存"
        }
    }

    var hint: String {
        switch self {
        case .persistent: return "~/.wechat-hud/cache — 启动最快，明文落盘"
        case .temporary:  return "/tmp — 重启清空，每次开机首次解密"
        case .memory:     return "进程内存 — 最安全，每次启动都全量解密"
        }
    }
}

struct NotificationConfig: Codable {
    var atMention: Bool = true
    var important: Bool = true
    var allWhitelist: Bool = false
    var durationSeconds: Int = 3
}

// MARK: - AI Subsystem

/// Configuration for the per-message ask classifier (Role 1 in the AI
/// design doc).
///
/// **Source of truth at runtime is the `classifier` row in the `settings`
/// table.** The field defaults below mirror the local OMLX baseline so
/// tests and first-run call sites stay usable even before the settings
/// row is read back; `HUDStore.seedAISettingsIfMissing()` still writes
/// the canonical first-launch values and never overwrites customizations.
///
/// Always read this config via `HUDStore.loadClassifierConfig()` rather
/// than constructing it directly — that helper is the single read point
/// and guarantees post-seed values come back.
///
/// See `docs/superpowers/plans/2026-04-12-wechathud-ai-subsystem.md`.
struct AIClassifierConfig: Codable {
    var baseURL: String = "http://127.0.0.1:8000/v1"
    var model: String = "Qwen3.5-27B-6bit"
    var apiKey: String = ""
    var temperature: Double = 0.1
    var maxTokens: Int = 256
    var promptVersion: String = "classifier_v1"
}

/// Categories the classifier emits for what kind of action a message is
/// asking the recipient to perform. `none` is the negative case.
enum AskType: String, Codable {
    case yesNo    = "yes_no"
    case sendFile = "send_file"
    case review
    case decide
    case info
    case schedule
    case action
    case none

    var label: String {
        switch self {
        case .yesNo:    return "确认"
        case .sendFile: return "发送"
        case .review:   return "审核"
        case .decide:   return "决定"
        case .info:     return "提供信息"
        case .schedule: return "安排"
        case .action:   return "执行"
        case .none:     return "无"
        }
    }
}

/// One message handed to the classifier. Pure value type — no DB ids,
/// no timestamps. Captures only what the model needs to make a decision.
struct ClassifierInput {
    let msgUID: String
    let text: String
    let senderName: String
    let chatName: String
    let isGroup: Bool
}

/// What the classifier returns. The classifier itself does not resolve
/// `deadlineRelative` to an absolute time — that conversion happens at
/// the call site so the classifier stays a pure function of its input.
struct ClassifierResult {
    let isAsk: Bool
    let type: AskType
    let summary: String
    let deadlineRelative: String?    // "+30m", "+2h", "+1d", "+1w" or nil
    let confidence: Double
    let promptVersion: String
}

/// One row in `pending_asks`. Created by the classifier pass after a new
/// whitelist/VIP message is detected. Lifecycle: pending → done | dismissed.
struct PendingAsk: Identifiable {
    let id: Int64                 // 0 for unsaved rows; assigned by SQLite on insert
    let msgUID: String
    let chatUsername: String
    let chatName: String
    let senderName: String
    let rawText: String
    let summary: String
    let askType: AskType
    let deadlineAt: Date?
    let confidence: Double
    let bucket: AskBucket
    let status: AskStatus
    let promptVersion: String
    let createdAt: Date
    let updatedAt: Date
    // New fields for four-tier system
    let senderLevel: AttentionLevel?
    let senderRole: ContactRole?
    let urgency: AskUrgency?
}

enum AskBucket: String, Codable {
    case main         // confidence >= 0.85, fully visible
    case review       // 0.5 ≤ confidence < 0.85, collapsed sub-list
}

enum AskStatus: String, Codable {
    case pending
    case done
    case dismissed
}

/// One row in `ai_audit`. Written for **every** AI call across all three
/// roles. Used for debugging and weekly false-positive review. Auto-pruned
/// after 14 days on `HUDStore.open()`.
struct AIAuditEntry {
    let id: Int64                 // 0 for unsaved rows
    let ts: Date
    let role: AIRole
    let model: String
    let promptVersion: String
    let inputText: String
    let outputText: String
    let latencyMs: Int
    let status: AIAuditStatus
    let errorMessage: String?
}

enum AIRole: String, Codable {
    case classifier
    case ranker
    case retrospector
    case commitmentTracker = "commitment_tracker"
    case contextAnalyzer   = "context_analyzer"
    case replyGenerator    = "reply_generator"
    case vipAggregator     = "vip_aggregator"
    case groupDigestor     = "group_digestor"
    case recallAnalyzer    = "recall_analyzer"
    case autopilot         = "autopilot"
}

enum AIAuditStatus: String, Codable {
    case ok
    case parseError = "parse_error"
    case httpError  = "http_error"
    case timeout
}

/// One row in `ai_feedback`. Written when the user explicitly confirms
/// or contradicts an AI output, including classifier asks and reply-debt
/// ranking audits. Drives the manual prompt-tuning loop.
struct AIFeedbackEntry {
    let id: Int64                 // 0 for unsaved rows
    let ts: Date
    let msgUID: String
    let feedbackType: AIFeedbackType
    let originalOutput: String    // serialized JSON the AI produced
    let userAction: String?       // 'marked_done' | 'marked_not_ask' | 'edited_summary'
    let note: String?
}

enum AIFeedbackType: String, Codable {
    case truePositive  = "true_positive"
    case falsePositive = "false_positive"
    case trueNegative  = "true_negative"
    case falseNegative = "false_negative"
}

// MARK: - Enhanced Contact (four-tier system)

struct ContactEntry: Identifiable {
    let id: String  // username
    let username: String
    let displayName: String
    let attentionLevel: AttentionLevel
    let role: ContactRole
    let roleNote: String
    let replyWindowMinutes: Int
    let levelChangedAt: Date?
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - VIP Trace

struct VIPTrace: Identifiable {
    let id: Int64
    let vipUsername: String
    let vipName: String
    let chatUsername: String
    let chatName: String
    let msgUID: String
    let rawText: String
    let msgTime: Int
    let batchID: String?
    let createdAt: Date
}

// MARK: - Recalled Message

enum ChatType: String, Codable {
    case privateChat = "private"
    case group
}

struct RecalledMessage: Identifiable {
    let id: Int64
    let msgUID: String
    let senderUsername: String
    let senderName: String
    let senderLevel: AttentionLevel
    let senderRole: ContactRole
    let chatUsername: String
    let chatName: String
    let chatType: ChatType
    let originalText: String
    let sentAt: Int
    let recalledAt: Int
    let recallDelaySeconds: Int
    // AI analysis (filled async)
    let aiReason: String?
    let aiIntelligenceValue: String?
    let aiDetail: String?
    let aiShouldNotify: Bool?
    let aiNotifyLevel: NotifyLevel?
    let aiAnalyzedAt: Date?
    let createdAt: Date
}

// MARK: - Commitment (your promises)

enum CommitmentStatus: String, Codable {
    case pending
    case fulfilled
    case overdue
    case cancelled
}

struct Commitment: Identifiable {
    let id: Int64
    let msgUID: String
    let chatUsername: String
    let chatName: String
    let content: String
    let commitTo: String
    let deadlineAt: Date?
    let confidence: Double
    let status: CommitmentStatus
    let promptVersion: String
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - Urgency (used by enhanced Classifier)

enum AskUrgency: String, Codable {
    case routine
    case timely
    case urgent
}

/// Per-role default configuration, stored as JSON in settings["role_configs"].
struct RoleConfig: Codable {
    var replyWindow: Int
    var notifyLevel: String
    var classifierStrictness: String  // "normal" or "high"
    var replyTone: String
    var vipTrackDimensions: [String]
}

// MARK: - Conversation Memory

struct ConversationMemory {
    let chatUsername: String
    var summary: String
    var keyTopics: [String]
    var pendingItems: [String]
    var sharedContext: [String]
    var communicationNotes: [String]
    var moodTrend: String
    /// Current conversation phase: 闲聊/讨论/决策/争论/告别/无
    var conversationPhase: String
    /// User's current stance or position in the conversation (e.g., "支持方案A").
    var stance: String
    var messageCount7d: Int
    var lastUpdated: Date

    /// Format memory as concise text block for prompt injection.
    /// Capped at 400 characters to control token budget on local models.
    /// Priority: phase/stance > summary > key_topics > shared_context > pending > communication > mood.
    func formatForPrompt() -> String? {
        var parts: [String] = []
        // Phase and stance are highest priority — directly affect reply coherence
        if !conversationPhase.isEmpty && conversationPhase != "无" {
            parts.append("当前对话阶段: \(conversationPhase)")
        }
        if !stance.isEmpty { parts.append("你的立场: \(stance)") }
        if !summary.isEmpty { parts.append("摘要: \(summary)") }
        if !keyTopics.isEmpty { parts.append("最近话题: \(keyTopics.joined(separator: "、"))") }
        if !sharedContext.isEmpty { parts.append("共同背景: \(sharedContext.joined(separator: "、"))") }
        if !pendingItems.isEmpty { parts.append("待办/未完成: \(pendingItems.joined(separator: "、"))") }
        if !communicationNotes.isEmpty { parts.append("沟通习惯: \(communicationNotes.joined(separator: "、"))") }
        if !moodTrend.isEmpty { parts.append("情绪: \(moodTrend)") }
        guard !parts.isEmpty else { return nil }

        // Two-pass truncation: reserve first 80 chars for phase+stance (indices 0-1),
        // remaining 320 chars for other fields.
        var result = ""
        for (idx, part) in parts.enumerated() {
            let candidate = result.isEmpty ? part : result + "\n" + part
            // Phase/stance fields (first 2) get 80-char budget
            // Remaining fields share 320-char budget (total 400)
            let limit = idx < 2 ? 80 : 400
            if candidate.count > limit { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Reply Timing Profile

/// Per-contact reply timing model. Stores delay distribution across time periods.
struct ReplyTimingProfile {
    let chatUsername: String
    /// Delay in seconds at P25/P50/P75 percentiles per time period.
    var workHours: DelayDistribution   // Mon-Fri 9:00-18:00
    var evening: DelayDistribution     // 18:00-23:00
    var weekend: DelayDistribution     // Sat-Sun 9:00-23:00
    var lateNight: DelayDistribution   // 23:00-7:00
    /// Whether user historically stays silent during late night (23:00-7:00).
    var silentAtNight: Bool
    /// Late-night reply rate (0.0-1.0). Used for configurable threshold comparison.
    var lateNightReplyRate: Double
    /// Total reply pairs analyzed.
    var sampleCount: Int
    var lastUpdated: Date

    struct DelayDistribution: Codable {
        var p25: Int  // seconds
        var p50: Int  // seconds (median)
        var p75: Int  // seconds
        var count: Int

        static let zero = DelayDistribution(p25: 0, p50: 0, p75: 0, count: 0)

        /// Pick a random delay within the distribution range to mimic human variance.
        func randomDelay() -> TimeInterval {
            guard count > 0, p50 > 0 else { return 30 } // fallback: 30s
            // Random between P25 and P75 with slight bias toward P50
            let lo = Double(p25)
            let hi = Double(p75)
            let mid = Double(p50)
            let r = Double.random(in: 0...1)
            // Weighted toward median: 50% chance in P25-P50, 50% in P50-P75
            let delay = r < 0.5
                ? lo + (mid - lo) * (r * 2)
                : mid + (hi - mid) * ((r - 0.5) * 2)
            return max(5, delay) // minimum 5 seconds
        }
    }
}

/// Message urgency level — affects reply delay.
enum MessageUrgency {
    case high    // 问号、"急"、"在吗"
    case normal
    case low     // 表情、闲聊

    /// Multiplier applied to base delay. < 1.0 = faster reply.
    var delayMultiplier: Double {
        switch self {
        case .high: return 0.4
        case .normal: return 1.0
        case .low: return 1.3
        }
    }

    /// Detect urgency from message text.
    static func detect(from text: String) -> MessageUrgency {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // High urgency signals
        let highSignals = ["?", "？", "急", "在吗", "在不在", "有空吗", "能不能",
                           "马上", "立刻", "尽快", "赶紧", "！！", "!!", "ASAP"]
        for signal in highSignals {
            if t.contains(signal) { return .high }
        }
        // Multiple question marks
        if t.filter({ $0 == "？" || $0 == "?" }).count >= 2 { return .high }
        // Very short messages are often low urgency (greetings, stickers)
        if t.count <= 2 { return .low }
        return .normal
    }
}

// MARK: - Relationship Strength

struct RelationshipStrength {
    let score: Int  // 0-100
    let label: String
    let daysSinceLastInteraction: Int

    var color: String {
        if score >= 80 { return "green" }
        if score >= 50 { return "yellow" }
        if score >= 20 { return "orange" }
        return "red"
    }

    var isCooling: Bool { daysSinceLastInteraction >= 7 }
}

// MARK: - Chat Trend

struct DayMessageCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

// MARK: - DB Key

struct DBKey {
    let relativePath: String
    let encKey: Data         // 32 bytes
}

// MARK: - Autopilot

/// Autopilot action taken for a message.
enum AutopilotAction: String, Codable {
    case sent           // auto-replied successfully
    case pending        // AI not confident enough, waiting for user review
    case skipped        // message doesn't need reply (sticker, system msg, etc.)
    case readNoReply    // opened chat (triggered read receipt) but no reply
    case proactive      // proactively initiated conversation
    case vipNotified    // VIP contact — sent "busy" notice instead of real reply
    case failed         // attempted send but failed
    case groupLogged    // group @mention — logged only, not replied
}

/// Risk level assessed by AI for an auto-reply.
enum AutopilotRisk: String, Codable {
    case low
    case medium
    case high
}

/// One autopilot log entry — every message processed during autopilot mode.
struct AutopilotLogEntry: Identifiable {
    let id: Int64
    let sessionId: Int64
    let chatUsername: String
    let chatName: String
    let senderUsername: String
    let senderName: String
    let triggerMsgUID: String
    let triggerText: String
    let generatedReply: String?
    let confidence: Double
    let riskLevel: AutopilotRisk
    let action: AutopilotAction
    let aiReasoning: String?
    let sentAt: Date?
    let createdAt: Date
}

/// An autopilot session — one contiguous period of autopilot mode.
struct AutopilotSession: Identifiable {
    let id: Int64
    let startedAt: Date
    var endedAt: Date?
    var totalHandled: Int
    var totalPending: Int
    var totalSent: Int
}

/// Reply style preference for autopilot-generated replies.
enum AutopilotReplyStyle: String, Codable, CaseIterable {
    case auto       // follow user's historical style (default)
    case brief      // always keep replies under 15 chars
    case detailed   // always give complete answers

    var label: String {
        switch self {
        case .auto:     return "跟随历史风格"
        case .brief:    return "极简模式"
        case .detailed: return "详细模式"
        }
    }

    var hint: String {
        switch self {
        case .auto:     return "分析你的聊天记录，模仿真实风格回复"
        case .brief:    return "所有回复控制在 15 字以内"
        case .detailed: return "完整回答对方的问题，不省略细节"
        }
    }

    var promptFragment: String {
        switch self {
        case .auto:     return ""
        case .brief:    return "\n额外要求：回复必须极简，不超过 15 个字。能用一两个字回的绝不多说。"
        case .detailed: return "\n额外要求：回复要完整详细，回答对方所有问题，不省略信息。"
        }
    }
}

/// Persisted autopilot configuration.
struct AutopilotConfig: Codable {
    var enabled: Bool = false
    /// Confidence threshold for auto-sending (0.0-1.0). Below this → pending review.
    var confidenceThreshold: Double = 0.8
    /// Max auto-replies per hour (rate limit).
    var maxRepliesPerHour: Int = 20
    /// Whether to handle group @mentions (currently false per user request).
    var handleGroupAt: Bool = false
    /// Whether VIP contacts get the "busy" auto-notification.
    var vipAutoNotify: Bool = true
    /// The "busy" message template for VIP contacts.
    var vipBusyTemplate: String = "你好，我现在可能正在忙，你的消息已标记为重要信息，会马上通知他查看回复。"
    /// Seconds to wait for more messages before processing a batch.
    var batchWindowSeconds: Int = 10
    /// Contact usernames excluded from autopilot (never auto-reply).
    var excludedContacts: [String] = []
    /// Reply style preference.
    var replyStyle: AutopilotReplyStyle = .auto
    /// Maximum total sends per autopilot session. 0 = unlimited.
    var maxSendsPerSession: Int = 50
    /// Sensitive keywords — if AI reply contains any, route to pending review.
    var sensitiveKeywords: [String] = [
        "钱", "转账", "汇款", "银行卡", "密码", "验证码",
        "合同", "签字", "辞职", "离职", "解雇",
        "骂", "傻逼", "滚", "操", "妈的"
    ]
    /// Global reply speed multiplier. < 1.0 = faster, > 1.0 = slower. Default 1.0.
    var replySpeedMultiplier: Double = 1.0
    /// Enable proactive messaging (autopilot initiates conversations). Default false.
    var proactiveEnabled: Bool = false
    /// Max proactive messages per session. Default 3.
    var maxProactivePerSession: Int = 3
    /// Minimum days since last interaction before proactive outreach. Default 3.
    var proactiveSilenceDays: Int = 3
    /// Late-night silence threshold (0.0-1.0). If reply rate in 23:00-7:00 < this → silent.
    var silentNightThreshold: Double = 0.2
}
