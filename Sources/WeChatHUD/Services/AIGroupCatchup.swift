import Foundation

/// Generates a 3-5 sentence "what did I miss" summary for a noisy
/// group chat. Designed to be triggered manually from a group row's
/// context menu, or automatically when the user opens a group with
/// > N unread messages since their last visit.
///
/// Pure service. Reads its config from `loadAIConfig()` so
/// it tracks whatever model the user has set.
actor AIGroupCatchup {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    func updateConfig(_ newConfig: AIConfig) {
        var c = newConfig; c.maxTokens = 512; c.temperature = 0.15
        self.config = c
    }

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "group_catchup_v1"
    ) {
        self.store = store
        // Catchup is a longer structured response with a few fields,
        // bump max_tokens accordingly. Temperature stays low so the
        // summary is faithful to the messages, not creative.
        var inflated = config
        inflated.maxTokens = 512
        inflated.temperature = 0.15
        self.config = inflated
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Output of one catchup call.
    struct Summary: Decodable {
        let headline: String
        let highlights: [String]
        let needsUserAction: Bool
        let actionSummary: String
        let skipSafe: Bool
        let noiseRatio: Double

        enum CodingKeys: String, CodingKey {
            case headline
            case highlights
            case needsUserAction = "needs_user_action"
            case actionSummary = "action_summary"
            case skipSafe = "skip_safe"
            case noiseRatio = "noise_ratio"
        }
    }

    /// Input bundle. `messages` should be most-recent-last (chronological).
    /// Each entry: (sender, body). Caller is responsible for filtering
    /// out non-text messages and trimming length.
    struct Input {
        let chatName: String
        let selfName: String
        let messages: [(sender: String, body: String)]
    }

    /// Returns the structured catchup, or nil on parse/HTTP failure.
    func summarize(_ input: Input) async -> Summary? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIGroupCatchup: prompt load failed: \(error)")
            return nil
        }

        // Format messages compactly: [sender] body  (one per line)
        let formattedMessages = input.messages
            .map { "[\(clean($0.sender))] \(clean($0.body))" }
            .joined(separator: "\n")

        let userPrompt = template
            .replacingOccurrences(of: "{chat_name}", with: clean(input.chatName))
            .replacingOccurrences(of: "{self_name}", with: clean(input.selfName))
            .replacingOccurrences(of: "{message_count}", with: "\(input.messages.count)")
            .replacingOccurrences(of: "{messages}", with: formattedMessages)

        let first = await call(userPrompt)
        if let parsed = parse(first.text) {
            audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err)
            return nil
        }

        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
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
        let trackID = "catchup:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "群聊追赶")
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
                ["role": "system", "content": "你是一个群聊补课助手，严格按要求输出 JSON。不要进入 thinking 模式，不要输出 <think> 标签。"],
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

    private func parse(_ raw: String) -> Summary? {
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
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) {
        let firstFew = input.messages.prefix(3).map { "\($0.sender): \($0.body.prefix(20))" }.joined(separator: " | ")
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .retrospector,
            model: config.model,
            promptVersion: promptVersion,
            inputText: "[\(input.chatName)|n=\(input.messages.count)] \(firstFew)",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIGroupCatchup: failed to write audit: \(error)")
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
