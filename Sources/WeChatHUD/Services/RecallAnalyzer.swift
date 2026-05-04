import Foundation

/// Analyzes recalled (withdrawn) WeChat messages for intelligence value.
///
/// When a contact recalls a message, this actor loads the prompt template,
/// interpolates context, calls the configured AI model, parses the JSON result,
/// writes analysis back to the DB, and emits an audit log entry.
///
/// Follows the same patterns as `CommitmentTracker` and `VIPAggregator`.
actor RecallAnalyzer {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    // MARK: - Result type

    struct AnalysisResult {
        let reason: String
        let intelligenceValue: String
        let detail: String?
        let shouldNotify: Bool
        let notifyLevel: NotifyLevel?
    }

    // MARK: - Public API

    /// Analyze a recalled message. Returns nil when AI is unavailable or parsing fails.
    /// On success writes the analysis back to the DB and emits an audit log entry.
    func analyze(recalled: RecalledMessage, context: [MessageInfo]) async -> AnalysisResult? {
        let template: String
        do { template = try promptLoader.load(version: "recall_analyzer_v1") }
        catch { print("[WCHUD] RecallAnalyzer: prompt load failed: \(error)"); return nil }

        let contextText: String
        if context.isEmpty {
            contextText = "（无上下文）"
        } else {
            contextText = context.map { msg in
                let ts = MessageInfo.formatRelative(msg.createTime)
                return "[\(ts)] \(msg.senderName): \(AIService.sanitizeForAI(msg.text))"
            }.joined(separator: "\n")
        }

        let chatTypeLabel: String
        switch recalled.chatType {
        case .privateChat: chatTypeLabel = "私聊"
        case .group:       chatTypeLabel = "群聊"
        }

        let prompt = template
            .replacingOccurrences(of: "{sender_name}", with: escape(recalled.senderName))
            .replacingOccurrences(of: "{sender_role}", with: recalled.senderRole.label)
            .replacingOccurrences(of: "{original_text}", with: escape(recalled.originalText))
            .replacingOccurrences(of: "{delay_seconds}", with: "\(recalled.recallDelaySeconds)")
            .replacingOccurrences(of: "{chat_type}", with: chatTypeLabel)
            .replacingOccurrences(of: "{chat_name}", with: escape(recalled.chatName))
            .replacingOccurrences(of: "{context}", with: contextText)

        let started = Date()
        let response = await callModel(prompt: prompt)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let model: String
        if let actualModel = response.model {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }

        let inputSummary = "[\(recalled.senderName)@\(recalled.chatName)] recalled: \(recalled.originalText.prefix(60))"

        guard let body = response.text else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .recallAnalyzer,
                model: model, promptVersion: "recall_analyzer_v1",
                inputText: inputSummary, outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: response.error ?? "no response"
            ))
            return nil
        }

        guard let result = parseResult(body) else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .recallAnalyzer,
                model: model, promptVersion: "recall_analyzer_v1",
                inputText: inputSummary, outputText: body,
                latencyMs: latency, status: .parseError, errorMessage: "JSON parse failed"
            ))
            return nil
        }

        // Write analysis back to DB
        let notifyLevel = result.notifyLevel ?? .light
        try? store.updateRecallAnalysis(
            msgUID: recalled.msgUID,
            reason: result.reason,
            value: result.intelligenceValue,
            detail: result.detail ?? "",
            shouldNotify: result.shouldNotify,
            notifyLevel: notifyLevel
        )

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .recallAnalyzer,
            model: model, promptVersion: "recall_analyzer_v1",
            inputText: inputSummary, outputText: body,
            latencyMs: latency, status: .ok, errorMessage: nil
        ))

        return result
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String?
        let error: String?
        let model: String?
    }

    private func callModel(prompt: String) async -> ModelResponse {
        let trackID = "recall:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "撤回分析")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "只输出 JSON。",
                user: prompt,
                options: CompleteOptions(timeout: 30, temperature: 0.05, maxTokens: 256, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: nil, error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    private func parseResult(_ text: String) -> AnalysisResult? {
        let cleaned = cleanJSON(text)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = json["likely_reason"] as? String,
              let intelligenceValue = json["intelligence_value"] as? String,
              let shouldNotify = json["should_notify"] as? Bool else { return nil }

        let detail = json["detail"] as? String
        let notifyLevelStr = json["notify_level"] as? String
        let notifyLevel = notifyLevelStr.flatMap { NotifyLevel(rawValue: $0) }

        return AnalysisResult(
            reason: reason,
            intelligenceValue: intelligenceValue,
            detail: (detail?.isEmpty == true) ? nil : detail,
            shouldNotify: shouldNotify,
            notifyLevel: notifyLevel
        )
    }

    // MARK: - Helpers

    private func cleanJSON(_ text: String) -> String {
        AIJSONExtractor.firstObjectString(from: text)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
