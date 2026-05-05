import Foundation

// MARK: - Daily Report Data Model

/// A unified daily report that aggregates data from all available sources:
/// retrospective highlights, todos, pending asks, commitments, reply debt,
/// and recalled messages. Produced by `DailyReportBuilder`; consumed by
/// `AIDailyReportGenerator` for AI enrichment and by `DailyReportTabView`
/// for display.
struct DailyReport: Sendable {
    let date: Date
    let dateRange: (start: Date, end: Date)
    let generatedAt: Date

    let metrics: DailyReportMetrics
    let highlights: [DailyReportHighlight]
    let actions: [DailyReportAction]
    let risks: [DailyReportRisk]
    let pendingAsks: [PendingAsk]

    /// AI-generated fields (populated by AIDailyReportGenerator).
    var narrative: String?
    var tomorrowFocus: String?
    var wechatDraft: String?
}

// MARK: - Metrics

struct DailyReportMetrics: Sendable {
    let unreadMessageCount: Int
    let pendingTodoCount: Int
    let pendingAskCount: Int
    let pendingCommitmentCount: Int
    let overdueCommitmentCount: Int
    let replyDebtCount: Int
    let recalledMessageCount: Int
    let highlightCount: Int
    let analyzedChatCount: Int
}

// MARK: - Highlight

/// A highlight surfaced from the retrospective pipeline, enriched for
/// daily-report display.
struct DailyReportHighlight: Sendable {
    let summary: String
    let category: HighlightCategory
    let sourceChatName: String
    let sourceChatUsername: String
    let date: Date
    let confidence: Double
    let quotedSnippet: String?
    let involved: [String]
}

// MARK: - Action

/// A unified action item drawn from todos, commitments, or reply debt.
enum DailyReportActionType: String, Sendable {
    case todo, commitment, replyDebt, ask
}

struct DailyReportAction: Sendable {
    let content: String
    let type: DailyReportActionType
    let urgency: ActionUrgency
    let deadline: Date?
    let sourceChatName: String
    let sourceChatUsername: String
    let relatedID: String // todoID, commitment msgUID, or chatUsername
}

enum ActionUrgency: Int, Sendable, Comparable {
    case critical = 0   // overdue or red-banner
    case high = 1       // due today
    case medium = 2     // due within 3 days
    case low = 3        // no deadline or distant

    static func < (lhs: ActionUrgency, rhs: ActionUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Risk

struct DailyReportRisk: Sendable {
    let type: RiskType
    let description: String
    let severity: RiskSeverity
    let sourceChatName: String?
    let sourceChatUsername: String?
}

enum RiskType: String, Sendable {
    case overdueCommitment, overdueTodo, recalledMessage, uncertainHighlight, failedAnalysis
}

enum RiskSeverity: Int, Sendable, Comparable {
    case high = 0
    case medium = 1
    case low = 2

    static func < (lhs: RiskSeverity, rhs: RiskSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
