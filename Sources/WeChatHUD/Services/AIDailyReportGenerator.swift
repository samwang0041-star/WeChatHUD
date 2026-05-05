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

        return template
            .replacingOccurrences(of: "{unread_count}", with: "\(metrics.unreadMessageCount)")
            .replacingOccurrences(of: "{analyzed_chat_count}", with: "\(metrics.analyzedChatCount)")
            .replacingOccurrences(of: "{highlight_count}", with: "\(metrics.highlightCount)")
            .replacingOccurrences(of: "{pending_todo_count}", with: "\(metrics.pendingTodoCount)")
            .replacingOccurrences(of: "{pending_ask_count}", with: "\(metrics.pendingAskCount)")
            .replacingOccurrences(of: "{pending_commitment_count}", with: "\(metrics.pendingCommitmentCount)")
            .replacingOccurrences(of: "{overdue_commitment_count}", with: "\(metrics.overdueCommitmentCount)")
            .replacingOccurrences(of: "{reply_debt_count}", with: "\(metrics.replyDebtCount)")
            .replacingOccurrences(of: "{recalled_count}", with: "\(metrics.recalledMessageCount)")
            .replacingOccurrences(of: "{highlights}", with: highlightsText.isEmpty ? "暂无高亮数据" : highlightsText)
            .replacingOccurrences(of: "{actions}", with: actionsText.isEmpty ? "暂无待办" : actionsText)
            .replacingOccurrences(of: "{risks}", with: risksText.isEmpty ? "暂无风险" : risksText)
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
