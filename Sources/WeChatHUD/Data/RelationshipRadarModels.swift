import Foundation

/// One calendar day's *facts* for a chat. Fed by 单聊分析; never stores
/// attitudes / tone_changes / mood_shift — those belong to 关系雷达.
struct DailyInsightPoint: Codable, Equatable {
    var chatUsername: String
    var day: String
    var headline: String
    var topics: [String]
    var decisions: [String]
    var waitingCount: Int
    var overallMood: String
    var messageCount: Int
    var myMessageCount: Int
    var insight: String
}

struct RadarToneChange: Codable, Equatable {
    var from: String
    var to: String
    var aroundDay: String
}

/// Cross-day / cross-week trend for one conversation. Independent of
/// single-day ChatInsightResult.
struct RelationshipRadarSnapshot: Codable, Equatable {
    var chatUsername: String
    var generatedAt: Date
    var windowDays: Int
    var attitudeTrend: String
    var toneChanges: [RadarToneChange]
    var moodShift: String?
    var silenceDays: Int
    var relationshipTrend: String
    var darkSignals: [String]
    var summary: String
    var evidenceHashes: [String]

    /// Redacted one-liner safe to send to a briefing model.
    var briefingLine: String {
        let silence = silenceDays > 0 ? " 沉默\(silenceDays)天" : ""
        return "[\(chatUsername)] \(relationshipTrend)/\(attitudeTrend)\(silence)：\(summary)"
    }
}

enum RelationshipRadarKind {
    static let attitudeWarming = "warming"
    static let attitudeCooling = "cooling"
    static let attitudeMixed = "mixed"
    static let attitudeStable = "stable"
    static let attitudeUnknown = "unknown"
    static let trendImproving = "improving"
    static let trendDeteriorating = "deteriorating"
    static let trendStable = "stable"
}
