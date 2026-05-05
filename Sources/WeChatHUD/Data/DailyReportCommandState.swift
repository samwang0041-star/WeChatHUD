import Foundation

// MARK: - Command State

/// Tracks user actions taken on daily report items: completion, dismissal,
/// or snoozing. Persisted per date so historical reports retain their state.
enum DailyReportCommandStateValue: String, Codable, Sendable {
    case completed
    case dismissed
    case snoozed
}

struct DailyReportCommandState: Sendable {
    let dateKey: String
    let itemID: String
    let state: DailyReportCommandStateValue
    let completedAt: Date?
    let dismissedAt: Date?
    let snoozedUntil: Date?
    let updatedAt: Date

    init(
        dateKey: String,
        itemID: String,
        state: DailyReportCommandStateValue,
        completedAt: Date? = nil,
        dismissedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.dateKey = dateKey
        self.itemID = itemID
        self.state = state
        self.completedAt = completedAt
        self.dismissedAt = dismissedAt
        self.snoozedUntil = snoozedUntil
        self.updatedAt = updatedAt
    }
}

// MARK: - Snapshot

/// A lightweight Codable snapshot of a daily report for history navigation.
/// Stored as JSON in SQLite so the full `DailyReport` shape doesn't need
/// to be `Codable`.
struct DailyReportSnapshot: Codable, Sendable {
    let dateKey: String
    let dateStart: Date
    let dateEnd: Date
    let generatedAt: Date
    let metrics: DailyReportMetricsSnapshot
    let highlightCount: Int
    let actionCount: Int
    let riskCount: Int
    let hasAIEnhancement: Bool
    let narrativePreview: String?
    let wechatDraftPreview: String?

    struct DailyReportMetricsSnapshot: Codable, Sendable {
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
}

// MARK: - Progress Metrics

/// Computed progress indicators for the command center header.
struct DailyReportProgressMetrics: Sendable {
    let completedCount: Int
    let activeCount: Int
    let totalCount: Int
    let overdueCount: Int
    let urgentCount: Int

    var completionRatio: Double {
        totalCount == 0 ? 1.0 : Double(completedCount) / Double(totalCount)
    }

    var isQuietDay: Bool {
        totalCount == 0 && overdueCount == 0
    }
}

// MARK: - Date Key Helper

extension Date {
    /// "yyyy-MM-dd" string used as the persistent date key for daily report state.
    var dailyReportDateKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: self)
    }
}
