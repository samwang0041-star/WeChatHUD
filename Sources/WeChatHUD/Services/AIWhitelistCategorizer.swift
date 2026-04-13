import Foundation

/// Suggests a whitelist category (work / life / other) for a contact
/// based on their recent message history. Designed to drive an
/// "auto-fill category" button in the whitelist add/edit UI, and to
/// power batch suggestions when the user opens settings for the first
/// time.
///
/// Pure service. Reads its config from `loadAIConfig()` so
/// it tracks whatever model the user has set.
actor AIWhitelistCategorizer {
    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        config: AIConfig,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "whitelist_categorizer_v1"
    ) {
        self.store = store
        var inflated = config
        inflated.maxTokens = 384
        inflated.temperature = 0.15
        self.config = inflated
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Output of one categorization call.
    struct Suggestion: Decodable {
        let category: String          // "work" | "life" | "other"
        let confidence: Double
        let reason: String
        let signalKeywords: [String]
        let isGroup: Bool
        let shouldWhitelist: Bool

        enum CodingKeys: String, CodingKey {
            case category
            case confidence
            case reason
            case signalKeywords = "signal_keywords"
            case isGroup = "is_group"
            case shouldWhitelist = "should_whitelist"
        }

        /// Map the AI's string category back to the strongly-typed
        /// `WhitelistCategory` for use with HUDStore.addToWhitelist.
        var whitelistCategory: WhitelistCategory {
            switch category.lowercased() {
            case "work": return .work
            case "life": return .life
            default:     return .other
            }
        }
    }

    /// Input bundle. `messages` should be most-recent-last (chronological).
    struct Input {
        let contactName: String
        let isGroup: Bool
        let messages: [(sender: String, body: String)]
    }

    func categorize(_ input: Input) async -> Suggestion? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIWhitelistCategorizer: prompt load failed: \(error)")
            return nil
        }

        let formattedMessages = input.messages
            .map { "[\(clean($0.sender))] \(clean($0.body))" }
            .joined(separator: "\n")

        let userPrompt = template
            .replacingOccurrences(of: "{contact_name}", with: clean(input.contactName))
            .replacingOccurrences(of: "{is_group}", with: input.isGroup ? "true" : "false")
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

    // MARK: - Batch categorization

    struct BatchItem {
        let index: Int
        let contactName: String
        let isGroup: Bool
        let recentCount: Int
        let messages: [(sender: String, body: String)]
    }

    struct BatchResult: Decodable {
        let index: Int
        let category: String
        let shouldWhitelist: Bool
        let reason: String

        enum CodingKeys: String, CodingKey {
            case index, category, reason
            case shouldWhitelist = "should_whitelist"
        }
    }

    func categorizeBatch(_ items: [BatchItem]) async -> [BatchResult] {
        guard !items.isEmpty else { return [] }

        let template: String
        do {
            template = try promptLoader.load(version: "whitelist_batch_v1")
        } catch {
            print("[WCHUD] AIWhitelistCategorizer: batch prompt load failed: \(error)")
            return []
        }

        let candidatesText = items.map { item in
            let msgs = item.messages.prefix(5)
                .map { "[\(clean($0.sender))] \(clean($0.body))" }
                .joined(separator: "\n")
            let groupLabel = item.isGroup ? "群聊" : "个人"
            return """
            \(item.index). \(clean(item.contactName)) (\(groupLabel), 近45天\(item.recentCount)条)
            最近消息:
            \(msgs)
            """
        }.joined(separator: "\n---\n")

        let userPrompt = template
            .replacingOccurrences(of: "{candidates}", with: candidatesText)

        let response = await call(userPrompt)
        guard !response.text.isEmpty else { return [] }
        return parseBatch(response.text)
    }

    private func parseBatch(_ raw: String) -> [BatchResult] {
        var cleaned = raw
        if let fenceRange = cleaned.range(of: "```") {
            cleaned = String(cleaned[fenceRange.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let endFence = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<endFence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("[") {
            if let lo = cleaned.firstIndex(of: "["), let hi = cleaned.lastIndex(of: "]") {
                cleaned = String(cleaned[lo...hi])
            }
        }
        guard let data = cleaned.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([BatchResult].self, from: data)) ?? []
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "whitelist:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "白名单扫描")
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
                ["role": "system", "content": "你是一个联系人分类助手，严格按要求输出 JSON。"],
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

    private func parse(_ raw: String) -> Suggestion? {
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
        return try? JSONDecoder().decode(Suggestion.self, from: data)
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .ranker,
            model: config.model,
            promptVersion: promptVersion,
            inputText: "[contact:\(input.contactName)|n=\(input.messages.count)|group:\(input.isGroup)]",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIWhitelistCategorizer: failed to write audit: \(error)")
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
