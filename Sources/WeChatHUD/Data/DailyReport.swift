import Foundation

// MARK: - Daily Report Data Model

struct DailyReport: Sendable {
    let date: Date
    let dateRange: (start: Date, end: Date)
    let generatedAt: Date

    let metrics: DailyReportMetrics
    let highlights: [DailyReportHighlight]
    let actions: [DailyReportAction]
    let risks: [DailyReportRisk]
    let pendingAsks: [PendingAsk]
    let retrospectiveRunID: Int?
    let status: DailyReportStatus
    let statusMessage: String?
    let aiErrorMessage: String?

    /// AI-generated fields (populated by AIDailyReportGenerator).
    var narrative: String?
    var tomorrowFocus: String?
    var wechatDraft: String?

    init(
        date: Date,
        dateRange: (start: Date, end: Date),
        generatedAt: Date,
        metrics: DailyReportMetrics,
        highlights: [DailyReportHighlight],
        actions: [DailyReportAction],
        risks: [DailyReportRisk],
        pendingAsks: [PendingAsk],
        retrospectiveRunID: Int? = nil,
        status: DailyReportStatus = .localOnly,
        statusMessage: String? = nil,
        aiErrorMessage: String? = nil,
        narrative: String?,
        tomorrowFocus: String?,
        wechatDraft: String?
    ) {
        self.date = date
        self.dateRange = dateRange
        self.generatedAt = generatedAt
        self.metrics = metrics
        self.highlights = highlights
        self.actions = actions
        self.risks = risks
        self.pendingAsks = pendingAsks
        self.retrospectiveRunID = retrospectiveRunID
        self.status = status
        self.statusMessage = statusMessage
        self.aiErrorMessage = aiErrorMessage
        self.narrative = narrative
        self.tomorrowFocus = tomorrowFocus
        self.wechatDraft = wechatDraft
    }
}

enum DailyReportStatus: String, Sendable {
    case localOnly
    case aiEnhanced
    case aiUnavailable
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
struct DailyReportHighlight: Identifiable, Sendable {
    let id: String
    let summary: String
    let category: HighlightCategory
    let sourceChatName: String
    let sourceChatUsername: String
    let date: Date
    let confidence: Double
    let quotedSnippet: String?
    let involved: [String]

    init(
        id: String? = nil,
        summary: String,
        category: HighlightCategory,
        sourceChatName: String,
        sourceChatUsername: String,
        date: Date,
        confidence: Double,
        quotedSnippet: String? = nil,
        involved: [String] = []
    ) {
        self.id = id ?? "\(sourceChatUsername)-\(summary.hashValue)"
        self.summary = summary
        self.category = category
        self.sourceChatName = sourceChatName
        self.sourceChatUsername = sourceChatUsername
        self.date = date
        self.confidence = confidence
        self.quotedSnippet = quotedSnippet
        self.involved = involved
    }
}

// MARK: - Action

/// A unified action item drawn from todos, commitments, or reply debt.
enum DailyReportActionType: String, Sendable {
    case todo, commitment, replyDebt, ask
}

struct DailyReportAction: Identifiable, Sendable {
    let id: String
    let content: String
    let type: DailyReportActionType
    let urgency: ActionUrgency
    let deadline: Date?
    let sourceChatName: String
    let sourceChatUsername: String
    let relatedID: String
    let completedAt: Date?

    init(
        id: String? = nil,
        content: String,
        type: DailyReportActionType,
        urgency: ActionUrgency,
        deadline: Date? = nil,
        sourceChatName: String,
        sourceChatUsername: String,
        relatedID: String,
        completedAt: Date? = nil
    ) {
        self.id = id ?? "\(type.rawValue)-\(relatedID)"
        self.content = content
        self.type = type
        self.urgency = urgency
        self.deadline = deadline
        self.sourceChatName = sourceChatName
        self.sourceChatUsername = sourceChatUsername
        self.relatedID = relatedID
        self.completedAt = completedAt
    }
}

enum ActionUrgency: Int, Sendable, Comparable {
    case critical = 0
    case high = 1
    case medium = 2
    case low = 3

    static func < (lhs: ActionUrgency, rhs: ActionUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Risk

struct DailyReportRisk: Identifiable, Sendable {
    let id: String
    let type: RiskType
    let description: String
    let severity: RiskSeverity
    let sourceChatName: String?
    let sourceChatUsername: String?
    let dismissedAt: Date?

    init(
        id: String? = nil,
        type: RiskType,
        description: String,
        severity: RiskSeverity,
        sourceChatName: String? = nil,
        sourceChatUsername: String? = nil,
        dismissedAt: Date? = nil
    ) {
        self.id = id ?? "\(type.rawValue)-\(description.hashValue)"
        self.type = type
        self.description = description
        self.severity = severity
        self.sourceChatName = sourceChatName
        self.sourceChatUsername = sourceChatUsername
        self.dismissedAt = dismissedAt
    }
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

extension DailyReportAction: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DailyReportAction, rhs: DailyReportAction) -> Bool {
        lhs.id == rhs.id
    }
}

extension DailyReportHighlight: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DailyReportHighlight, rhs: DailyReportHighlight) -> Bool {
        lhs.id == rhs.id
    }
}

extension DailyReportRisk: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DailyReportRisk, rhs: DailyReportRisk) -> Bool {
        lhs.id == rhs.id
    }
}
