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

    func build(for date: Date = Date(), now: Date = Date()) -> DailyReport {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let endOfRange = isToday ? now : calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let dateRange = (start: startOfDay, end: endOfRange)

        // 1. Retrospective data. Only use a run whose source range overlaps
        // today; old runs must not be presented as today's highlights.
        let latestRun = store.latestCompletedRun()
        let targetRun = latestRun.flatMap { run in
            run.rangeEnd >= startOfDay && run.rangeStart <= endOfRange ? run : nil
        }
        let runHighlights: [ReviewHighlight] = targetRun
            .map { store.highlights(for: $0.id).filter { $0.date >= startOfDay && $0.date <= endOfRange } } ?? []
        let runTodos: [ReviewTodo] = targetRun.map { store.todos(for: $0.id, statuses: [.pending]) } ?? []

        let pendingAsks = store.loadPendingAsks(status: .pending)
            .filter { $0.createdAt >= startOfDay && $0.createdAt <= endOfRange }
        let handledAsks = store.loadPendingAsks(status: .done)
            .filter { $0.updatedAt >= startOfDay && $0.updatedAt <= endOfRange }

        // 3. Commitments
        let allCommitments = store.loadCommitments()
        let pendingCommitments = allCommitments.filter { $0.status == .pending }
        let overdueCommitments = allCommitments.filter { $0.status == .overdue }

        // 4. Recalled messages (today)
        let todayRecalled = store.loadRecalledMessages(since: Int(startOfDay.timeIntervalSince1970), limit: 50)
            .filter { $0.recalledAt >= Int(startOfDay.timeIntervalSince1970) && $0.recalledAt <= Int(endOfRange.timeIntervalSince1970) }

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
            analyzedChatCount: targetRun?.progressChatCount ?? 0
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

        for todo in runTodos where todo.deadline != nil && todo.deadline! < endOfRange {
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

        let localText = localFallbackText(
            metrics: metrics,
            highlights: highlights,
            actions: actions,
            risks: risks,
            handledAskCount: handledAsks.count,
            now: endOfRange
        )

        return DailyReport(
            date: date,
            dateRange: dateRange,
            generatedAt: now,
            metrics: metrics,
            highlights: highlights,
            actions: actions,
            risks: risks,
            pendingAsks: pendingAsks + handledAsks,
            retrospectiveRunID: targetRun?.id,
            status: .localOnly,
            statusMessage: localText.statusMessage,
            aiErrorMessage: nil,
            narrative: localText.narrative,
            tomorrowFocus: localText.tomorrowFocus,
            wechatDraft: localText.wechatDraft
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

    private func localFallbackText(
        metrics: DailyReportMetrics,
        highlights: [DailyReportHighlight],
        actions: [DailyReportAction],
        risks: [DailyReportRisk],
        handledAskCount: Int,
        now: Date
    ) -> (narrative: String, tomorrowFocus: String, wechatDraft: String, statusMessage: String) {
        let dateKey = now.dailyReportDateKey
        let actionableCount = metrics.pendingTodoCount + metrics.pendingAskCount + metrics.pendingCommitmentCount + metrics.replyDebtCount
        let hasSignals = metrics.unreadMessageCount > 0
            || actionableCount > 0
            || metrics.overdueCommitmentCount > 0
            || metrics.recalledMessageCount > 0
            || metrics.highlightCount > 0
            || handledAskCount > 0

        if !hasSignals {
            return (
                "今天暂无需要处理的微信事项；未读、待回复、承诺和复盘高亮都为空。",
                "明天先做一次微信巡检，确认是否有新的待回复、请求或承诺。",
                "\(now.dailyReportDateKey) 工作小结\n今日微信侧暂无待处理事项，已保持关注列表清空。明日计划：继续巡检重点对话，及时处理新增请求和承诺。\n需要支持：暂无。",
                "本地生成：暂无 AI 增强，当前没有可汇总的今日事项。"
            )
        }

        var facts: [String] = []
        if metrics.unreadMessageCount > 0 { facts.append("未读 \(metrics.unreadMessageCount) 条") }
        if metrics.replyDebtCount > 0 { facts.append("待回复 \(metrics.replyDebtCount) 项") }
        if metrics.pendingAskCount > 0 { facts.append("待处理请求 \(metrics.pendingAskCount) 项") }
        if metrics.pendingTodoCount > 0 { facts.append("复盘待办 \(metrics.pendingTodoCount) 项") }
        if metrics.pendingCommitmentCount > 0 { facts.append("进行中承诺 \(metrics.pendingCommitmentCount) 项") }
        if metrics.overdueCommitmentCount > 0 { facts.append("超期承诺 \(metrics.overdueCommitmentCount) 项") }
        if metrics.highlightCount > 0 { facts.append("今日高亮 \(metrics.highlightCount) 条") }
        if handledAskCount > 0 { facts.append("已处理请求 \(handledAskCount) 项") }

        let firstAction = actions.first?.content
        let firstRisk = risks.first?.description
        var narrative = "今天本地统计显示：" + facts.joined(separator: "，") + "。"
        if let firstRisk {
            narrative += " 最高风险：\(firstRisk)。"
        } else if let firstAction {
            narrative += " 优先处理：\(firstAction)。"
        } else if let firstHighlight = highlights.first?.summary {
            narrative += " 主要进展：\(firstHighlight)。"
        }

        let tomorrowFocus: String
        if let critical = actions.first(where: { $0.urgency == .critical }) {
            tomorrowFocus = "先处理紧急事项：\(critical.content)。"
        } else if let next = actions.first {
            tomorrowFocus = "先推进：\(next.content)。"
        } else if metrics.unreadMessageCount > 0 {
            tomorrowFocus = "先清理未读消息，避免遗漏新的请求和承诺。"
        } else {
            tomorrowFocus = "复查今日高亮，补齐需要沉淀的行动项。"
        }

        let completedLine = handledAskCount > 0 ? "处理微信请求 \(handledAskCount) 项" : "完成微信消息巡检与重点事项整理"
        let followLine = firstAction ?? firstRisk ?? "暂无明确阻塞，保持重点对话巡检"
        let wechatDraft = """
        \(dateKey) 工作小结
        今日完成：1) \(completedLine)；2) 汇总\(facts.joined(separator: "、"))。
        明日计划：\(tomorrowFocus)
        需要支持：\(followLine)
        """

        return (
            narrative,
            tomorrowFocus,
            wechatDraft,
            "本地生成：AI 未完成前先展示可读日报。"
        )
    }

}
