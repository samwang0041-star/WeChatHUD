import Foundation

/// Deep context analyzer — triggered when user expands a pending ask.
/// Provides background, stakeholder analysis, and action suggestions.
actor ContextAnalyzer {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
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

        let started = Date()
        guard let response = await callModel(prompt: prompt) else {
            await writeAudit(input: ask.summary, output: "", latency: ms(since: started), status: .httpError, error: "no response")
            return nil
        }

        let latency = ms(since: started)
        guard let data = cleanJSON(response).data(using: .utf8),
              let result = try? JSONDecoder().decode(AnalysisResult.self, from: data) else {
            await writeAudit(input: ask.summary, output: response, latency: latency, status: .parseError, error: "JSON parse failed")
            return nil
        }

        await writeAudit(input: ask.summary, output: response, latency: latency, status: .ok, error: nil)
        return result
    }

    // MARK: - Private

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func writeAudit(input: String, output: String, latency: Int, status: AIAuditStatus, error: String?) async {
        let model = await aiService.currentConfig().model
        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .contextAnalyzer,
            model: model, promptVersion: "context_analyzer_v1",
            inputText: input, outputText: output,
            latencyMs: latency, status: status, errorMessage: error
        ))
    }

    private func callModel(prompt: String) async -> String? {
        let trackID = "context:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "上下文分析")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            return try await aiService.complete(
                system: "只输出 JSON。",
                user: prompt,
                options: CompleteOptions(timeout: 45, temperature: 0.1, maxTokens: 384)
            )
        } catch {
            return nil
        }
    }

    private func cleanJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = s.range(of: "<think>") {
            if let end = s.range(of: "</think>") {
                s.removeSubrange(range.lowerBound..<end.upperBound)
            } else { break }
        }
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") {
            s = String(s[start...end])
        }
        return s
    }
}
