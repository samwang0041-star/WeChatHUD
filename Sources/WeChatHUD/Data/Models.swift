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

/// Escalation tiers for an unanswered VIP message. Computed purely
/// from how long the item has been overdue — ProactiveAlertEngine
/// advances the tier on each scan and fires the right signal for
/// each level:
///
/// - `.t1` (30m+): one system notification
/// - `.t2` (60m+): menu-bar "!" badge + compact pill pulse (visual only)
/// - `.t3` (120m+): second system notification + in-panel toast
/// - `.t4` (240m+): third notification + persistent "!Nh" in menu bar
///
/// Each tier only fires once per item; resetting requires the user to
/// act on the item (reply / dismiss / snooze).
enum VIPAlertTier: Int, Comparable, Codable {
    case none = 0
    case t1 = 1
    case t2 = 2
    case t3 = 3
    case t4 = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func compute(overdueMinutes: Int) -> Self {
        if overdueMinutes >= 240 { return .t4 }
        if overdueMinutes >= 120 { return .t3 }
        if overdueMinutes >= 60  { return .t2 }
        if overdueMinutes >= 30  { return .t1 }
        return .none
    }

    /// Approximate "how long has this been overdue" label — rendered in
    /// the menu bar and banner so the user knows how urgent it is.
    var agingLabel: String {
        switch self {
        case .none: return ""
        case .t1:   return "30m"
        case .t2:   return "1h"
        case .t3:   return "2h"
        case .t4:   return "4h+"
        }
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case ok
    case stale              // >5 min since last sync
    case waitingForWeChat   // WeChat process not running
    case accountSwitched    // WeChat logged into a different account since we started
    case error(String)

    var dotColor: String {
        switch self {
        case .idle, .syncing: return "yellow"
        case .ok: return "green"
        case .stale: return "yellow"
        case .waitingForWeChat, .error, .accountSwitched: return "red"
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

struct MessageInfo: Identifiable, Codable {
    let id: String           // message UID
    /// Local row id inside the chat's Msg table. Used only as a
    /// tie-breaker when multiple WeChat messages share the same second.
    let localId: Int
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

    init(
        id: String,
        localId: Int = 0,
        chatUsername: String,
        chatName: String,
        senderUsername: String,
        senderName: String,
        text: String,
        baseType: Int,
        subType: Int,
        createTime: Int,
        appType: Int = 0
    ) {
        self.id = id
        self.localId = localId
        self.chatUsername = chatUsername
        self.chatName = chatName
        self.senderUsername = senderUsername
        self.senderName = senderName
        self.text = text
        self.baseType = baseType
        self.subType = subType
        self.createTime = createTime
        self.appType = appType
    }

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
    /// Counterpart sent a substantive message (money / specific time /
    /// decision / commitment-reference) and the user's only reply
    /// was an ack ("嗯嗯", "好的"). Flag so the user doesn't let an
    /// important point slide with a hollow acknowledgment.
    case unsubstantiveReply

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
        case .unsubstantiveReply: return "未实质回应"
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
    /// Exact source retained for context; never substitute another message in this chat.
    var contextNotification: HUDNotification? = nil
}

struct ReplyDebtConfig: Codable {
    var maxSessions: Int = 100
    var normalOverdueMinutes: Int = 120
    var vipOverdueMinutes: Int = 30
    var groupAtOverdueMinutes: Int = 30
}


// MARK: - Notification

enum HUDNotificationKind: Equatable {
    /// 1-on-1 private chat.
    case privateChat
    /// Group chat where the user was explicitly @-mentioned (or @All/@所有人).
    case groupAt
    /// Group chat, regular message (not mentioning the user).
    case groupMessage
}

struct HUDNotification: Identifiable, Equatable {
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

    var presentationSemanticState: InboxSemanticState {
        switch kind {
        case .privateChat:
            return isVIP ? .privateVIPRisk : .privateInfoOnly
        case .groupAt:
            return .groupMentionFYI
        case .groupMessage:
            return .groupInfoOnly
        }
    }

    var supportsDeepActionContext: Bool {
        guard kind == .groupAt else { return false }
        let text = rawText
        return text.contains("?")
            || text.contains("？")
            || text.contains("吗")
            || text.contains("能否")
            || text.contains("能不能")
            || text.contains("要不要")
            || text.contains("是不是")
            || text.contains("确认")
            || text.contains("决定")
            || text.contains("拍板")
            || text.contains("看下")
            || text.contains("看看")
    }

    var isVIP: Bool {
        attentionLevel == .vip
    }

    var briefingKey: String {
        if !messageID.isEmpty { return messageID }
        return "\(chatUsername):\(Int(timestamp.timeIntervalSince1970)):\(senderName)"
    }

    /// Action target for banner/island snooze. Never fall back to another chat.
    func actionInboxItem() -> InboxItem {
        InboxItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: senderName,
            preview: snippet,
            isGroup: kind != .privateChat,
            timestamp: timestamp,
            actionRequired: true,
            priority: isVIP ? .p0 : .p1,
            isVIP: isVIP,
            isWhitelisted: true,
            unreadCount: 1,
            isAtMention: isAtMention,
            askType: .none,
            reasons: [],
            suggestedReplyMinutes: 60,
            status: .active,
            dismissedAtMsgId: nil,
            aiSummary: nil,
            moodEmoji: nil
        )
    }

    static func == (lhs: HUDNotification, rhs: HUDNotification) -> Bool {
        lhs.chatUsername == rhs.chatUsername
            && lhs.messageID == rhs.messageID
            && lhs.snippet == rhs.snippet
            && lhs.rawText == rhs.rawText
            && lhs.timestamp == rhs.timestamp
            && lhs.kind == rhs.kind
            && lhs.isAtMention == rhs.isAtMention
            && lhs.senderUsername == rhs.senderUsername
            && lhs.attentionLevel == rhs.attentionLevel
    }
}

struct ScanDismissedEntry: Identifiable {
    var id: String { username }
    let username: String
    let displayName: String
    let dismissedAt: Date
}

struct IgnoredSenderRule: Identifiable, Equatable {
    let chatUsername: String
    let chatName: String
    let senderIdentifier: String
    let senderUsername: String
    let senderName: String
    let createdAt: Date
    /// Where this rule applies. `chat` matches only inside one conversation;
    /// `global` follows the person everywhere.
    let scope: IgnoredSenderScope

    var id: String { "\(chatUsername)|\(senderIdentifier)" }
}

enum IgnoredSenderScope: String, Codable, CaseIterable {
    case chat
    case global

    var label: String {
        switch self {
        case .chat: return "仅这个对话"
        case .global: return "所有对话"
        }
    }
}

/// A member the user wants to hear from inside one group, even without an @.
///
/// Groups are noisy by design: the room is worth following, but only because
/// of two or three people in it. This records exactly that.
struct GroupMemberRule: Identifiable, Equatable {
    let chatUsername: String
    let chatName: String
    let senderUsername: String
    let senderName: String
    let createdAt: Date

    var id: String { "\(chatUsername)|\(senderUsername)" }
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
/// Unified AI configuration. Single source of truth for all AI services.
/// Stored in the `ai` row of the `settings` table.
/// Read via `HUDStore.loadAIConfig()`.
/// Per-slot provider connection info (cloud or local).
struct AIProviderSlot: Codable, Equatable {
    var providerID: String = "custom"
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""

    enum CodingKeys: String, CodingKey {
        case providerID, baseURL, model, apiKey
    }

    init(
        providerID: String = "custom",
        baseURL: String = "",
        model: String = "",
        apiKey: String = ""
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? "custom"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(apiKey, forKey: .apiKey)
    }
}

struct AIConfig: Codable {
    // Single provider slot — a preset vendor or a custom service.
    var provider: AIProviderSlot = AIProviderSlot()

    // Legacy single-provider fields — migration only, encoded as _legacy* to
    // avoid clashing with the computed compatibility shims below.
    var _legacyBaseURL: String?
    var _legacyModel: String?
    var _legacyApiKey: String?
    var _legacyProviderID: String?

    // Generation defaults (services may override per-call)
    var maxTokens: Int = 2048
    var temperature: Double = 0.3

    // Capability toggles
    var summaryEnabled: Bool = true
    var suggestionsEnabled: Bool = true
    var moodDetectionEnabled: Bool = true
    var debtJudgeEnabled: Bool = true
    var debtJudgeShadowMode: Bool = true
    var thinkingEnabled: Bool = false
    var dailyReportActionInsightsEnabled: Bool = true

    // ── Compatibility shims ──
    // All existing services read `config.baseURL` / `.model` / `.apiKey`.
    // These resolve to the single provider slot so nothing else needs to change.
    var baseURL: String {
        get { provider.baseURL }
        set { /* no-op — use slot setters */ }
    }
    var model: String {
        get { provider.model }
        set { /* no-op */ }
    }
    var apiKey: String {
        get { provider.apiKey }
        set { /* no-op */ }
    }

    private static func slotIsConfigured(_ slot: AIProviderSlot) -> Bool {
        // Codex slots are valid even with an empty baseURL — the URL is
        // hardcoded and auth comes from the codex CLI login state.
        !slot.baseURL.isEmpty || slot.providerID == "openai-codex"
    }

    /// Migrate from old single-provider format if needed.
    mutating func migrateIfNeeded() {
        if !Self.slotIsConfigured(provider), let url = _legacyBaseURL, !url.isEmpty {
            provider = AIProviderSlot(
                providerID: _legacyProviderID ?? "custom",
                baseURL: url,
                model: _legacyModel ?? "",
                apiKey: _legacyApiKey ?? ""
            )
        }
        _legacyBaseURL = nil
        _legacyModel = nil
        _legacyApiKey = nil
        _legacyProviderID = nil
    }

    // Custom coding keys — decode old dual-slot and single-provider keys into
    // migration-only fields. Encoding writes the single "provider" key only.
    enum CodingKeys: String, CodingKey {
        case provider
        case legacyCloudProvider = "cloudProvider"
        case legacyLocalProvider = "localProvider"
        case legacyActiveMode = "activeMode"
        case legacyAutoCloudFirst = "autoCloudFirst"
        case _legacyBaseURL = "baseURL"
        case _legacyModel = "model"
        case _legacyApiKey = "apiKey"
        case _legacyProviderID = "providerID"
        case maxTokens, temperature
        case summaryEnabled, suggestionsEnabled, moodDetectionEnabled
        case debtJudgeEnabled, debtJudgeShadowMode, thinkingEnabled
        case dailyReportActionInsightsEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(AIProviderSlot.self, forKey: .provider) ?? AIProviderSlot()
        let legacyCloud = try container.decodeIfPresent(AIProviderSlot.self, forKey: .legacyCloudProvider) ?? AIProviderSlot()
        let legacyLocal = try container.decodeIfPresent(AIProviderSlot.self, forKey: .legacyLocalProvider) ?? AIProviderSlot()
        // Old activeMode values were "local"/"cloud"/"auto"; unreadable values
        // (corrupt data or future formats) fall back to the local slot.
        let legacyModeRaw = try container.decodeIfPresent(String.self, forKey: .legacyActiveMode) ?? "local"
        let legacyAutoCloudFirst = try container.decodeIfPresent(Bool.self, forKey: .legacyAutoCloudFirst) ?? true
        if !Self.slotIsConfigured(provider) {
            let primary: AIProviderSlot
            switch legacyModeRaw {
            case "cloud": primary = legacyCloud
            case "auto": primary = legacyAutoCloudFirst ? legacyCloud : legacyLocal
            default: primary = legacyLocal
            }
            if Self.slotIsConfigured(primary) {
                provider = primary
            } else if Self.slotIsConfigured(legacyCloud) {
                provider = legacyCloud
            } else if Self.slotIsConfigured(legacyLocal) {
                provider = legacyLocal
            }
        }
        _legacyBaseURL = try container.decodeIfPresent(String.self, forKey: ._legacyBaseURL)
        _legacyModel = try container.decodeIfPresent(String.self, forKey: ._legacyModel)
        _legacyApiKey = try container.decodeIfPresent(String.self, forKey: ._legacyApiKey)
        _legacyProviderID = try container.decodeIfPresent(String.self, forKey: ._legacyProviderID)
        migrateIfNeeded()
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.3
        summaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .summaryEnabled) ?? true
        suggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .suggestionsEnabled) ?? true
        moodDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .moodDetectionEnabled) ?? true
        debtJudgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .debtJudgeEnabled) ?? true
        debtJudgeShadowMode = try container.decodeIfPresent(Bool.self, forKey: .debtJudgeShadowMode) ?? true
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        dailyReportActionInsightsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dailyReportActionInsightsEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(summaryEnabled, forKey: .summaryEnabled)
        try container.encode(suggestionsEnabled, forKey: .suggestionsEnabled)
        try container.encode(moodDetectionEnabled, forKey: .moodDetectionEnabled)
        try container.encode(debtJudgeEnabled, forKey: .debtJudgeEnabled)
        try container.encode(debtJudgeShadowMode, forKey: .debtJudgeShadowMode)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encode(dailyReportActionInsightsEnabled, forKey: .dailyReportActionInsightsEnabled)
    }
}

// MARK: - AI Provider Presets

struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let models: [String]       // first is default
    let requiresKey: Bool
    let signupURL: String      // where to get an API key

    static let builtIn: [AIProvider] = [
        AIProvider(
            id: "dashscope",
            name: "阿里百炼 (DashScope)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            models: ["qwen-plus", "qwen-turbo", "qwen-max", "qwen-long"],
            requiresKey: true,
            signupURL: "https://bailian.console.aliyun.com/"
        ),
        AIProvider(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            models: ["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat", "deepseek-reasoner"],
            requiresKey: true,
            signupURL: "https://platform.deepseek.com/"
        ),
        AIProvider(
            id: "siliconflow",
            name: "硅基流动 (SiliconFlow)",
            baseURL: "https://api.siliconflow.cn",
            models: ["Qwen/Qwen2.5-72B-Instruct", "deepseek-ai/DeepSeek-V3", "Pro/Qwen/Qwen2.5-Coder-32B-Instruct"],
            requiresKey: true,
            signupURL: "https://cloud.siliconflow.cn/"
        ),
        AIProvider(
            id: "moonshot",
            name: "月之暗面 (Kimi)",
            baseURL: "https://api.moonshot.cn",
            models: ["kimi-k2.6", "kimi-k2.5", "kimi-k2-thinking", "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],
            requiresKey: true,
            signupURL: "https://platform.moonshot.cn/"
        ),
        AIProvider(
            id: "kimicode",
            name: "Kimi Coding Plan (kimi.com)",
            baseURL: "https://api.kimi.com/coding/v1",
            models: ["kimi-for-coding", "kimi-k2.6", "k2p6", "kimi-k2.5", "k2p5", "kimi-k2-thinking", "kimi-k2-turbo-preview"],
            requiresKey: true,
            signupURL: "https://kimi.com"
        ),
        AIProvider(
            id: "zhipu",
            name: "智谱 (GLM)",
            baseURL: "https://open.bigmodel.cn/api/paas",
            models: ["glm-4-flash", "glm-4", "glm-4-plus"],
            requiresKey: true,
            signupURL: "https://open.bigmodel.cn/"
        ),
        AIProvider(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com",
            models: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1-nano"],
            requiresKey: true,
            signupURL: "https://platform.openai.com/"
        ),
        AIProvider(
            id: "ollama",
            name: "Ollama (本地)",
            baseURL: "http://127.0.0.1:11434",
            models: ["qwen2.5:14b", "qwen2.5:7b", "llama3.1:8b", "deepseek-r1:14b"],
            requiresKey: false,
            signupURL: ""
        ),
        // Special-cased provider: requires no API key and no baseURL.
        // Reads OAuth tokens from `~/.codex/auth.json` (codex-cli login state)
        // and posts to chatgpt.com/backend-api/codex/responses with a request
        // fingerprint identical to OpenClaw / pi-ai. Dispatched by
        // `AIService.send` when `slot.providerID == "openai-codex"`.
        AIProvider(
            id: "openai-codex",
            name: "OpenAI Codex (ChatGPT 订阅)",
            baseURL: "",
            models: ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.3-codex"],
            requiresKey: false,
            signupURL: "https://github.com/openai/codex"
        ),
        AIProvider(
            id: "custom",
            name: "自定义",
            baseURL: "",
            models: [],
            requiresKey: false,
            signupURL: ""
        ),
    ]

    static func find(_ id: String) -> AIProvider? {
        builtIn.first { $0.id == id }
    }
}

struct SyncConfig: Codable {
    var intervalSeconds: Int = 30
    var wechatDBPath: String = "auto"
    /// User-selected local key JSON. nil keeps the historical default path.
    var keysFilePath: String? = nil
    var cacheStrategy: CacheStrategy = .temporary
    var displayScreen: DisplayScreen = .builtIn
}

/// Which screen to show the floating panel on.
enum DisplayScreen: String, Codable, CaseIterable {
    case builtIn  = "builtin"
    case external = "external"

    var label: String {
        switch self {
        case .builtIn:  return "原生屏幕"
        case .external: return "扩展屏"
        }
    }
}

/// Where decrypted WeChat DBs are cached.
enum CacheStrategy: String, Codable, CaseIterable {
    case persistent   // ~/.wechat-hud/cache/ — fast cold start, plaintext on disk
    case temporary    // /tmp/wechat_hud_cache/ — cleared on reboot
    case memory       // process-scoped temporary files; removed on normal cleanup

    var label: String {
        switch self {
        case .persistent: return "持久磁盘"
        case .temporary:  return "临时磁盘"
        case .memory:     return "会话临时"
        }
    }

    var hint: String {
        switch self {
        case .persistent: return "~/.wechat-hud/cache — 启动最快，明文落盘"
        case .temporary:  return "/tmp — 重启清空，每次开机首次解密"
        case .memory:     return "会话临时文件 — 正常退出时清理，每次启动重新解密"
        }
    }
}

struct NotificationConfig: Codable {
    var atMention: Bool = true
    var important: Bool = true
    var allWhitelist: Bool = false
    var durationSeconds: Int = 3

    func shouldPresent(_ semantic: InboxSemanticState) -> Bool {
        switch semantic {
        case .privateVIPRisk: return important
        case .groupMentionFYI: return atMention
        case .privateInfoOnly, .groupInfoOnly: return allWhitelist
        default: return false
        }
    }
}

// MARK: - Message admission

/// How wide the net is cast when deciding what reaches the user.
enum AdmissionMode: String, Codable, CaseIterable {
    /// Only conversations the user explicitly follows, plus VIP people, @s and
    /// watched group members.
    case whitelistOnly = "whitelist_only"
    /// Every conversation with unread messages, as WeChat reports them.
    case all = "all"

    var label: String {
        switch self {
        case .whitelistOnly: return "只提醒我关注的人"
        case .all: return "全部未读都提醒"
        }
    }

    var detail: String {
        switch self {
        case .whitelistOnly:
            return "只有关注的人、群里 @你、以及你点名的成员会进来。关注一个群不会把每一条闲聊都拿来分析。"
        case .all:
            return "微信里有未读的对话都会进收件箱。摘要和待办仍只整理你关注的人和群。"
        }
    }
}

/// Who is allowed to reach the user, and how.
///
/// This is deliberately one setting rather than scattered flags: the question
/// "why did this message show up" has to have a single answer, or the user
/// cannot predict the app.
struct AdmissionConfig: Codable, Equatable {
    var mode: AdmissionMode = .whitelistOnly
    /// Groups where an @ still reaches the inbox but must not raise a banner.
    /// Muting outright would silently drop the one message the user was
    /// probably waiting for; this keeps it, quietly.
    var atMutedGroups: Set<String> = []

    init(mode: AdmissionMode = .whitelistOnly, atMutedGroups: Set<String> = []) {
        self.mode = mode
        self.atMutedGroups = atMutedGroups
    }

    // Tolerate configs written by an earlier build.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AdmissionMode.self, forKey: .mode) ?? .whitelistOnly
        atMutedGroups = try container.decodeIfPresent(Set<String>.self, forKey: .atMutedGroups) ?? []
    }
}

// MARK: - AI Subsystem

/// Categories the classifier emits for what kind of action a message is
/// asking the recipient to perform. `none` is the negative case.
enum AskType: String, Codable, Equatable {
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
    case summarizer        = "summarizer"
    case briefer           = "briefer"
    case chatAnalyzer      = "chat_analyzer"
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

struct Commitment: Identifiable, Equatable {
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
    let sourceText: String
    let contextText: String
    let captureReason: String
    let nextStep: String
    let deadlineLabel: String
    let commitmentKind: String

    init(
        id: Int64,
        msgUID: String,
        chatUsername: String,
        chatName: String,
        content: String,
        commitTo: String,
        deadlineAt: Date?,
        confidence: Double,
        status: CommitmentStatus,
        promptVersion: String,
        createdAt: Date,
        updatedAt: Date,
        sourceText: String = "",
        contextText: String = "",
        captureReason: String = "",
        nextStep: String = "",
        deadlineLabel: String = "",
        commitmentKind: String = ""
    ) {
        self.id = id
        self.msgUID = msgUID
        self.chatUsername = chatUsername
        self.chatName = chatName
        self.content = content
        self.commitTo = commitTo
        self.deadlineAt = deadlineAt
        self.confidence = confidence
        self.status = status
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceText = sourceText
        self.contextText = contextText
        self.captureReason = captureReason
        self.nextStep = nextStep
        self.deadlineLabel = deadlineLabel
        self.commitmentKind = commitmentKind
    }
}

// MARK: - DiscussionItem (bidirectional conversation-extracted work items)

/// The kind of thing extracted from a conversation. Drives the UI
/// icon + filter chip + sort priority.
enum DiscussionItemKind: String, Codable, CaseIterable {
    case todo       // 待办事项
    case decision   // 待决策（讨论过，没定）
    case info       // 信息点（地址/价格/关键信息）
    case timePlace  // 时间地点（约见/截止）
    case question   // 悬而未决的问题

    var label: String {
        switch self {
        case .todo:      return "待办"
        case .decision:  return "待决策"
        case .info:      return "信息"
        case .timePlace: return "时间地点"
        case .question:  return "待确认"
        }
    }

    var iconName: String {
        switch self {
        case .todo:      return "checkmark.square"
        case .decision:  return "arrow.triangle.branch"
        case .info:      return "info.circle"
        case .timePlace: return "calendar"
        case .question:  return "questionmark.circle"
        }
    }
}

/// Whose responsibility is the item — drives the "上级交代给我 / 我交代给下级"
/// weekly-report slicing. `mine` = I need to do it; `theirs` = other
/// party needs to do it; `shared` = undetermined or joint.
enum DiscussionItemOwner: String, Codable {
    case mine
    case theirs
    case shared

    var label: String {
        switch self {
        case .mine:   return "我要做"
        case .theirs: return "对方要做"
        case .shared: return "双方"
        }
    }

    /// Customer-facing label used in the 不漏事 workspace.
    var workspaceLabel: String {
        switch self {
        case .mine: return "我来做"
        case .theirs: return "等对方"
        case .shared: return "共同推进"
        }
    }
}

enum DiscussionItemStatus: String, Codable {
    case pending    // 默认
    case done       // 用户手动标记完成
    case dismissed  // 用户觉得不是待办，扔掉
    case archived   // 老了，折叠
}

/// Bounded HUD window so old discussion rows stay out of the live list.
enum DiscussionLiveWindow {
    static let pendingDays = 14
    static let historyDays = 14
    static let catalogDays = 30

    static func cutoff(days: Int, now: Date = Date()) -> Int {
        Int(now.timeIntervalSince1970) - days * 86_400
    }

    static func contains(_ item: DiscussionItem, cutoff: Int) -> Bool {
        if item.sourceTimestamp >= cutoff { return true }
        if let due = item.dueAt, Int(due.timeIntervalSince1970) >= cutoff { return true }
        // Recently completed / archived rows stay visible in history even when
        // the original source is older than the window.
        if item.status != .pending, Int(item.updatedAt.timeIntervalSince1970) >= cutoff {
            return true
        }
        return false
    }

    static func contains(_ item: Commitment, cutoff: Int) -> Bool {
        if item.status == .pending || item.status == .overdue { return true }
        if Int(item.createdAt.timeIntervalSince1970) >= cutoff { return true }
        if let due = item.deadlineAt, Int(due.timeIntervalSince1970) >= cutoff { return true }
        if Int(item.updatedAt.timeIntervalSince1970) >= cutoff { return true }
        return false
    }

    /// Classifier asks use the same 14-day source/due window as discussion.
    static func contains(_ ask: PendingAsk, cutoff: Int) -> Bool {
        if Int(ask.createdAt.timeIntervalSince1970) >= cutoff { return true }
        if let due = ask.deadlineAt, Int(due.timeIntervalSince1970) >= cutoff { return true }
        return false
    }
}

struct DiscussionItem: Identifiable, Equatable {
    let id: Int64
    let chatUsername: String
    let chatName: String
    let kind: DiscussionItemKind
    let owner: DiscussionItemOwner
    /// The item text, one line e.g. "下周五之前提交 Q2 方案".
    let content: String
    /// Optional free-form detail extracted alongside (rationale, deps).
    let detail: String?
    /// Anchor message that produced this item. Used for dedupe and
    /// to link back to the source conversation.
    let anchorMsgUID: String
    /// Unix seconds of the source message — used for weekly slicing.
    let sourceTimestamp: Int
    let dueAt: Date?
    var status: DiscussionItemStatus
    let confidence: Double
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
    /// Capped at 800 characters to give AI enough context for 7-day comparison
    /// while staying within the 2500-token budget.
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

        // Two-pass truncation: reserve first 120 chars for phase+stance (indices 0-1),
        // remaining 680 chars for other fields (total 800).
        var result = ""
        for (idx, part) in parts.enumerated() {
            let candidate = result.isEmpty ? part : result + "\n" + part
            let limit = idx < 2 ? 120 : 800
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

/// One outgoing message inside an active autopilot session. The ledger
/// is injected into the next reply's prompt so the model can stay
/// consistent with what it just said. Lives in memory on `ChatMonitor`
/// and resets when the autopilot session starts or stops.
struct LedgerEntry: Equatable {
    let timestamp: Date
    let outgoingText: String
    let peerLastMessage: String?
    let topic: String?
}

/// Autopilot action taken for a message.
enum AutopilotAction: String, Codable {
    case sent           // auto-replied successfully
    case stall          // sent a stalling reply (not a real answer, buying time)
    case pending        // AI not confident enough, waiting for user review (legacy — full-auto mode never produces this)
    case queued         // low-risk auto-send is waiting for human-like delay
    case skipped        // message doesn't need reply (sticker, system msg, etc.)
    case readNoReply    // opened chat (triggered read receipt) but no reply
    case proactive      // proactively initiated conversation
    case vipNotified    // VIP contact — sent "busy" notice instead of real reply (legacy)
    case failed         // attempted send but failed
    case groupLogged    // group @mention — logged only, not replied
}

/// Risk level assessed by AI for an auto-reply.
enum AutopilotRisk: String, Codable {
    case low
    case medium
    case high

    /// User-facing Chinese label — the rawValue is English and leaks
    /// "HIGH"/"MEDIUM" into the UI if displayed verbatim.
    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
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
    var generatedReply: String?
    let confidence: Double
    let riskLevel: AutopilotRisk
    let action: AutopilotAction
    let aiReasoning: String?
    let sentAt: Date?
    let createdAt: Date

    func replacingReply(_ reply: String) -> AutopilotLogEntry {
        AutopilotLogEntry(
            id: id,
            sessionId: sessionId,
            chatUsername: chatUsername,
            chatName: chatName,
            senderUsername: senderUsername,
            senderName: senderName,
            triggerMsgUID: triggerMsgUID,
            triggerText: triggerText,
            generatedReply: reply,
            confidence: confidence,
            riskLevel: riskLevel,
            action: action,
            aiReasoning: aiReasoning,
            sentAt: sentAt,
            createdAt: createdAt
        )
    }
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
        case .auto:     return "跟随我的习惯"
        case .brief:    return "极简模式"
        case .detailed: return "详细模式"
        }
    }

    var hint: String {
        switch self {
        case .auto:     return "根据你过往的聊天风格来生成回复。"
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

// MARK: - Pending Send Queue

/// A message queued for delayed sending. Visible to UI for cancel/edit/send-now.
struct PendingSend: Identifiable {
    let id: UUID
    let chatUsername: String
    let chatName: String
    let senderName: String
    var replyText: String
    let confidence: Double
    let risk: AutopilotRisk
    let reasoning: String
    let styleScore: Int
    let scheduledSendTime: Date
    let createdAt: Date
    /// The peer message that triggered this reply, if available. Used by
    /// the session ledger so later prompts can echo back naturally.
    var peerLastMessage: String? = nil
    /// Conversation phase snapshot at the time the reply was drafted.
    /// Used as the ledger entry's `topic`.
    var topic: String? = nil
    /// Number of automated send attempts. A failed or unverified send
    /// must not be retried blindly; it becomes manual-only.
    var autoSendAttempts: Int = 0
    /// Non-nil means timers must not auto-send this item. The user can
    /// still inspect, edit, cancel, or explicitly send it from the UI.
    var manualOnlyReason: String? = nil

    init(
        id: UUID = UUID(),
        chatUsername: String,
        chatName: String,
        senderName: String,
        replyText: String,
        confidence: Double,
        risk: AutopilotRisk,
        reasoning: String,
        styleScore: Int,
        scheduledSendTime: Date,
        createdAt: Date = Date(),
        peerLastMessage: String? = nil,
        topic: String? = nil,
        autoSendAttempts: Int = 0,
        manualOnlyReason: String? = nil
    ) {
        self.id = id
        self.chatUsername = chatUsername
        self.chatName = chatName
        self.senderName = senderName
        self.replyText = replyText
        self.confidence = confidence
        self.risk = risk
        self.reasoning = reasoning
        self.styleScore = styleScore
        self.scheduledSendTime = scheduledSendTime
        self.createdAt = createdAt
        self.peerLastMessage = peerLastMessage
        self.topic = topic
        self.autoSendAttempts = autoSendAttempts
        self.manualOnlyReason = manualOnlyReason
    }

    /// Remaining seconds until scheduled send.
    var remainingSeconds: Int {
        max(0, Int(scheduledSendTime.timeIntervalSinceNow))
    }
}

/// Persisted autopilot configuration.
struct AutopilotConfig: Codable {
    var enabled: Bool = false
    /// Master switch for unattended WeChat sends. Default false because
    /// UI automation is inherently high-risk until target and delivery
    /// verification both pass. Manual approval/send remains available.
    var autoSendEnabled: Bool = false
    /// Confidence threshold for auto-sending (0.0-1.0). Below this → pending review.
    var confidenceThreshold: Double = 0.8
    /// Max auto-replies per hour (rate limit).
    var maxRepliesPerHour: Int = 20
    /// Whether to handle group @mentions (currently false per user request).
    var handleGroupAt: Bool = false

    /// Group traffic is logged-only unless the user turned on @-mention handling.
    func shouldQueue(isGroup: Bool, isAtMention: Bool) -> Bool {
        !isGroup || (handleGroupAt && isAtMention)
    }
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
    /// Which keystroke submits a message in WeChat. Default `.cmdEnter`
    /// matches the stock WeChat config (Enter=newline, Cmd+Enter=send).
    /// Users who flipped WeChat's preference to "Enter=send" must set
    /// this to `.enter`, otherwise the autopilot's Cmd+Enter keypress
    /// is interpreted as a newline and the message never leaves the
    /// input box.
    var sendKey: WeChatSendKey = .cmdEnter
}

/// Which keystroke submits a message in WeChat, matching the "按 Enter
/// 发送消息" preference. See `AutopilotConfig.sendKey`.
enum WeChatSendKey: String, Codable, CaseIterable {
    case cmdEnter  // default WeChat: Cmd+Enter sends, Enter inserts newline
    case enter     // user flipped it: Enter sends, Shift/Option+Enter inserts newline
}
