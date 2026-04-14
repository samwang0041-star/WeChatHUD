import Foundation

/// Analyzes WeChat chat messages to produce structured summaries for groups
/// and private chats. Uses the AI service with dedicated prompt templates.
///
/// Two entry points:
/// - `analyzeGroup(...)` → `GroupAnalysis?`
/// - `analyzePrivate(...)` → `PrivateAnalysis?`
actor ChatAnalyzer {

    // MARK: - Result types

    struct GroupAnalysis: Decodable {
        let topics: String
        let decisions: String?
        let my_action_items: String?
        let key_speakers: String?
        let status: String
        let one_liner: String
    }

    struct PrivateAnalysis: Decodable {
        let intent: String
        let urgency: String
        let urgency_reason: String
        let mood: String
        let mood_evidence: String
        let context: String?
        let one_liner: String
    }

    // MARK: - Dependencies

    private let store: HUDStore
    private var config: AIConfig
    private let promptLoader: PromptLoader

    init(store: HUDStore, config: AIConfig, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        var cfg = config
        cfg.maxTokens = 512
        cfg.temperature = 0.2
        self.config = cfg
        self.promptLoader = promptLoader
    }

    /// Hot-reload when the user changes AI settings.
    func updateConfig(_ newConfig: AIConfig) {
        var cfg = newConfig
        cfg.maxTokens = 512
        cfg.temperature = 0.2
        self.config = cfg
    }

    // MARK: - Public API

    /// Analyze a group chat. `messages` come newest-first from the reader.
    func analyzeGroup(
        chatUsername: String,
        chatName: String,
        messages: [MessageInfo],
        myUsername: String,
        myName: String
    ) async -> GroupAnalysis? {
        let template: String
        do {
            template = try promptLoader.load(version: "group_analysis_v1")
        } catch {
            print("[WCHUD] ChatAnalyzer: failed to load group_analysis_v1 prompt: \(error)")
            return nil
        }

        let formatted = formatMessages(
            messages,
            chatUsername: chatUsername,
            myUsername: myUsername,
            myName: myName
        )

        let userPrompt = template
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{my_name}", with: myName.isEmpty ? myUsername : myName)
            .replacingOccurrences(of: "{messages}", with: formatted)

        print("[WCHUD] ChatAnalyzer: group analysis starting for \(chatName), \(messages.count) messages")
        let raw = await call(userPrompt)
        if raw.isEmpty {
            print("[WCHUD] ChatAnalyzer: group analysis got empty response")
            return nil
        }

        if let result: GroupAnalysis = parseJSON(raw) {
            print("[WCHUD] ChatAnalyzer: group analysis success for \(chatName)")
            return result
        }
        print("[WCHUD] ChatAnalyzer: group analysis parse failed, retrying. Raw: \(raw.prefix(200))")

        // Retry with stricter instruction
        let strict = userPrompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let raw2 = await call(strict)
        if let result: GroupAnalysis = parseJSON(raw2) {
            print("[WCHUD] ChatAnalyzer: group analysis retry success")
            return result
        }
        print("[WCHUD] ChatAnalyzer: group analysis retry also failed. Raw2: \(raw2.prefix(200))")
        return nil
    }

    /// Analyze a private chat. `messages` come newest-first from the reader.
    func analyzePrivate(
        chatUsername: String,
        contactName: String,
        messages: [MessageInfo],
        myUsername: String,
        myName: String
    ) async -> PrivateAnalysis? {
        let template: String
        do {
            template = try promptLoader.load(version: "private_analysis_v1")
        } catch {
            print("[WCHUD] ChatAnalyzer: failed to load private_analysis_v1 prompt: \(error)")
            return nil
        }

        let formatted = formatMessages(
            messages,
            chatUsername: chatUsername,
            myUsername: myUsername,
            myName: myName
        )

        // Resolve relationship description from store
        let relationship: String
        if let profile = store.getRelationshipProfile(username: chatUsername) {
            var parts = [profile.relationship]
            if let note = profile.userNote, !note.isEmpty { parts.append(note) }
            relationship = parts.joined(separator: "，")
        } else {
            relationship = "未知"
        }

        let userPrompt = template
            .replacingOccurrences(of: "{contact_name}", with: contactName)
            .replacingOccurrences(of: "{relationship}", with: relationship)
            .replacingOccurrences(of: "{messages}", with: formatted)

        let raw = await call(userPrompt)
        guard !raw.isEmpty else { return nil }

        if let result: PrivateAnalysis = parseJSON(raw) {
            return result
        }

        // Retry with stricter instruction
        let strict = userPrompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let raw2 = await call(strict)
        return parseJSON(raw2)
    }

    // MARK: - Message formatting

    /// Reverse newest-first messages to chronological order, then format
    /// each as "[时间] 发送者: 消息内容".
    private func formatMessages(
        _ messages: [MessageInfo],
        chatUsername: String,
        myUsername: String,
        myName: String
    ) -> String {
        let chronological = messages.reversed()
        return chronological.map { msg in
            let isSelf = MessageHelpers.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUsername)
            let sender = isSelf
                ? (myName.isEmpty ? "我" : myName)
                : (msg.senderName.isEmpty ? msg.senderUsername : msg.senderName)
            let time = MessageInfo.formatRelative(msg.createTime)
            let body = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(time)] \(sender): \(body)"
        }.joined(separator: "\n")
    }

    // MARK: - HTTP call

    private func call(_ userPrompt: String) async -> String {
        let trackID = "chatanalyzer:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "聊天分析")
        defer { AIActivityTracker.shared.end(trackID) }
        let baseURL = normalizeURL(config.baseURL)
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            print("[WCHUD] ChatAnalyzer: invalid URL: \(config.baseURL)")
            return ""
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "你是一个消息分析助手，严格按要求输出 JSON。"],
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
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[WCHUD] ChatAnalyzer: HTTP \(code)")
                return ""
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("[WCHUD] ChatAnalyzer: could not extract content from response")
                return ""
            }
            return stripThinking(content)
        } catch {
            print("[WCHUD] ChatAnalyzer: request error: \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: - JSON parsing

    private func parseJSON<T: Decodable>(_ raw: String) -> T? {
        guard !raw.isEmpty else { return nil }
        var cleaned = raw

        // Strip markdown fences
        if let fenceRange = cleaned.range(of: "```") {
            cleaned = String(cleaned[fenceRange.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let endFence = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<endFence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON between first { and last }
        if !cleaned.hasPrefix("{") {
            if let lo = cleaned.firstIndex(of: "{"), let hi = cleaned.lastIndex(of: "}") {
                cleaned = String(cleaned[lo...hi])
            }
        }

        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
