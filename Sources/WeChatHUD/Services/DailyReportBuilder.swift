import Foundation

/// Builds a unified `DailyReport` by aggregating data from all existing
/// sources: retrospective highlights/todos, pending asks, commitments,
/// reply debt, and recalled messages. Pure data assembly — no AI.
///
/// Designed to be called on the main actor (it reads `@MainActor` state
/// like `replyDebtItems`), but the builder itself is not isolated so it
/// can be used from background contexts when given a captured store.
struct DailyReportBuilder {
    let store: HUDStore
    let replyDebtItems: [ReplyDebtItem]
    let stats: HUDStats

    /// Builds a report for the current day (00:00 to now).
    /// If no retrospective run exists for today, degrades gracefully
    /// to asks + commitments + reply debt only.
    func build() -> DailyReport {
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let dateRange = (start: startOfDay, end: now)

        // 1. Retrospective data (latest run, may be from earlier today or before)
        let latestRun = store.latestCompletedRun()
        let runHighlights: [ReviewHighlight] = latestRun.map { store.highlights(for: $0.id) } ?? []
        let runTodos: [ReviewTodo] = latestRun.map { store.todos(for: $0.id, statuses: [.pending]) } ?? []

        // 2. Pending asks (today's scope)
        let pendingAsks = store.loadPendingAsks(status: .pending)
            .filter { $0.createdAt >= startOfDay }
        let handledAsks = store.loadPendingAsks(status: .done)
            .filter { $0.updatedAt >= startOfDay }

        // 3. Commitments
        let allCommitments = store.loadCommitments()
        let pendingCommitments = allCommitments.filter { $0.status == .pending }
        let overdueCommitments = allCommitments.filter { $0.status == .overdue }

        // 4. Recalled messages (today)
        let todayRecalled = store.loadRecalledMessages(since: Int(startOfDay.timeIntervalSince1970), limit: 50)
            .filter { $0.recalledAt >= Int(startOfDay.timeIntervalSince1970) }

        // 5. Build metrics
        let metrics = DailyReportMetrics(
            unreadMessageCount: stats.unreadCount,
            pendingTodoCount: runTodos.count,
            pendingAskCount: pendingAsks.count,
            pendingCommitmentCount: pendingCommitments.count,
            overdueCommitmentCount: overdueCommitments.count,
            replyDebtCount: replyDebtItems.count,
            recalledMessageCount: todayRecalled.count,
            highlightCount: runHighlights.count,
            analyzedChatCount: latestRun?.progressChatCount ?? 0
        )

        // 6. Build highlights (from retrospective)
        let highlights = runHighlights.map { h in
            DailyReportHighlight(
                summary: h.summary,
                category: h.category,
                sourceChatName: h.sourceChatName,
                sourceChatUsername: h.sourceChatUsername,
                date: h.date,
                confidence: h.confidence,
                quotedSnippet: h.quotedSnippet,
                involved: h.involved
            )
        }

        // 7. Build unified actions
        var actions: [DailyReportAction] = []

        // Todos from retrospective
        for todo in runTodos {
            actions.append(DailyReportAction(
                content: todo.content,
                type: .todo,
                urgency: urgencyFor(deadline: todo.deadline),
                deadline: todo.deadline,
                sourceChatName: todo.sourceChatName,
                sourceChatUsername: todo.sourceChatUsername,
                relatedID: "\(todo.id)"
            ))
        }

        // Commitments (pending + overdue)
        for c in pendingCommitments + overdueCommitments {
            actions.append(DailyReportAction(
                content: c.content,
                type: .commitment,
                urgency: urgencyFor(deadline: c.deadlineAt, status: c.status),
                deadline: c.deadlineAt,
                sourceChatName: c.chatName,
                sourceChatUsername: c.chatUsername,
                relatedID: c.msgUID
            ))
        }

        // Reply debt
        for debt in replyDebtItems {
            actions.append(DailyReportAction(
                content: "回复 \(debt.senderName): \(debt.preview.prefix(60))\(debt.preview.count > 60 ? "…" : "")",
                type: .replyDebt,
                urgency: urgencyForReplyDebt(debt),
                deadline: nil,
                sourceChatName: debt.chatName,
                sourceChatUsername: debt.chatUsername,
                relatedID: debt.chatUsername
            ))
        }

        // Pending asks
        for ask in pendingAsks {
            actions.append(DailyReportAction(
                content: ask.summary,
                type: .ask,
                urgency: urgencyFor(deadline: ask.deadlineAt),
                deadline: ask.deadlineAt,
                sourceChatName: ask.chatName,
                sourceChatUsername: ask.chatUsername,
                relatedID: ask.msgUID
            ))
        }

        // Sort by urgency ascending (critical first)
        actions.sort { $0.urgency < $1.urgency }

        // 8. Build risks
        var risks: [DailyReportRisk] = []

        for c in overdueCommitments {
            risks.append(DailyReportRisk(
                type: .overdueCommitment,
                description: "承诺「\(c.content)」已超期",
                severity: .high,
                sourceChatName: c.chatName,
                sourceChatUsername: c.chatUsername
            ))
        }

        for todo in runTodos where todo.deadline != nil && todo.deadline! < now {
            risks.append(DailyReportRisk(
                type: .overdueTodo,
                description: "待办「\(todo.content)」已超期",
                severity: .high,
                sourceChatName: todo.sourceChatName,
                sourceChatUsername: todo.sourceChatUsername
            ))
        }

        for r in todayRecalled where r.aiShouldNotify == true {
            let severity: RiskSeverity = (r.aiNotifyLevel == .strong) ? .high : .medium
            risks.append(DailyReportRisk(
                type: .recalledMessage,
                description: "\(r.senderName) 撤回了一条消息",
                severity: severity,
                sourceChatName: r.chatName,
                sourceChatUsername: r.chatUsername
            ))
        }

        for h in runHighlights where h.flaggedUncertain {
            risks.append(DailyReportRisk(
                type: .uncertainHighlight,
                description: "高亮信息置信度低: \(h.summary.prefix(50))",
                severity: .low,
                sourceChatName: h.sourceChatName,
                sourceChatUsername: h.sourceChatUsername
            ))
        }

        risks.sort { $0.severity < $1.severity }

        return DailyReport(
            date: now,
            dateRange: dateRange,
            generatedAt: now,
            metrics: metrics,
            highlights: highlights,
            actions: actions,
            risks: risks,
            pendingAsks: pendingAsks + handledAsks,
            narrative: nil,
            tomorrowFocus: nil,
            wechatDraft: nil
        )
    }

    // MARK: - Urgency helpers

    private func urgencyFor(deadline: Date?, status: CommitmentStatus? = nil) -> ActionUrgency {
        if let status = status, status == .overdue {
            return .critical
        }
        guard let deadline = deadline else { return .low }
        let now = Date()
        let diff = deadline.timeIntervalSince(now)
        if diff < 0 { return .critical }
        if diff < 86400 { return .high }
        if diff < 3 * 86400 { return .medium }
        return .low
    }

    private func urgencyForReplyDebt(_ debt: ReplyDebtItem) -> ActionUrgency {
        switch debt.priority {
        case .p0: return .critical
        case .p1: return .high
        case .p2: return .medium
        }
    }
}
