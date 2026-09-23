// Sources/WeChatHUD/Data/ChatInsightModels.swift
import Foundation

// MARK: - Chat Insight Result (per-chat AI output)

struct ChatInsightResult: Codable {
    /// Keys that 单聊分析 must never grow. 关系雷达 owns these.
    static let reservedInferenceKeys = ["attitudes", "tone_changes", "mood_shift"]

    let headline: String
    let topics: [TopicInsight]
    let decisions: [String]
    let actionItems: [InsightActionItem]
    let mentionsMe: Int
    let waitingForMe: [WaitingItem]
    let myCommitments: [String]
    let needsMyAttention: Bool
    let overallMood: String
    let signalNoiseRatio: Double
    let decisionEfficiency: String
    let importanceToMe: ImportanceLevel
    let crossChatTopics: [String]?
    let insight: String
    let suggestion: String

    enum CodingKeys: String, CodingKey {
        case headline, topics, decisions
        case actionItems = "action_items"
        case mentionsMe = "mentions_me"
        case waitingForMe = "waiting_for_me"
        case myCommitments = "my_commitments"
        case needsMyAttention = "needs_my_attention"
        case overallMood = "overall_mood"
        case signalNoiseRatio = "signal_noise_ratio"
        case decisionEfficiency = "decision_efficiency"
        case importanceToMe = "importance_to_me"
        case crossChatTopics = "cross_chat_topics"
        case insight, suggestion
    }
}

struct TopicInsight: Codable {
    let name: String
    let messageCount: Int
    let participantCount: Int
    let summary: String
    let status: String
    let myInvolvement: String?
    let crossChats: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case messageCount = "message_count"
        case participantCount = "participant_count"
        case summary, status
        case myInvolvement = "my_involvement"
        case crossChats = "cross_chats"
    }
}

struct InsightActionItem: Codable {
    let what: String
    let who: String
    let deadline: String?
}

struct WaitingItem: Codable {
    let source: String
    let what: String
    // `waiting_hours` is NOT a field of this model. The key is still in the
    // prompt and the model still answers it, but it is a duration nobody
    // measured: the per-chat prompt hands out bare epoch stamps with no "now"
    // anchor and the global briefing sends no timestamps at all. Decoding it
    // rendered as 「同事 已等 3 小时」 inside a red 「需要你立即处理」 row whose
    // button opens the chat to reply. A number nobody measured must not be
    // presented as one, so it is dropped at the decode boundary.

    enum CodingKeys: String, CodingKey {
        case source, what
    }
}

struct ImportanceLevel: Codable {
    let level: String
    let reason: String
}

// MARK: - Global Briefing

struct GlobalBriefing: Codable {
    let date: String
    let actionRequired: [ActionRequiredItem]
    let headline: String
    let stats: BriefingStats
    let crossTopics: [CrossTopic]
    let darkSignals: DarkSignals
    let overallMood: String
    let blindSpots: [String]
    let topSuggestion: String

    enum CodingKeys: String, CodingKey {
        case date
        case actionRequired = "action_required"
        case headline, stats
        case crossTopics = "cross_topics"
        case darkSignals = "dark_signals"
        case overallMood = "overall_mood"
        case blindSpots = "blind_spots"
        case topSuggestion = "top_suggestion"
    }
}

extension GlobalBriefing {
    /// AI `source` is a display name. Bind it to the whitelist username so
    /// tapping a briefing card opens that chat instead of bouncing back.
    func bindingChatUsernames(names: [String: String]) -> GlobalBriefing {
        GlobalBriefing(
            date: date,
            actionRequired: actionRequired.map { item in
                var item = item
                item.chatUsername = InsightChatIdentity.resolve(item.source, names: names)
                return item
            },
            headline: headline,
            stats: stats,
            crossTopics: crossTopics,
            darkSignals: darkSignals,
            overallMood: overallMood,
            blindSpots: blindSpots,
            topSuggestion: topSuggestion
        )
    }
}

struct ActionRequiredItem: Codable {
    let source: String
    let what: String
    let urgency: String
    /// Bound after decode from the whitelist the briefing was built on.
    /// AI only returns a display name in `source`.
    var chatUsername: String? = nil

    enum CodingKeys: String, CodingKey {
        case source, what, urgency
    }

    init(source: String, what: String, urgency: String, chatUsername: String? = nil) {
        self.source = source
        self.what = what
        self.urgency = urgency
        self.chatUsername = chatUsername
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        what = try container.decode(String.self, forKey: .what)
        urgency = try container.decode(String.self, forKey: .urgency)
        chatUsername = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(what, forKey: .what)
        try container.encode(urgency, forKey: .urgency)
    }
}

struct CrossTopic: Codable {
    let name: String
    let chats: [String]
    let summary: String
    let conflict: String?
    let status: String
}

struct DarkSignals: Codable {
    let headline: String?
}

struct BriefingStats: Codable {
    let totalMessages: Int
    let myMessages: Int
    let activeGroups: Int
    let totalGroups: Int
    let activePrivateChats: Int
    let workRatio: Double

    enum CodingKeys: String, CodingKey {
        case totalMessages = "total_messages"
        case myMessages = "my_messages"
        case activeGroups = "active_groups"
        case totalGroups = "total_groups"
        case activePrivateChats = "active_private_chats"
        case workRatio = "work_ratio"
    }
}

// MARK: - Keyword Insight

struct KeywordInsight: Codable {
    let summary: String
    let status: String
    let chats: [String]
    let timeline: [TimelineEvent]
    let stakeholders: [Stakeholder]
    let perspectives: [Perspective]
    let conflicts: [String]
    let myPosition: String
    let risks: [String]
    let recommendation: String

    enum CodingKeys: String, CodingKey {
        case summary, status, chats, timeline, stakeholders
        case perspectives, conflicts
        case myPosition = "my_position"
        case risks, recommendation
    }
}

struct TimelineEvent: Codable {
    let date: String
    let event: String
}

struct Stakeholder: Codable {
    let name: String
    let role: String
    let attitude: String
    let evidence: String
}

struct Perspective: Codable {
    let chat: String
    let angle: String
}

// MARK: - Pure algorithm stats (no AI)

struct ChatStatsData {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let category: WhitelistCategory
    let messageCount: Int
    let myMessageCount: Int
    let participantCount: Int
    let messagesByHour: [Int]
    let messagesByWeekday: [Int]        // 7 buckets: Sun=0..Sat=6
    let typeCounts: [Int: Int]          // baseType → count
    let avgResponseTimeSeconds: Double
    let symmetryRatio: Double
    let trend7d: Double
    let topSenders: [(name: String, count: Int)]
    let silentMembers: [(name: String, usualDaily: Int, today: Int)]
    let ignoredMessages: [(sender: String, text: String, time: Int)]
    let selfInitiated: Bool             // first message in window is from self
    let earliestTs: Int
    let latestTs: Int
    /// Messages inside `InsightRecentWindow`, which is a span — not "this chat
    /// was recently active, so count its whole history".
    var recentMessageCount: Int = 0
}

/// The "近期" the insight overview means: the seven day-buckets ending today —
/// a per-day histogram over the last 7 calendar days, summed.
///
/// Declared once because the window has to agree between the scan that counts
/// it and the overview that divides it: a cutoff computed in one place and a
/// `/ 7.0` written in another is how a metric silently stops being about the
/// last seven days.
///
/// Calendar-aligned (today's start plus six days back), not a rolling 168
/// hours: 「近 7 天」 on the screen reads as days on the calendar, and the
/// 「日均」 derived from the span is a true daily average only when the span is
/// exactly those seven days.
enum InsightRecentWindow {
    static let days = 7

    /// Epoch seconds of the first instant in the oldest bucket — the start of
    /// the local day `days - 1` days ago. A message at or after this instant
    /// sits in one of the seven buckets.
    static func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        return Int(first.timeIntervalSince1970)
    }
}
