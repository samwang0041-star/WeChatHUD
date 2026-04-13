import Foundation

/// Generates a one-line summary (<=25 chars) for an inbox item,
/// telling the user "what does this person want from you?"
///
/// Examples:
///   "红字为修改部分请查收" → "等你确认方案修改稿"
///   "@你 方案定了吗"       → "张总问你方案排期"
///
/// Follows the same actor + HTTP + audit pattern as AIReplySuggester.
actor AIInboxSummarizer {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "inbox_summary_v1"
    ) {
        self.store = store
        var c = config
        c.temperature = 0.1    // deterministic summaries
        c.maxTokens = 100      // short output
        self.config = c
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Hot-reload connection params when the user changes AI settings.
    func updateConfig(_ newConfig: AIConfig) {
        var c = newConfig
        c.temperature = 0.1
        c.maxTokens = 100
        self.config = c
    }

    /// Generate a one-line summary for an inbox item.
    /// Returns nil on failure (caller should fall back to raw preview).
    func summarize(_ context: InboxContext) async -> String? {
        guard config.summaryEnabled else { return nil }
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIInboxSummarizer: prompt load failed: \(error)")
            return nil
        }

        // Build context messages string (last N messages as "sender: text" lines)
        let contextStr = context.recentMessages.prefix(5).map { msg in
            "\(msg.senderName): \(String(msg.text.prefix(60)))"
        }.joined(separator: "\n")

        let commitmentsStr = context.pendingCommitments.isEmpty
            ? "无"
            : context.pendingCommitments.map { $0.content }.joined(separator: "; ")

        let asksStr = context.pendingAsks.isEmpty
            ? "无"
            : context.pendingAsks.map { $0.summary }.joined(separator: "; ")

        let userPrompt = template
            .replacingOccurrences(of: "{sender_name}", with: context.triggerMessage.senderName)
            .replacingOccurrences(of: "{sender_role}", with: context.senderRole.rawValue)
            .replacingOccurrences(of: "{chat_name}", with: context.triggerMessage.chatName)
            .replacingOccurrences(of: "{chat_kind}", with: context.isGroupChat ? "群聊" : "私聊")
            .replacingOccurrences(of: "{message_body}", with: context.triggerMessageText)
            .replacingOccurrences(of: "{context_messages}", with: contextStr)
            .replacingOccurrences(of: "{my_last_reply}", with: context.myLastReplyText ?? "无")
            .replacingOccurrences(of: "{pending_commitments}", with: commitmentsStr)
            .replacingOccurrences(of: "{pending_asks}", with: asksStr)

        let result = await call(userPrompt)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        if let text = result.text, !text.isEmpty {
            // Clean: remove quotes, trim, cap at 30 chars
            let cleaned = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\u{201C}", with: "")
                .replacingOccurrences(of: "\u{201D}", with: "")
            let summary = String(cleaned.prefix(30))
            audit(input: context.triggerMessageText, output: summary, latencyMs: latencyMs, status: .ok, error: nil)
            return summary
        }

        audit(
            input: context.triggerMessageText,
            output: "",
            latencyMs: latencyMs,
            status: result.error != nil ? .httpError : .parseError,
            error: result.error
        )
        return nil
    }

    // MARK: - HTTP call

    private struct CallResult {
        let text: String?
        let error: String?
    }

    private func call(_ userPrompt: String) async -> CallResult {
        let baseURL = normalizeURL(config.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            return CallResult(text: nil, error: "invalid url: \(config.baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "你是用户的微信消息管家。只输出摘要文本，不要任何其他内容。"],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                return CallResult(text: nil, error: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(errBody.prefix(200))")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return CallResult(text: nil, error: "could not extract content")
            }
            let cleaned = stripThinking(content)
            return CallResult(text: cleaned, error: nil)
        } catch {
            return CallResult(text: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Helpers

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
            role: .summarizer,
            model: config.model,
            promptVersion: promptVersion,
            inputText: String(input.prefix(100)),
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIInboxSummarizer: audit write failed: \(error)")
        }
    }
}
