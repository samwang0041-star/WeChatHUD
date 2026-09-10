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
        let historical = !isToday
        let dateRange = (start: startOfDay, end: endOfRange)

        // 1. Retrospective data. Only use a run whose source range overlaps
        // today; old runs must not be presented as today's highlights.
        let targetRun = store.latestCompletedRun(overlapping: startOfDay, end: endOfRange)
        let runHighlights: [ReviewHighlight] = targetRun
            .map { store.highlights(for: $0.id).filter { $0.date >= startOfDay && $0.date < endOfRange } } ?? []
        let runTodos: [ReviewTodo] = targetRun
            .map { store.todos(for: $0.id, statuses: historical ? nil : [.pending])
                .filter { !historical || ($0.createdAt >= startOfDay && $0.createdAt < endOfRange) } } ?? []

        let pendingAsks = store.loadPendingAsks(
            status: historical ? nil : .pending,
            relevantSince: historical ? nil : DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays, now: now)
        )
            .filter { ask in
                if historical {
                    return ask.createdAt >= startOfDay && ask.createdAt < endOfRange
                }
                // Same 14-day live window as 待办. "还剩什么" is open work,
                // not only asks created this calendar day.
                return DiscussionLiveWindow.contains(
                    ask,
                    cutoff: DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays, now: now)
                )
            }
        let handledAsks = historical ? [] : store.loadPendingAsks(status: .done)
            .filter { $0.updatedAt >= startOfDay && $0.updatedAt < endOfRange }

        let liveDiscussions = historical ? [] : store.loadDiscussionItems(
            status: .pending,
            relevantSince: DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays, now: now)
        ).filter { $0.kind != .info && $0.owner == .mine }

        // 3. Commitments
        let allCommitments = store.loadCommitments()
        let scopedCommitments = allCommitments.filter {
            historical
                ? ($0.createdAt >= startOfDay && $0.createdAt < endOfRange)
                : $0.createdAt < endOfRange
        }
        let pendingCommitments = historical ? [] : scopedCommitments.filter { $0.status == .pending }
        let overdueCommitments = historical ? [] : scopedCommitments.filter { $0.status == .overdue }

        // 4. Recalled messages (today)
        let todayRecalled = store.loadRecalledMessages(since: Int(startOfDay.timeIntervalSince1970), limit: 50)
            .filter { $0.recalledAt >= Int(startOfDay.timeIntervalSince1970) && $0.recalledAt < Int(endOfRange.timeIntervalSince1970) }

        // 5. Build metrics
        let metrics = DailyReportMetrics(
            unreadMessageCount: historical ? 0 : stats.unreadCount,
            pendingTodoCount: historical ? 0 : runTodos.count + liveDiscussions.count,
            pendingAskCount: historical ? 0 : pendingAsks.filter { ask in
                !liveDiscussions.contains { $0.anchorMsgUID == ask.msgUID }
            }.count,
            pendingCommitmentCount: pendingCommitments.count,
            overdueCommitmentCount: overdueCommitments.count,
            replyDebtCount: historical ? 0 : replyDebtItems.filter { $0.timestamp < endOfRange }.count,
            recalledMessageCount: todayRecalled.count,
            highlightCount: runHighlights.count
                + (historical ? scopedCommitments.count + runTodos.count + pendingAsks.count : 0),
            analyzedChatCount: targetRun?.progressChatCount ?? 0
        )

        // 6. Build highlights (from retrospective)
        var highlights = runHighlights.map { h in
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
        if historical {
            highlights += scopedCommitments.map { c in
                DailyReportHighlight(summary: "当天记录的承诺：\(c.content)", category: .progress,
                                     sourceChatName: c.chatName, sourceChatUsername: c.chatUsername,
                                     date: c.createdAt, confidence: c.confidence, quotedSnippet: c.sourceText)
            }
            highlights += runTodos.map { todo in
                DailyReportHighlight(summary: "当天记录的待办：\(todo.content)", category: .progress,
                                     sourceChatName: todo.sourceChatName, sourceChatUsername: todo.sourceChatUsername,
                                     date: todo.createdAt, confidence: todo.confidence)
            }
            highlights += pendingAsks.map { ask in
                DailyReportHighlight(summary: "当天记录的请求：\(ask.summary)", category: .discussion,
                                     sourceChatName: ask.chatName, sourceChatUsername: ask.chatUsername,
                                     date: ask.createdAt, confidence: ask.confidence, quotedSnippet: ask.rawText)
            }
        }

        // 7. Build unified actions
        var actions: [DailyReportAction] = []

        // Todos from retrospective
        for todo in historical ? [] : runTodos {
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

        let discussionAnchors = Set(liveDiscussions.map(\.anchorMsgUID))
        for item in liveDiscussions {
            actions.append(DailyReportAction(
                content: item.content,
                type: .todo,
                urgency: urgencyFor(deadline: item.dueAt),
                deadline: item.dueAt,
                sourceChatName: item.chatName,
                sourceChatUsername: item.chatUsername,
                relatedID: "discussion-\(item.id)"
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
        for debt in historical ? [] : replyDebtItems where debt.timestamp < endOfRange {
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
        for ask in historical ? [] : pendingAsks where !discussionAnchors.contains(ask.msgUID) {
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

        for todo in historical ? [] : runTodos where todo.deadline != nil && todo.deadline! < endOfRange {
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
            reportDate: startOfDay,
            historical: historical
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
        reportDate: Date,
        historical: Bool
    ) -> (narrative: String, tomorrowFocus: String, wechatDraft: String, statusMessage: String) {
        let dateKey = reportDate.dailyReportDateKey
        if historical {
            let recordedCount = highlights.count
            let recordedText = recordedCount == 0 ? "当天可追溯来源中暂无记录。" : "当天可追溯来源记录 \(recordedCount) 条。"
            let first = highlights.first?.summary
            let narrative = first.map { "\(dateKey) 的历史记录：\(recordedText) 重点：\($0)" } ?? "\(dateKey) 的历史记录：\(recordedText)"
            let review = first.map { "复核记录：\($0)" } ?? "复核记录：暂无明确事项。"
            return (
                narrative,
                "历史记录仅反映当日来源，不代表当前待办状态。",
                "\(dateKey) 工作小结\n\(recordedText)\n\(review)\n当前未读、待回复和待处理状态没有历史快照，未作当日结论。",
                "历史来源记录：未将当前未读、待回复或状态倒推为当日快照。"
            )
        }
        let actionableCount = metrics.pendingTodoCount + metrics.pendingAskCount + metrics.pendingCommitmentCount + metrics.replyDebtCount
        let hasSignals = metrics.unreadMessageCount > 0
            || actionableCount > 0
            || metrics.overdueCommitmentCount > 0
            || metrics.recalledMessageCount > 0
            || metrics.highlightCount > 0
            || handledAskCount > 0

        if !hasSignals {
            guard stats.lastSyncAt != nil else {
                return (
                    "尚无成功同步记录，暂不能判断今天是否有需要处理的微信事项。",
                    "连接微信并完成一次成功同步，再查看今天的待回复、请求和承诺。",
                    "\(dateKey) 工作小结\n今日微信数据尚未验证，暂无足够来源生成工作小结。\n需要支持：请先连接微信并完成一次成功同步。",
                    "未验证：尚无成功同步记录，未对今日事项下结论。"
                )
            }
            return (
                "今天已成功同步的数据中，暂未发现需要处理的微信事项。",
                "明天先做一次微信巡检，确认是否有新的待回复、请求或承诺。",
                "\(dateKey) 工作小结\n今日微信侧暂无待处理事项（基于已成功同步的数据）。明日计划：继续巡检重点对话，及时处理新增请求和承诺。\n需要支持：暂无。",
                "规则整理：基于已成功同步的本地数据，暂无待处理事项。"
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

        let recordLine = facts.isEmpty
            ? "本地记录：当前没有可汇总的本地信号。"
            : "本地记录：\(facts.joined(separator: "；"))。"
        let reviewLine: String
        if let firstRisk {
            reviewLine = "待核对：\(firstRisk)"
        } else if let firstAction {
            reviewLine = "待核对：\(firstAction)"
        } else {
            reviewLine = "待核对：暂无明确事项。"
        }
        let wechatDraft = """
        \(dateKey) 工作小结
        \(recordLine)
        建议核对：\(tomorrowFocus)
        \(reviewLine)
        需要支持：暂无（如需协作请人工补充）。
        """

        return (
            narrative,
            tomorrowFocus,
            wechatDraft,
            "规则整理：AI 未完成前先展示可读日报。"
        )
    }

}
