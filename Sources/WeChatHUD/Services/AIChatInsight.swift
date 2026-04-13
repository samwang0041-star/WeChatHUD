import Foundation

/// AI-powered chat insight analysis.
/// Analyzes individual chats and generates global briefings.
actor AIChatInsight {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader()
    ) {
        self.store = store
        var inflated = config
        inflated.maxTokens = 2048  // insight output is larger
        inflated.temperature = 0.2
        self.config = inflated
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
            writeAudit(
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
            writeAudit(
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
        writeAudit(
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

    // MARK: - HTTP call (same pattern as AIGroupCatchup)

    private struct ModelResponse {
        let text: String
        let error: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let baseURL = normalizeURL(config.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            return ModelResponse(text: "", error: "invalid url: \(config.baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": userPrompt]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return ModelResponse(text: "", error: "no http response")
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return ModelResponse(text: "", error: "HTTP \(http.statusCode): \(body.prefix(200))")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return ModelResponse(text: "", error: "could not extract content")
            }
            return ModelResponse(text: stripThinking(content), error: nil)
        } catch {
            print("[ChatInsight] API error: \(error.localizedDescription)")
            return ModelResponse(text: "", error: "request failed: \(error.localizedDescription)")
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

    private func normalizeURL(_ url: String) -> String {
        var u = url
        if !u.contains("://") { u = "http://\(u)" }
        while u.hasSuffix("/") { u.removeLast() }
        if !u.hasSuffix("/v1") { u += "/v1" }
        return u
    }

    private func stripThinking(_ text: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeAudit(
        chatUsername: String,
        prompt: String,
        output: String,
        latencyMs: Int,
        status: AIAuditStatus,
        error: String?
    ) {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .contextAnalyzer,
            model: config.model,
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
