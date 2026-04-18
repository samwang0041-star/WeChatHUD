import Foundation

/// AI-powered chat insight analysis.
/// Analyzes individual chats and generates global briefings.
actor AIChatInsight {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader()
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    // MARK: - Single chat analysis

    /// Analyze a single chat's messages and return structured insight.
    func analyzeChat(
        chatUsername: String,
        chatName: String,
        chatType: String,  // "group" or "private"
        category: String,  // "work", "life", "other"
        selfName: String,
        timeRange: String,
        messages: [(sender: String, body: String, time: Int)],
        recalledMessages: [(sender: String, content: String)],
        memory: String
    ) async -> ChatInsightResult? {
        // Check cache first
        let inputHash = simpleHash("\(chatUsername)_\(timeRange)_\(messages.count)")
        if let cached = store.loadAnalysisCache(
            chatUsername: chatUsername,
            analysisType: "chat_insight_v1",
            inputHash: inputHash
        ) {
            return parseInsight(cached)
        }

        // Load and fill prompt template
        let template: String
        do {
            template = try promptLoader.load(version: "chat_insight_v1")
        } catch {
            print("[ChatInsight] Failed to load prompt template: \(error)")
            return nil
        }

        let formattedMessages = messages.map { "[\($0.sender)] \($0.body)" }.joined(separator: "\n")
        let formattedRecalled = recalledMessages.isEmpty
            ? "无"
            : recalledMessages.map { "[\($0.sender)] \($0.content)" }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{chat_type}", with: chatType)
            .replacingOccurrences(of: "{category}", with: category)
            .replacingOccurrences(of: "{self_name}", with: selfName)
            .replacingOccurrences(of: "{time_range}", with: timeRange)
            .replacingOccurrences(of: "{messages}", with: formattedMessages)
            .replacingOccurrences(of: "{recalled_messages}", with: formattedRecalled)
            .replacingOccurrences(of: "{memory}", with: memory.isEmpty ? "无" : memory)

        let started = Date()

        // Call AI
        let response = await call(prompt)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        guard !response.text.isEmpty else {
            return nil
        }

        // Parse
        if let result = parseInsight(response.text) {
            try? store.writeAnalysisCache(
                chatUsername: chatUsername,
                analysisType: "chat_insight_v1",
                inputHash: inputHash,
                result: response.text,
                ttlHours: 2
            )
            await writeAudit(
                chatUsername: chatUsername,
                prompt: prompt,
                output: response.text,
                latencyMs: latencyMs,
                status: .ok,
                error: nil
            )
            return result
        }

        // Retry with strict instruction
        let retry = prompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
        let retryResponse = await call(retry)
        guard !retryResponse.text.isEmpty,
              let retryResult = parseInsight(retryResponse.text) else {
            await writeAudit(
                chatUsername: chatUsername,
                prompt: prompt,
                output: retryResponse.text,
                latencyMs: latencyMs,
                status: .parseError,
                error: "JSON parse failed after retry"
            )
            return nil
        }

        try? store.writeAnalysisCache(
            chatUsername: chatUsername,
            analysisType: "chat_insight_v1",
            inputHash: inputHash,
            result: retryResponse.text,
            ttlHours: 2
        )
        await writeAudit(
            chatUsername: chatUsername,
            prompt: prompt,
            output: retryResponse.text,
            latencyMs: latencyMs,
            status: .ok,
            error: "recovered after retry"
        )
        return retryResult
    }

    // MARK: - Global briefing

    /// Generate a global briefing from all per-chat insights.
    func generateGlobalBriefing(
        selfName: String,
        date: String,
        chatInsights: [(chatName: String, result: ChatInsightResult)],
        globalStats: BriefingStats
    ) async -> GlobalBriefing? {
        let template: String
        do {
            template = try promptLoader.load(version: "chat_insight_global_v1")
        } catch {
            print("[ChatInsight] Failed to load global prompt template: \(error)")
            return nil
        }

        // Serialize chat insights to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let insightsJSON: String
        do {
            let data = try encoder.encode(chatInsights.map { $0.result })
            insightsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            insightsJSON = "[]"
        }

        let statsJSON: String
        do {
            let data = try encoder.encode(globalStats)
            statsJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            statsJSON = "{}"
        }

        let prompt = template
            .replacingOccurrences(of: "{self_name}", with: selfName)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{chat_insights}", with: insightsJSON)
            .replacingOccurrences(of: "{global_stats}", with: statsJSON)

        let response = await call(prompt)
        guard !response.text.isEmpty else { return nil }
        return parseGlobalBriefing(response.text)
    }

    // MARK: - HTTP call

    private struct ModelResponse {
        let text: String
        let error: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "insight:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "对话洞察")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let content = try await aiService.complete(
                system: "",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.15, maxTokens: 1200)
            )
            return ModelResponse(text: content, error: nil)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription)
        }
    }

    // MARK: - JSON parsing

    private func parseInsight(_ raw: String) -> ChatInsightResult? {
        guard let jsonStr = extractJSON(raw),
              let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatInsightResult.self, from: data)
    }

    private func parseGlobalBriefing(_ raw: String) -> GlobalBriefing? {
        guard let jsonStr = extractJSON(raw),
              let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GlobalBriefing.self, from: data)
    }

    /// Extract JSON object from raw AI response (handles markdown fences, leading text).
    private func extractJSON(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown fences
        s = s.replacingOccurrences(of: "```json", with: "")
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find JSON boundaries
        guard let start = s.firstIndex(of: "{") else { return nil }
        guard let end = s.lastIndex(of: "}") else { return nil }
        return String(s[start...end])
    }

    // MARK: - Helpers

    private func simpleHash(_ input: String) -> String {
        // Simple hash — doesn't need to be cryptographic for cache keys
        String(input.hashValue)
    }

    private func writeAudit(
        chatUsername: String,
        prompt: String,
        output: String,
        latencyMs: Int,
        status: AIAuditStatus,
        error: String?
    ) async {
        let model = await aiService.currentConfig().model
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .contextAnalyzer,
            model: model,
            promptVersion: "chat_insight_v1",
            inputText: "[\(chatUsername)] \(prompt.prefix(100))",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        try? store.writeAIAudit(entry)
    }
}
