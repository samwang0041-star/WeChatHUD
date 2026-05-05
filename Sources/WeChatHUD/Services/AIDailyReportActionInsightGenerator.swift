import Foundation

/// Generates per-action AI insights (reason + nextStep) for the daily report.
/// One batched call per `loadDailyReport` invocation. Caches results in
/// `daily_report_action_insights` keyed by (dateKey, actionID); cached
/// rows are not re-requested.
actor AIDailyReportActionInsightGenerator {
    private let aiService: AIService
    private let store: HUDStore
    private let promptLoader: PromptLoader
    private let promptVersion: String
    static let actionsPerCall = 12

    init(
        aiService: AIService,
        store: HUDStore,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "daily_report_action_insights_v1"
    ) {
        self.aiService = aiService
        self.store = store
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    // MARK: - Output schema

    struct AIRow: Decodable {
        let id: String
        let reason: String
        let nextStep: String

        enum CodingKeys: String, CodingKey {
            case id, reason
            case nextStep = "next_step"
        }
    }

    // MARK: - Generate

    func generate(for actions: [DailyReportAction], dateKey: String) async -> [DailyReportActionInsight] {
        guard !actions.isEmpty else { return [] }

        // 1. Load cache; partition into hits and misses.
        let cached = store.loadActionInsights(dateKey: dateKey)
        let cacheMap = Dictionary(uniqueKeysWithValues: cached.map { ($0.actionID, $0) })

        var hits: [DailyReportActionInsight] = []
        var misses: [DailyReportAction] = []
        for a in actions {
            if let c = cacheMap[a.id] { hits.append(c) } else { misses.append(a) }
        }
        if misses.isEmpty { return hits }

        // 2. Load template.
        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            await audit(dateKey: dateKey, output: "", latencyMs: 0,
                        status: .parseError, error: "prompt load failed: \(error)", model: nil)
            return hits
        }

        // 3. Call AI with retry on parse failure.
        let started = Date()
        let userPrompt = formatPrompt(template: template, actions: misses)

        var rows: [AIRow] = []
        let first = await call(userPrompt)
        rows = parse(first.text)
        if rows.isEmpty, !first.text.isEmpty {
            let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON 数组。只输出符合 schema 的 JSON 数组，不要任何其他文字。"
            let second = await call(strict)
            rows = parse(second.text)
            if rows.isEmpty {
                await audit(dateKey: dateKey, output: second.text,
                            latencyMs: ms(since: started),
                            status: .parseError, error: "JSON parse failed after retry", model: second.model)
                return hits
            }
        } else if rows.isEmpty {
            await audit(dateKey: dateKey, output: "", latencyMs: ms(since: started),
                        status: .httpError, error: first.error ?? "empty AI response", model: first.model)
            return hits
        }

        // 4. Match rows by id and persist.
        let now = Date()
        let missMap = Dictionary(uniqueKeysWithValues: misses.map { ($0.id, $0) })
        var fresh: [DailyReportActionInsight] = []
        for row in rows where missMap[row.id] != nil {
            let insight = DailyReportActionInsight(
                dateKey: dateKey,
                actionID: row.id,
                reason: row.reason,
                nextStep: row.nextStep,
                modelVersion: promptVersion,
                generatedAt: now
            )
            do {
                try store.upsertActionInsight(insight)
                fresh.append(insight)
            } catch {
                print("[WCHUD] insight upsert failed for \(row.id): \(error)")
            }
        }

        await audit(dateKey: dateKey, output: "rows=\(rows.count) fresh=\(fresh.count)",
                    latencyMs: ms(since: started), status: .ok, error: nil, model: nil)

        return hits + fresh
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "daily_insight:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "日报逐条注释")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是工作调度助手，严格按要求输出 JSON 数组。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 1024, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Audit

    private func audit(dateKey: String, output: String, latencyMs: Int,
                       status: AIAuditStatus, error: String?, model: String?) async {
        let resolved: String
        if let model {
            resolved = model
        } else {
            resolved = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0, ts: Date(), role: .retrospector, model: resolved,
            promptVersion: promptVersion,
            inputText: "[daily_action_insights|\(dateKey)]",
            outputText: output, latencyMs: latencyMs,
            status: status, errorMessage: error
        )
        do {
            try store.writeAIAudit(entry)
        } catch {
            print("[WCHUD] AIDailyReportActionInsightGenerator audit failed: \(error)")
        }
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - Prompt formatting

    nonisolated func formatPrompt(template: String, actions: [DailyReportAction]) -> String {
        let capped = Array(actions.prefix(Self.actionsPerCall))
        let lines = capped.map { a -> String in
            let deadline = a.deadline.map { " deadline=\"\($0.formatted(date: .abbreviated, time: .shortened))\"" } ?? ""
            return "id=\"\(a.id)\" type=\"\(a.type.rawValue)\" source=\"\(a.sourceChatName)\"\(deadline) content=\"\(a.content.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return template
            .replacingOccurrences(of: "{count}", with: "\(capped.count)")
            .replacingOccurrences(of: "{actions}", with: lines.joined(separator: "\n"))
    }

    // MARK: - Parsing

    nonisolated func parse(_ raw: String) -> [AIRow] {
        AIJSONExtractor.decodeFirstArray(from: raw, as: AIRow.self) ?? []
    }
}
