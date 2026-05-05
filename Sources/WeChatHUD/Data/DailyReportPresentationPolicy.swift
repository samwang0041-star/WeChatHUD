import Foundation

// MARK: - Presentation Policy

/// Pure logic for grouping, filtering, sorting, and progress-computing
/// daily report data into the command-center view model.
///
/// This type has no UI dependencies and is fully testable.
enum DailyReportPresentationPolicy {

    // MARK: - Grouped View Model

    struct CommandCenterViewModel: Sendable {
        let progress: DailyReportProgressMetrics
        let urgentActions: [DailyReportAction]
        let activeActions: [DailyReportAction]
        let activeToday: [DailyReportAction]
        let activeThisWeek: [DailyReportAction]
        let activeLater: [DailyReportAction]
        let completedActions: [DailyReportAction]
        let highlights: [DailyReportHighlight]
        let activeRisks: [DailyReportRisk]
        let dismissedRisks: [DailyReportRisk]
        let narrative: String?
        let tomorrowFocus: String?
        let wechatDraft: String?
        let isAIEnhanced: Bool
        let date: Date
    }

    // MARK: - Build

    static func buildViewModel(
        from report: DailyReport,
        commandStates: [DailyReportCommandState] = []
    ) -> CommandCenterViewModel {
        let stateMap = Dictionary(
            commandStates.map { ($0.itemID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )

        // Partition actions by state
        var urgent: [DailyReportAction] = []
        var active: [DailyReportAction] = []
        var completed: [DailyReportAction] = []

        for action in report.actions {
            let state = stateMap[action.id]
            let isCompleted = state == .completed
            let isSnoozed = state == .snoozed

            if isCompleted {
                completed.append(action)
            } else if isSnoozed {
                // Snoozed items are hidden from active but not shown as completed
                continue
            } else if action.urgency == .critical || action.urgency == .high {
                urgent.append(action)
            } else {
                active.append(action)
            }
        }

        // Sort: urgent by urgency ascending, then by deadline
        urgent.sort { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency < rhs.urgency }
            guard let l = lhs.deadline, let r = rhs.deadline else { return false }
            return l < r
        }
        active.sort { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency < rhs.urgency }
            guard let l = lhs.deadline, let r = rhs.deadline else { return false }
            return l < r
        }

        // Partition `active` into deadline buckets.
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now)) ?? now

        var bucketToday: [DailyReportAction] = []
        var bucketWeek: [DailyReportAction] = []
        var bucketLater: [DailyReportAction] = []
        for a in active {
            guard let d = a.deadline else { bucketLater.append(a); continue }
            if d <= endOfToday { bucketToday.append(a) }
            else if d <= endOfWeek { bucketWeek.append(a) }
            else { bucketLater.append(a) }
        }

        completed.sort { lhs, rhs in
            guard let l = lhs.completedAt, let r = rhs.completedAt else { return false }
            return l > r // newest first
        }

        // Partition risks
        var activeRisks: [DailyReportRisk] = []
        var dismissedRisks: [DailyReportRisk] = []

        for risk in report.risks {
            if stateMap[risk.id] == .dismissed {
                dismissedRisks.append(risk)
            } else {
                activeRisks.append(risk)
            }
        }
        activeRisks.sort { $0.severity < $1.severity }

        // Progress metrics
        let total = report.actions.count
        let done = completed.count
        let activeCount = urgent.count + active.count
        let overdue = report.actions.filter {
            guard let d = $0.deadline else { return false }
            return d < Date() && stateMap[$0.id] != .completed
        }.count
        let urgentCount = urgent.count

        let progress = DailyReportProgressMetrics(
            completedCount: done,
            activeCount: activeCount,
            totalCount: total,
            overdueCount: overdue,
            urgentCount: urgentCount
        )

        return CommandCenterViewModel(
            progress: progress,
            urgentActions: urgent,
            activeActions: active,
            activeToday: bucketToday,
            activeThisWeek: bucketWeek,
            activeLater: bucketLater,
            completedActions: completed,
            highlights: report.highlights,
            activeRisks: activeRisks,
            dismissedRisks: dismissedRisks,
            narrative: report.narrative,
            tomorrowFocus: report.tomorrowFocus,
            wechatDraft: report.wechatDraft,
            isAIEnhanced: report.status == .aiEnhanced,
            date: report.date
        )
    }

    // MARK: - Markdown Export

    static func markdown(for report: DailyReport, viewModel: CommandCenterViewModel) -> String {
        let dateStr = report.date.dailyReportDateKey
        var lines: [String] = []

        lines.append("# 日报 · \(dateStr)")
        lines.append("")

        // Progress
        let p = viewModel.progress
        lines.append("## 今日进度")
        lines.append("- 完成: \(p.completedCount)/\(p.totalCount)")
        lines.append("- 待处理: \(p.activeCount)")
        if p.overdueCount > 0 {
            lines.append("- 超期: \(p.overdueCount)")
        }
        lines.append("")

        // Urgent
        if !viewModel.urgentActions.isEmpty {
            lines.append("## 🔴 紧急待处理")
            for action in viewModel.urgentActions {
                lines.append("- [ ] \(action.content) (\(action.sourceChatName))")
            }
            lines.append("")
        }

        // Active
        if !viewModel.activeActions.isEmpty {
            lines.append("## 📋 待处理")
            for action in viewModel.activeActions {
                lines.append("- [ ] \(action.content) (\(action.sourceChatName))")
            }
            lines.append("")
        }

        // Completed
        if !viewModel.completedActions.isEmpty {
            lines.append("## ✅ 已完成")
            for action in viewModel.completedActions {
                lines.append("- [x] \(action.content) (\(action.sourceChatName))")
            }
            lines.append("")
        }

        // Highlights
        if !viewModel.highlights.isEmpty {
            lines.append("## 📌 今日高亮")
            for h in viewModel.highlights {
                lines.append("- [\(h.category.label)] \(h.sourceChatName): \(h.summary)")
            }
            lines.append("")
        }

        // Risks
        if !viewModel.activeRisks.isEmpty {
            lines.append("## ⚠️ 风险与异常")
            for r in viewModel.activeRisks {
                lines.append("- \(r.description)")
            }
            lines.append("")
        }

        // AI Insight
        if let narrative = viewModel.narrative, !narrative.isEmpty {
            lines.append("## 💡 AI 洞察")
            lines.append(narrative)
            lines.append("")
        }
        if let tomorrow = viewModel.tomorrowFocus, !tomorrow.isEmpty {
            lines.append("**明日优先:** \(tomorrow)")
            lines.append("")
        }

        // Draft
        if let draft = viewModel.wechatDraft, !draft.isEmpty {
            lines.append("## 📋 微信日报草稿")
            lines.append("```")
            lines.append(draft)
            lines.append("```")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Helpers

extension HighlightCategory {
    var label: String {
        switch self {
        case .decision:   return "决策"
        case .progress:   return "进展"
        case .discussion: return "讨论"
        case .risk:       return "风险"
        }
    }
}
