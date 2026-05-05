import Foundation

/// Analyzes recalled (withdrawn) WeChat messages for intelligence value.
///
/// When a contact recalls a message, this actor loads the prompt template,
/// interpolates context, calls the configured AI model, parses the JSON result,
/// writes analysis back to the DB, and emits an audit log entry.
///
/// All AI calls go through `AIAnalysisPipeline` for unified retry and audit.
/// Uses `executeRaw` because parsing requires `JSONSerialization` for flexible field access.
actor RecallAnalyzer {
    private let store: HUDStore
    private let aiService: AIService
    private let pipeline: AIAnalysisPipeline
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.pipeline = AIAnalysisPipeline(aiService: aiService, store: store)
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
    /// On success writes the analysis back to the DB.
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

        let result = await pipeline.executeRaw(
            prompt: prompt,
            configuration: .init(
                systemPrompt: "只输出 JSON。",
                options: CompleteOptions(timeout: 30, temperature: 0.05, maxTokens: 256, responseFormatJSON: true),
                auditRole: .recallAnalyzer,
                promptVersion: "recall_analyzer_v1",
                inputSummary: "[\(recalled.senderName)@\(recalled.chatName)] recalled: \(recalled.originalText.prefix(60))",
                trackLabel: "撤回分析"
            )
        )

        guard let (text, _) = result else { return nil }

        guard let parsed = parseResult(text) else {
            print("[WCHUD] RecallAnalyzer: JSON parse failed")
            return nil
        }

        // Write analysis back to DB
        let notifyLevel = parsed.notifyLevel ?? .light
        try? store.updateRecallAnalysis(
            msgUID: recalled.msgUID,
            reason: parsed.reason,
            value: parsed.intelligenceValue,
            detail: parsed.detail ?? "",
            shouldNotify: parsed.shouldNotify,
            notifyLevel: notifyLevel
        )

        return parsed
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
