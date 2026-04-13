import Foundation

/// Generates 3 reply candidates for an inbound WeChat message in
/// 3 different tones (friendly / formal / brief). Designed to be
/// surfaced as a context menu on a "待决" row so the user can
/// one-click a reply without typing.
///
/// Pure service. No DB writes (apart from audit log via the shared
/// HUDStore). Reads its config from `loadAIConfig()` so it
/// always tracks whatever model the user has set.
///
/// See `docs/superpowers/plans/2026-04-12-wechathud-ai-subsystem.md`
/// for the role definitions and gating.
actor AIReplySuggester {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "reply_suggester_v1"
    ) {
        self.store = store
        // Reuse classifier config but bump max_tokens for the longer
        // structured output (~3 candidates × ~30 chars + JSON envelope).
        var inflated = config
        inflated.maxTokens = 512
        inflated.temperature = 0.4   // creative variety, but not random
        self.config = inflated
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Hot-reload connection params when the user changes AI settings.
    func updateConfig(_ newConfig: AIConfig) {
        var inflated = newConfig
        inflated.maxTokens = 512
        inflated.temperature = 0.4
        self.config = inflated
    }

    /// One reply suggestion. `tone` matches the prompt's friendly /
    /// formal / brief vocabulary.
    struct Suggestion: Decodable {
        let text: String
        let tone: String
        let rationale: String
    }

    /// Top-level schema returned by the model. Stays decoupled from
    /// the public Suggestion type.
    private struct ResultDTO: Decodable {
        let suggestions: [Suggestion]
    }

    /// Input bundle. `askType` and `relationship` come from the
    /// caller's existing PendingAsk + whitelist lookup so we don't
    /// re-classify the message just to suggest replies.
    struct Input {
        let messageBody: String
        let senderName: String
        let chatName: String
        let isGroup: Bool
        let askType: AskType
        /// "work" / "life" / "other" — comes from whitelist category,
        /// or "unknown" if not on whitelist.
        let relationship: String
        /// Optional style hint from StyleProfiler to match user's writing style.
        let styleHint: String?
        /// Optional feedback context — what the user liked/disliked in past suggestions.
        let feedbackContext: String?

        init(messageBody: String, senderName: String, chatName: String,
             isGroup: Bool, askType: AskType, relationship: String,
             styleHint: String? = nil, feedbackContext: String? = nil) {
            self.messageBody = messageBody
            self.senderName = senderName
            self.chatName = chatName
            self.isGroup = isGroup
            self.askType = askType
            self.relationship = relationship
            self.styleHint = styleHint
            self.feedbackContext = feedbackContext
        }
    }

    /// Returns 3 candidate replies, or nil if the model failed twice.
    /// Audits every call (success and failure) to `ai_audit`.
    func suggest(_ input: Input) async -> [Suggestion]? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIReplySuggester: prompt load failed: \(error)")
            return nil
        }

        var userPrompt = template
            .replacingOccurrences(of: "{message_body}", with: clean(input.messageBody))
            .replacingOccurrences(of: "{sender_name}", with: clean(input.senderName))
            .replacingOccurrences(of: "{chat_name}", with: clean(input.chatName))
            .replacingOccurrences(of: "{chat_kind}", with: input.isGroup ? "群聊" : "私聊")
            .replacingOccurrences(of: "{ask_type}", with: input.askType.rawValue)
            .replacingOccurrences(of: "{relationship}", with: input.relationship)

        // Append style hint if available (from StyleProfiler)
        if let hint = input.styleHint {
            userPrompt += "\n\n[风格参考] \(hint)"
        }
        // Append feedback context (from AI learning loop)
        if let feedback = input.feedbackContext {
            userPrompt += "\n\n[用户偏好反馈] \(feedback)"
        }

        // First attempt
        let first = await call(userPrompt)
        if let parsed = parse(first.text) {
            audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err)
            return nil
        }

        // Stricter retry
        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let parsed = parse(second.text) {
            audit(input: input, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry")
            return parsed
        }

        audit(input: input, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry")
        return nil
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "reply:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "回复建议")
        defer { AIActivityTracker.shared.end(trackID) }
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
                ["role": "system", "content": "你是一个回复建议助手，严格按要求输出 JSON。"],
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
            return ModelResponse(text: "", error: "request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> [Suggestion]? {
        guard !raw.isEmpty else { return nil }
        var cleaned = raw

        if let fenceRange = cleaned.range(of: "```") {
            cleaned = String(cleaned[fenceRange.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let endFence = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<endFence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("{") {
            if let lo = cleaned.firstIndex(of: "{"), let hi = cleaned.lastIndex(of: "}") {
                cleaned = String(cleaned[lo...hi])
            }
        }

        guard let data = cleaned.data(using: .utf8) else { return nil }
        do {
            let dto = try JSONDecoder().decode(ResultDTO.self, from: data)
            return dto.suggestions.isEmpty ? nil : dto.suggestions
        } catch {
            return nil
        }
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .ranker,           // reply suggestion is a "ranker" role per design
            model: config.model,
            promptVersion: promptVersion,
            inputText: "[\(input.senderName)@\(input.chatName)|\(input.askType.rawValue)] \(input.messageBody)",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIReplySuggester: failed to write audit: \(error)")
        }
    }

    // MARK: - Helpers

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
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
}
