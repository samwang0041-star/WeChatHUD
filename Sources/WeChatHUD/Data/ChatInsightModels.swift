// Sources/WeChatHUD/Data/ChatInsightModels.swift
import Foundation

// MARK: - Chat Insight Result (per-chat AI output)

struct ChatInsightResult: Codable {
    let headline: String
    let topics: [TopicInsight]
    let decisions: [String]
    let actionItems: [InsightActionItem]
    let mentionsMe: Int
    let waitingForMe: [WaitingItem]
    let myCommitments: [String]
    let needsMyAttention: Bool
    let overallMood: String
    let moodShift: MoodShift?
    let attitudes: [AttitudeSignal]?
    let toneChanges: [ToneChange]?
    let silentMembers: [SilentMember]?
    let recalledNotes: [RecalledNote]?
    let ignoredNotes: [IgnoredNote]?
    let signalNoiseRatio: Double
    let decisionEfficiency: String
    let importanceToMe: ImportanceLevel
    let participants: [ParticipantRole]?
    let relationshipSignal: String?
    let symmetry: Double?
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
        case moodShift = "mood_shift"
        case attitudes
        case toneChanges = "tone_changes"
        case silentMembers = "silent_members"
        case recalledNotes = "recalled_notes"
        case ignoredNotes = "ignored_notes"
        case signalNoiseRatio = "signal_noise_ratio"
        case decisionEfficiency = "decision_efficiency"
        case importanceToMe = "importance_to_me"
        case participants
        case relationshipSignal = "relationship_signal"
        case symmetry
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
    let attitudes: [String: String]?
    let crossChats: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case messageCount = "message_count"
        case participantCount = "participant_count"
        case summary, status
        case myInvolvement = "my_involvement"
        case attitudes
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
    let waitingHours: Double

    enum CodingKeys: String, CodingKey {
        case source, what
        case waitingHours = "waiting_hours"
    }
}

struct MoodShift: Codable {
    let from: String
    let to: String
    let trigger: String
    let time: String
}

struct AttitudeSignal: Codable {
    let person: String
    let topic: String
    let attitude: String
    let evidence: String
}

struct ToneChange: Codable {
    let person: String
    let change: String
    let interpretation: String
}

struct SilentMember: Codable {
    let name: String
    let usualDailyMessages: Int
    let todayMessages: Int
    let activeElsewhere: Bool
    let interpretation: String

    enum CodingKeys: String, CodingKey {
        case name
        case usualDailyMessages = "usual_daily_messages"
        case todayMessages = "today_messages"
        case activeElsewhere = "active_elsewhere"
        case interpretation
    }
}

struct RecalledNote: Codable {
    let person: String
    let originalContent: String?
    let context: String
    let replacement: String?
    let interpretation: String

    enum CodingKeys: String, CodingKey {
        case person
        case originalContent = "original_content"
        case context, replacement, interpretation
    }
}

struct IgnoredNote: Codable {
    let person: String
    let content: String
    let usualResponseRate: String
    let interpretation: String

    enum CodingKeys: String, CodingKey {
        case person, content
        case usualResponseRate = "usual_response_rate"
        case interpretation
    }
}

struct ImportanceLevel: Codable {
    let level: String
    let reason: String
}

struct ParticipantRole: Codable {
    let name: String
    let messageCount: Int
    let role: String
    let doing: String
    let attitudeToward: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case messageCount = "message_count"
        case role, doing
        case attitudeToward = "attitude_toward"
    }
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

struct ActionRequiredItem: Codable {
    let source: String
    let what: String
    let waitingHours: Double
    let urgency: String

    enum CodingKeys: String, CodingKey {
        case source, what
        case waitingHours = "waiting_hours"
        case urgency
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
    let toneChanges: [ToneChange]
    let silences: [SilentMember]
    let recalls: [RecalledNote]
    let ignored: [IgnoredNote]
    let headline: String?

    enum CodingKeys: String, CodingKey {
        case toneChanges = "tone_changes"
        case silences, recalls, ignored, headline
    }
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
    let avgResponseTimeSeconds: Double
    let symmetryRatio: Double
    let trend7d: Double
    let topSenders: [(name: String, count: Int)]
    let silentMembers: [(name: String, usualDaily: Int, today: Int)]
    let ignoredMessages: [(sender: String, text: String, time: Int)]
}
