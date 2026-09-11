import Foundation

/// Generates AI-enriched narrative, tomorrow focus, and WeChat draft for a
/// daily report. Takes a `DailyReport` produced by `DailyReportBuilder`,
/// formats a context-rich prompt, calls the AI service, and returns the
/// report with `narrative`, `tomorrowFocus`, and `wechatDraft` populated.
///
/// Falls back to the original data-only report if AI fails or returns
/// unparseable output after retry.
actor AIDailyReportGenerator {
    private let aiService: AIService
    private let store: HUDStore
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        aiService: AIService,
        store: HUDStore,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "daily_report_v1"
    ) {
        self.aiService = aiService
        self.store = store
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    // MARK: - Output

    struct AIOutput: Decodable {
        let narrative: String
        let tomorrowFocus: String
        let wechatDraft: String

        enum CodingKeys: String, CodingKey {
            case narrative
            case tomorrowFocus = "tomorrow_focus"
            case wechatDraft = "wechat_draft"
        }
    }

    // MARK: - Generation

    /// Enriches a `DailyReport` with AI-generated fields. If AI fails,
    /// returns the local report with an explicit degraded status.
    func enrich(_ report: DailyReport) async -> DailyReport {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            await audit(report: report, output: "", latencyMs: 0, status: .parseError, error: "prompt load failed: \(error)", model: nil)
            return report.withAIUnavailable("日报 AI prompt 加载失败：\(error.localizedDescription)")
        }

        let userPrompt = formatPrompt(template: template, report: report)

        let first = await call(userPrompt)
        if let parsed = parse(first.text) {
            await audit(report: report, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil, model: first.model)
            return report.withAI(
                narrative: parsed.narrative,
                tomorrowFocus: parsed.tomorrowFocus,
                wechatDraft: parsed.wechatDraft
            )
        }

        if first.text.isEmpty, let err = first.error {
            await audit(report: report, output: "", latencyMs: ms(since: started), status: .httpError, error: err, model: first.model)
            return report.withAIUnavailable("日报 AI 生成失败：\(err)")
        }

        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象，不要任何其他文字。"
        let second = await call(strict)
        if let parsed = parse(second.text) {
            await audit(report: report, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry", model: second.model)
            return report.withAI(
                narrative: parsed.narrative,
                tomorrowFocus: parsed.tomorrowFocus,
                wechatDraft: parsed.wechatDraft
            )
        }

        await audit(report: report, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry", model: second.model)
        return report.withAIUnavailable("日报 AI 输出无法解析，已使用本地日报。")
    }

    // MARK: - Prompt formatting

    /// Formats the prompt template with report data. Caps highlights,
    /// actions, and risks to respect token budgets.
    nonisolated func formatPrompt(template: String, report: DailyReport) -> String {
        let metrics = report.metrics
        let historical = isHistoricalReport(report)
        // Rewrite only the template's instructional prose. Do this before
        // inserting source text so quoted messages containing 今日/明天 remain
        // verbatim.
        let templateForReport: String
        if historical {
            // Historical reports have no current-state snapshot. Use a
            // dedicated instruction block so the ordinary current-day
            // template cannot make the model invent a next-day plan or a
            // manager-facing request for support.
            templateForReport = """
            你是一个专业的历史工作记录汇总助手。只根据所选日期已经保存的微信活动数据，生成一份事实性日报。

            你必须输出单个 JSON 对象，不要包含 markdown 围栏或任何其他文本。

            JSON schema:
            {
              "narrative": "所选日期的核心回顾，2-3 句话，最多 120 字。引用具体对话来源和已记录的活动。",
              "tomorrow_focus": "基于已记录事实的后续复核建议，1 句话，最多 50 字；没有依据时留空。",
              "wechat_draft": "可直接复制的历史工作记录，只陈述所选日期已记录的事实和具体交付物，不写后续计划、需要支持或当前完成状态。"
            }

            ## 所选日期概览
            - 未读消息: {unread_count}
            - 复盘对话数: {analyzed_chat_count}
            - 提取高亮: {highlight_count}
            - 待办事项: {pending_todo_count}
            - 待处理请求: {pending_ask_count}
            - 待履行承诺: {pending_commitment_count}（超期: {overdue_commitment_count}）
            - 回复债务: {reply_debt_count}
            - 撤回消息: {recalled_count}

            ## 所选日期高亮（来自实际对话）
            {highlights}

            ## 所选日期待办与承诺
            {actions}

            ## 所选日期风险与异常
            {risks}

            规则：不得把未知计数、空列表或当前状态解释为没有；不得编造后续计划或完成状态；wechat_draft 必须保留高亮中的具体人名和交付物。
            """
        } else {
            templateForReport = template
        }

        let highlightsText = report.highlights.prefix(8).enumerated().map { (i, h) in
            let snippet = h.quotedSnippet.map { " \"\($0.prefix(40))\($0.count > 40 ? "…" : "")\"" } ?? ""
            return "\(i + 1). [\(h.sourceChatName)] \(h.summary.prefix(60))\(h.summary.count > 60 ? "…" : "")\(snippet)"
        }.joined(separator: "\n")

        let actionsText = report.actions.prefix(12).enumerated().map { (i, a) in
            let deadlineStr = a.deadline.map { " (截止: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            let typeLabel = typeLabel(a.type)
            return "\(i + 1). [\(typeLabel)][\(a.sourceChatName)] \(a.content.prefix(60))\(a.content.count > 60 ? "…" : "")\(deadlineStr)"
        }.joined(separator: "\n")

        let risksText = report.risks.prefix(5).enumerated().map { (i, r) in
            let source = r.sourceChatName.map { " [\($0)]" } ?? ""
            return "\(i + 1).\(source) \(r.description)"
        }.joined(separator: "\n")

        let unread = historical ? "未知（历史报告未保存该项）" : "\(metrics.unreadMessageCount)"
        let pendingTodo = historical ? "未知（历史报告未保存该项）" : "\(metrics.pendingTodoCount)"
        let pendingAsk = historical ? "未知（历史报告未保存该项）" : "\(metrics.pendingAskCount)"
        let pendingCommitment = historical ? "未知（历史报告未保存该项）" : "\(metrics.pendingCommitmentCount)"
        let overdueCommitment = historical ? "未知（历史报告未保存该项）" : "\(metrics.overdueCommitmentCount)"
        let replyDebt = historical ? "未知（历史报告未保存该项）" : "\(metrics.replyDebtCount)"
        // Recalled messages are source-day events, so their count remains
        // factual in a historical report. Current-state counters above do not.
        let recalled = "\(metrics.recalledMessageCount)"
        let emptyHighlights = historical ? "这一天没有已记录的高亮（不代表没有发生对话）。" : "暂无高亮数据"
        let emptyActions = historical ? "历史报告未保存待办的当前状态，不能据此判断无待办。" : "暂无待办"
        let emptyRisks = historical ? "历史报告未保存风险的当前状态，不能据此判断无风险。" : "暂无风险"

        let formatted = templateForReport
            .replacingOccurrences(of: "{report_date}", with: Self.reportDateLine(report.date))
            .replacingOccurrences(of: "{unread_count}", with: unread)
            .replacingOccurrences(of: "{analyzed_chat_count}", with: "\(metrics.analyzedChatCount)")
            .replacingOccurrences(of: "{highlight_count}", with: "\(metrics.highlightCount)")
            .replacingOccurrences(of: "{pending_todo_count}", with: pendingTodo)
            .replacingOccurrences(of: "{pending_ask_count}", with: pendingAsk)
            .replacingOccurrences(of: "{pending_commitment_count}", with: pendingCommitment)
            .replacingOccurrences(of: "{overdue_commitment_count}", with: overdueCommitment)
            .replacingOccurrences(of: "{reply_debt_count}", with: replyDebt)
            .replacingOccurrences(of: "{recalled_count}", with: recalled)
            .replacingOccurrences(of: "{highlights}", with: highlightsText.isEmpty ? emptyHighlights : highlightsText)
            .replacingOccurrences(of: "{actions}", with: actionsText.isEmpty ? emptyActions : actionsText)
            .replacingOccurrences(of: "{risks}", with: risksText.isEmpty ? emptyRisks : risksText)

        guard historical else { return formatted }

        let selectedDate = historicalDateString(report.date)
        // Keep the output schema, but make the historical semantics explicit. The
        // generated-at day is deliberately used as the comparison anchor above;
        // no current wall-clock date is consulted here.
        return formatted
            + "\n\n# 历史日期模式\n"
            + "所选日期：\(selectedDate)（报告生成于另一个日历日）。\n"
            + "只根据所选日期的高亮和已记录事件写作；未保存的未读数、待办数、风险状态和完成状态必须明确写为未知，不能把 0 或空列表解释为没有。\n"
            + "tomorrow_focus 只能给出基于已记录事实的后续复核建议，也可以为空；不得编造后续计划。wechat_draft 只能陈述所选日期已记录的活动，只有当日来源明确记录完成时才能写已完成，不得根据当前状态或空列表推断。"
    }

    /// Uses the same user calendar as the report builder. The comparison is
    /// between the report's two persisted dates, never against wall-clock now.
    nonisolated private func isHistoricalReport(_ report: DailyReport) -> Bool {
        let calendar = Calendar.current
        return !calendar.isDate(report.date, inSameDayAs: report.generatedAt)
    }

    /// The date line handed to the prompt as `{report_date}`.
    ///
    /// The live report template asks for a "日期+工作小结" draft and tells the
    /// model to rank items due "24h 内", but no date was ever substituted — the
    /// model was left to guess what day it was writing about. The weekday is
    /// included because the surrounding data talks in weekday terms.
    nonisolated static func reportDateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    nonisolated private func historicalDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private func typeLabel(_ type: DailyReportActionType) -> String {
        switch type {
        case .todo: return "待办"
        case .commitment: return "承诺"
        case .replyDebt: return "回复"
        case .ask: return "请求"
        }
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "daily:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "日报生成")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是一个工作日汇总助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 90, temperature: 0.2, maxTokens: 1024, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    // internal for testing
    nonisolated func parse(_ raw: String) -> AIOutput? {
        AIJSONExtractor.decodeFirstObject(from: raw, as: AIOutput.self)
    }

    // MARK: - Audit

    private func audit(report: DailyReport, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .retrospector,
            model: model,
            promptVersion: promptVersion,
            inputText: "[daily_report|\(report.dateRange.start.formatted(date: .abbreviated, time: .omitted))|highlights=\(report.highlights.count)|actions=\(report.actions.count)|risks=\(report.risks.count)]",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do {
            try store.writeAIAudit(entry)
        } catch {
            print("[WCHUD] AIDailyReportGenerator: failed to write audit: \(error)")
        }
    }

    // MARK: - Helpers

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - DailyReport extension

extension DailyReport {
    /// Returns a new DailyReport with AI fields populated.
    func withAI(narrative: String, tomorrowFocus: String, wechatDraft: String) -> DailyReport {
        DailyReport(
            date: date,
            dateRange: dateRange,
            generatedAt: generatedAt,
            metrics: metrics,
            highlights: highlights,
            actions: actions,
            risks: risks,
            pendingAsks: pendingAsks,
            retrospectiveRunID: retrospectiveRunID,
            status: .aiEnhanced,
            statusMessage: "AI 增强：已基于本地数据生成日报。",
            aiErrorMessage: nil,
            narrative: narrative,
            tomorrowFocus: tomorrowFocus,
            wechatDraft: wechatDraft
        )
    }

    func withAIUnavailable(_ message: String) -> DailyReport {
        DailyReport(
            date: date,
            dateRange: dateRange,
            generatedAt: generatedAt,
            metrics: metrics,
            highlights: highlights,
            actions: actions,
            risks: risks,
            pendingAsks: pendingAsks,
            retrospectiveRunID: retrospectiveRunID,
            status: .aiUnavailable,
            statusMessage: "本地生成：AI 暂不可用，已保留确定性日报。",
            aiErrorMessage: message,
            narrative: narrative,
            tomorrowFocus: tomorrowFocus,
            wechatDraft: wechatDraft
        )
    }
}
