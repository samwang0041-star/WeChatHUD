import Foundation

/// Deep context analyzer — triggered when user expands a pending ask.
/// Provides background, stakeholder analysis, and action suggestions.
///
/// All AI calls go through `AIAnalysisPipeline` for unified retry, parsing, and audit.
actor ContextAnalyzer {
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

    struct Stakeholder: Codable {
        let name: String
        let stance: String
        let detail: String
    }

    struct AnalysisResult: Codable {
        let background: String
        let whatTheyWant: String
        let hiddenContext: String?
        let stakeholderMap: [Stakeholder]
        let yourPosition: String
        let suggestedAction: String
        let suggestedTiming: String
        let riskIfIgnore: String

        enum CodingKeys: String, CodingKey {
            case background
            case whatTheyWant = "what_they_want"
            case hiddenContext = "hidden_context"
            case stakeholderMap = "stakeholder_map"
            case yourPosition = "your_position"
            case suggestedAction = "suggested_action"
            case suggestedTiming = "suggested_timing"
            case riskIfIgnore = "risk_if_ignore"
        }
    }

    /// Analyze the full context of a pending ask.
    func analyze(
        ask: PendingAsk,
        senderRole: ContactRole,
        conversationContext: ContextWindow,
        senderProfile: String,
        userCommitments: String
    ) async -> AnalysisResult? {
        guard await aiService.isConfigured() else { return nil }

        let template: String
        do { template = try promptLoader.load(version: "context_analyzer_v1") }
        catch { print("[WCHUD] ContextAnalyzer: prompt load failed: \(error)"); return nil }

        let prompt = template
            .replacingOccurrences(of: "{ask_summary}", with: ask.summary)
            .replacingOccurrences(of: "{sender_name}", with: ask.senderName)
            .replacingOccurrences(of: "{sender_role}", with: senderRole.label)
            .replacingOccurrences(of: "{ask_type}", with: ask.askType.rawValue)
            .replacingOccurrences(of: "{urgency}", with: ask.urgency?.rawValue ?? "routine")
            .replacingOccurrences(of: "{conversation_thread}", with: conversationContext.serialize())
            .replacingOccurrences(of: "{sender_profile}", with: senderProfile.isEmpty ? "（暂无数据）" : senderProfile)
            .replacingOccurrences(of: "{user_commitments}", with: userCommitments.isEmpty ? "（无未完成承诺）" : userCommitments)

        let result = await pipeline.execute(
            prompt: prompt,
            configuration: .init(
                systemPrompt: "只输出 JSON。",
                options: CompleteOptions(timeout: 45, temperature: 0.1, maxTokens: 384, responseFormatJSON: true),
                auditRole: .contextAnalyzer,
                promptVersion: "context_analyzer_v1",
                inputSummary: ask.summary,
                trackLabel: "上下文分析"
            ),
            decodeAs: AnalysisResult.self
        )

        return result?.value
    }
}
