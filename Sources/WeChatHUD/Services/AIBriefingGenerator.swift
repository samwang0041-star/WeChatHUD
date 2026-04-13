import Foundation

/// Generates a structured briefing (situation + suggestion + 3 reply candidates)
/// when the user expands an inbox item. Returns `InboxBriefing?`.
///
/// Follows the same actor + HTTP + audit + retry pattern as AIReplySuggester.
actor AIBriefingGenerator {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "inbox_briefing_v1"
    ) {
        self.store = store
        var c = config
        c.temperature = 0.3    // slightly creative for reply suggestions
        c.maxTokens = 512      // longer structured output
        self.config = c
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Hot-reload connection params when the user changes AI settings.
    func updateConfig(_ newConfig: AIConfig) {
        var c = newConfig
        c.temperature = 0.3
        c.maxTokens = 512
        self.config = c
    }

    /// Generate a structured briefing for an inbox item.
    /// Returns nil on failure (caller should fall back to basic display).
    func generate(_ context: InboxContext, styleHint: String? = nil) async -> InboxBriefing? {
        guard config.summaryEnabled else { return nil }
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIBriefingGenerator: prompt load failed: \(error)")
            return nil
        }

        // Build context messages string
        let contextStr = context.recentMessages.prefix(8).map { msg in
            "\(msg.senderName): \(String(msg.text.prefix(80)))"
        }.joined(separator: "\n")

        let commitmentsStr = context.pendingCommitments.isEmpty
            ? "无"
            : context.pendingCommitments.map { $0.content }.joined(separator: "; ")

        let asksStr = context.pendingAsks.isEmpty
            ? "无"
            : context.pendingAsks.map { $0.summary }.joined(separator: "; ")

        let timeSinceReply: String
        if let interval = context.timeSinceMyLastReply {
            let minutes = Int(interval / 60)
            if minutes < 60 {
                timeSinceReply = "\(minutes)分钟前"
            } else {
                timeSinceReply = "\(minutes / 60)小时\(minutes % 60)分钟前"
            }
        } else {
            timeSinceReply = "无记录"
        }

        var userPrompt = template
            .replacingOccurrences(of: "{sender_name}", with: context.triggerMessage.senderName)
            .replacingOccurrences(of: "{sender_role}", with: context.senderRole.rawValue)
            .replacingOccurrences(of: "{chat_name}", with: context.triggerMessage.chatName)
            .replacingOccurrences(of: "{chat_kind}", with: context.isGroupChat ? "群聊" : "私聊")
            .replacingOccurrences(of: "{message_body}", with: context.triggerMessageText)
            .replacingOccurrences(of: "{context_messages}", with: contextStr)
            .replacingOccurrences(of: "{my_last_reply}", with: context.myLastReplyText ?? "无")
            .replacingOccurrences(of: "{time_since_reply}", with: timeSinceReply)
            .replacingOccurrences(of: "{pending_commitments}", with: commitmentsStr)
            .replacingOccurrences(of: "{pending_asks}", with: asksStr)
            .replacingOccurrences(of: "{is_overdue}", with: context.isOverdue ? "是" : "否")
            .replacingOccurrences(of: "{overdue_minutes}", with: "\(context.overdueMinutes)")
            .replacingOccurrences(of: "{inbound_count}", with: "\(context.inboundCountSinceMyLastReply)")

        // Append style hint if available
        if let hint = styleHint {
            userPrompt += "\n\n[风格参考] \(hint)"
        }

        // First attempt
        let first = await call(userPrompt)
        if let briefing = parse(first.text) {
            audit(input: context.triggerMessageText, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil)
            return briefing
        }
        if first.text.isEmpty, let err = first.error {
            audit(input: context.triggerMessageText, output: "", latencyMs: ms(since: started), status: .httpError, error: err)
            return nil
        }

        // Stricter retry
        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let briefing = parse(second.text) {
            audit(input: context.triggerMessageText, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry")
            return briefing
        }

        audit(
            input: context.triggerMessageText,
            output: second.text,
            latencyMs: ms(since: started),
            status: .parseError,
            error: second.error ?? "JSON parse failed after retry"
        )
        return nil
    }

    // MARK: - HTTP call

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
                ["role": "system", "content": "你是用户的微信消息管家。严格按要求输出 JSON，不要任何其他内容。"],
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
                let errBody = String(data: data, encoding: .utf8) ?? ""
                return ModelResponse(text: "", error: "HTTP \(http.statusCode): \(errBody.prefix(200))")
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

    private func parse(_ raw: String) -> InboxBriefing? {
        guard !raw.isEmpty else { return nil }
        var cleaned = raw

        // Strip markdown code fences
        if let fenceRange = cleaned.range(of: "```") {
            cleaned = String(cleaned[fenceRange.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let endFence = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<endFence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON object
        if !cleaned.hasPrefix("{") {
            if let lo = cleaned.firstIndex(of: "{"), let hi = cleaned.lastIndex(of: "}") {
                cleaned = String(cleaned[lo...hi])
            }
        }

        guard let data = cleaned.data(using: .utf8) else { return nil }
        do {
            let briefing = try JSONDecoder().decode(InboxBriefing.self, from: data)
            // Validate: must have at least 1 reply
            return briefing.replies.isEmpty ? nil : briefing
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audit

    private func audit(input: String, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .briefer,
            model: config.model,
            promptVersion: promptVersion,
            inputText: String(input.prefix(100)),
            outputText: String(output.prefix(300)),
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIBriefingGenerator: audit write failed: \(error)")
        }
    }
}
