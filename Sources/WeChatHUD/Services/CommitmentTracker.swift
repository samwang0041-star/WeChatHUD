import Foundation

/// Scans YOUR outgoing messages for promises/commitments.
actor CommitmentTracker {
    private let store: HUDStore
    private let promptLoader: PromptLoader

    init(store: HUDStore, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.promptLoader = promptLoader
    }

    struct CommitmentResult {
        let isCommitment: Bool
        let content: String
        let commitTo: String
        let deadlineExtracted: String
        let confidence: Double
    }

    /// Quick pre-filter: does message contain commitment signal words?
    /// This is additive — signals passed to AI as hints.
    static func hasCommitmentSignal(_ text: String) -> Bool {
        let signals = [
            "明天", "下周", "今天内", "稍后", "一会儿", "马上",
            "我去", "我来", "我发", "我问", "我看看", "我处理",
            "我安排", "我跟进", "我确认", "帮你", "给你", "发你",
            "回头", "等我", "好的", "没问题", "可以", "行",
            "OK", "ok", "收到", "了解", "月底前", "周五之前"
        ]
        return signals.contains(where: { text.contains($0) })
    }

    /// Analyze a message you sent. Returns nil if AI unavailable.
    func analyze(
        yourMessage: MessageInfo,
        contextMessages: [AnnotatedMessage],
        recipientName: String,
        recipientRole: ContactRole
    ) async -> CommitmentResult? {
        let config = store.loadClassifierConfig()
        guard !config.baseURL.isEmpty else { return nil }

        let template: String
        do { template = try promptLoader.load(version: "commitment_v1") }
        catch { print("[WCHUD] CommitmentTracker: prompt load failed: \(error)"); return nil }

        let signals = CommitmentTracker.hasCommitmentSignal(yourMessage.text)
            ? "算法检测到承诺信号词" : "算法未检测到明显信号词"

        let contextText = contextMessages.map {
            "[\(MessageInfo.formatRelative($0.createTime))] \($0.senderName): \($0.text)"
        }.joined(separator: "\n")

        let prompt = template
            .replacingOccurrences(of: "{recipient_name}", with: recipientName)
            .replacingOccurrences(of: "{recipient_role}", with: recipientRole.label)
            .replacingOccurrences(of: "{commitment_signals}", with: signals)
            .replacingOccurrences(of: "{context_messages}", with: contextText)
            .replacingOccurrences(of: "{user_message}", with: yourMessage.text)

        let started = Date()
        let response = await callModel(prompt: prompt, config: config)
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        guard let body = response else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: config.model, promptVersion: "commitment_v1",
                inputText: yourMessage.text, outputText: "",
                latencyMs: latency, status: .httpError, errorMessage: "no response"
            ))
            return nil
        }

        guard let result = parseResult(body) else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: config.model, promptVersion: "commitment_v1",
                inputText: yourMessage.text, outputText: body,
                latencyMs: latency, status: .parseError, errorMessage: "JSON parse failed"
            ))
            return nil
        }

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .commitmentTracker,
            model: config.model, promptVersion: "commitment_v1",
            inputText: yourMessage.text, outputText: body,
            latencyMs: latency, status: .ok, errorMessage: nil
        ))
        return result
    }

    private func callModel(prompt: String, config: AIClassifierConfig) async -> String? {
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else { return nil }
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
            "max_tokens": 256
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private func parseResult(_ text: String) -> CommitmentResult? {
        let cleaned = cleanJSON(text)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isCommitment = json["is_commitment"] as? Bool else { return nil }
        return CommitmentResult(
            isCommitment: isCommitment,
            content: json["content"] as? String ?? "",
            commitTo: json["commit_to"] as? String ?? "",
            deadlineExtracted: json["deadline_extracted"] as? String ?? "none",
            confidence: json["confidence"] as? Double ?? 0.5
        )
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
