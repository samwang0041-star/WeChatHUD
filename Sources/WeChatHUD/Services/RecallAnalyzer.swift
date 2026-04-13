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
    private let promptLoader: PromptLoader

    init(store: HUDStore, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
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
        let config = store.loadAIConfig()
        guard !config.baseURL.isEmpty else { return nil }

        let template: String
        do { template = try promptLoader.load(version: "recall_analyzer_v1") }
        catch { print("[WCHUD] RecallAnalyzer: prompt load failed: \(error)"); return nil }

        let contextText: String
        if context.isEmpty {
            contextText = "（无上下文）"
        } else {
            contextText = context.map { msg in
                let ts = MessageInfo.formatRelative(msg.createTime)
                return "[\(ts)] \(msg.senderName): \(msg.text)"
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
        let response = await callModel(prompt: prompt, config: config)
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        let inputSummary = "[\(recalled.senderName)@\(recalled.chatName)] recalled: \(recalled.originalText.prefix(60))"

        guard let body = response else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .recallAnalyzer,
                model: config.model, promptVersion: "recall_analyzer_v1",
                inputText: inputSummary, outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: "no response"
            ))
            return nil
        }

        guard let result = parseResult(body) else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .recallAnalyzer,
                model: config.model, promptVersion: "recall_analyzer_v1",
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
            model: config.model, promptVersion: "recall_analyzer_v1",
            inputText: inputSummary, outputText: body,
            latencyMs: latency, status: .ok, errorMessage: nil
        ))

        return result
    }

    // MARK: - Model call

    private func callModel(prompt: String, config: AIConfig) async -> String? {
        let trackID = "recall:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "撤回分析")
        defer { AIActivityTracker.shared.end(trackID) }
        guard let url = URL(string: "\(normalizeURL(config.baseURL))/chat/completions") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.1,
            "max_tokens": 256,
            "stream": false
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
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
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let start = s.range(of: "<think>") {
            if let end = s.range(of: "</think>") {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else { break }
        }
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}") {
            s = String(s[lo...hi])
        }
        return s
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeURL(_ url: String) -> String {
        var u = url
        if !u.contains("://") { u = "http://\(u)" }
        while u.hasSuffix("/") { u.removeLast() }
        if !u.hasSuffix("/v1") { u += "/v1" }
        return u
    }
}
