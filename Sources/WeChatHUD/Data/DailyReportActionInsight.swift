import Foundation

/// AI-produced per-action annotation for the daily report.
/// Persisted in `daily_report_action_insights`, keyed by `(dateKey, actionID)`.
struct DailyReportActionInsight: Sendable, Codable, Equatable {
    let dateKey: String
    let actionID: String
    let reason: String        // ≤ 30 字
    let nextStep: String      // ≤ 40 字
    let modelVersion: String  // e.g. "daily_report_action_insights_v1"
    let generatedAt: Date
}
