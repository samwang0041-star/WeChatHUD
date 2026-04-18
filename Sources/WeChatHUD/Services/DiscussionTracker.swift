import Foundation

/// Extract bidirectional work items, decisions, information points,
/// and open questions from a conversation window. The CommitmentTracker
/// sibling only looks at *your outgoing* messages to catch promises you
/// made — this actor looks at *both sides* so the user doesn't lose
/// things they discussed.
///
/// Primary user-facing output: the "工作台" tab (discussion items list)
/// and the weekly report that slices items by relationship hierarchy
/// (上级派给我 / 我派给下级).
actor DiscussionTracker {
    private let store: HUDStore
    private let promptLoader: PromptLoader
    private let promptVersion = "discussion_v1"

    init(store: HUDStore, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.promptLoader = promptLoader
    }

    struct ExtractedItem {
        let kind: DiscussionItemKind
        let owner: DiscussionItemOwner
        let content: String
        let detail: String?
        let dueAt: Date?
        let confidence: Double
    }

    /// Run extraction for one chat over the given messages (chronological
    /// or reverse — we normalize). Persists new items via the store.
    /// Returns the number of freshly-inserted items.
    @discardableResult
    func extract(
        chatUsername: String,
        chatName: String,
        messages: [MessageInfo],
        myUsername: String,
        myDisplayName: String,
        mySelfNames: Set<String>,
        config: AIConfig
    ) async -> Int {
        guard !config.baseURL.isEmpty, !messages.isEmpty else { return 0 }

        // Skip if we've already extracted recently enough — don't want
        // to re-call the model on every 10s scan for chats that
        // haven't had new messages. The latest source_timestamp we
        // persisted is the watermark.
        let watermark = store.latestDiscussionSourceTimestamp(chatUsername: chatUsername)
        let fresh = messages.filter { $0.createTime > watermark }
        // Even when nothing is technically new we still want a window
        // of context, so widen to the full input when fresh is empty
        // but the overall conversation has grown. However if literally
        // nothing is new, bail out fast.
        guard !fresh.isEmpty else { return 0 }

        // Load existing items so the AI can dedupe against known
        // content (prompt-level dedupe in addition to the SQL UNIQUE).
        let existing = store.loadDiscussionItems(
            chatUsername: chatUsername,
            status: nil,
            sinceTimestamp: max(0, watermark - 7 * 86400), // last week
            limit: 20
        )

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] DiscussionTracker: prompt load failed: \(error)")
            return 0
        }

        // Build a compact conversation transcript for the prompt. We
        // tag each line with "我" or the actual sender so the model
        // can assign ownership correctly — critical for the weekly
        // report's "上级派给我 / 我派给下级" slicing.
        let lines = messages.suffix(40).map { msg -> String in
            let isSelf = MessageHelpers.isFromSelf(
                msg, chatUsername: chatUsername,
                myUsername: myUsername, myDisplayName: myDisplayName,
                mySelfNames: mySelfNames
            )
            let speaker = isSelf ? "我" : (msg.senderName.isEmpty ? "对方" : msg.senderName)
            let ts = MessageInfo.formatRelative(msg.createTime)
            return "[\(ts)] \(speaker): \(msg.text)"
        }.joined(separator: "\n")

        let knownList = existing.map { "- \($0.kind.label): \($0.content)" }.joined(separator: "\n")
        let prompt = template
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{messages}", with: lines)
            .replacingOccurrences(of: "{known_items}", with: knownList.isEmpty ? "（暂无）" : knownList)

        let started = Date()
        let body = await callModel(prompt: prompt, config: config)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        guard let body = body else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: config.model, promptVersion: promptVersion,
                inputText: "chat=\(chatName), msgs=\(messages.count)",
                outputText: "", latencyMs: latency,
                status: .httpError, errorMessage: "no response"
            ))
            return 0
        }

        var items = parseItems(body)
        // One strict-retry, same pattern as CommitmentTracker / Classifier
        if items == nil {
            let strictPrompt = prompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要 markdown 代码块，不要任何解释性文字。"
            if let retryBody = await callModel(prompt: strictPrompt, config: config) {
                items = parseItems(retryBody)
            }
        }
        guard let parsed = items else {
            try? store.writeAIAudit(AIAuditEntry(
                id: 0, ts: Date(), role: .commitmentTracker,
                model: config.model, promptVersion: promptVersion,
                inputText: "chat=\(chatName)", outputText: body,
                latencyMs: latency, status: .parseError,
                errorMessage: "JSON parse failed after strict retry"
            ))
            return 0
        }

        // Persist. Each item is keyed by (chat, anchor_msg_uid, content)
        // so re-runs don't produce duplicates; the UNIQUE constraint
        // short-circuits silently in that case.
        let anchor = fresh.last?.id ?? messages.first?.id ?? ""
        let anchorTs = fresh.last?.createTime ?? messages.first?.createTime ?? Int(Date().timeIntervalSince1970)
        var inserted = 0
        for item in parsed {
            let did = (try? store.insertDiscussionItem(
                chatUsername: chatUsername,
                chatName: chatName,
                kind: item.kind,
                owner: item.owner,
                content: item.content,
                detail: item.detail,
                anchorMsgUID: anchor,
                sourceTimestamp: anchorTs,
                dueAt: item.dueAt,
                confidence: item.confidence,
                promptVersion: promptVersion
            )) ?? false
            if did { inserted += 1 }
        }

        try? store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .commitmentTracker,
            model: config.model, promptVersion: promptVersion,
            inputText: "chat=\(chatName), msgs=\(fresh.count)",
            outputText: "inserted=\(inserted)",
            latencyMs: latency, status: .ok, errorMessage: nil
        ))
        return inserted
    }

    // MARK: - Parsing

    private func parseItems(_ raw: String) -> [ExtractedItem]? {
        let cleaned = Self.cleanJSON(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let arr = root["items"] as? [[String: Any]] else {
            return nil
        }
        var out: [ExtractedItem] = []
        for row in arr {
            guard let kindStr = row["kind"] as? String,
                  let kind = DiscussionItemKind(rawValue: kindStr),
                  let ownerStr = row["owner"] as? String,
                  let owner = DiscussionItemOwner(rawValue: ownerStr),
                  let content = row["content"] as? String,
                  !content.isEmpty else { continue }
            let detail = row["detail"] as? String
            let deadline = (row["due"] as? String).flatMap { MessageHelpers.resolveDeadline($0) }
            let confidence = (row["confidence"] as? Double) ?? 0.6
            out.append(ExtractedItem(
                kind: kind, owner: owner,
                content: content, detail: detail?.isEmpty == true ? nil : detail,
                dueAt: deadline, confidence: confidence
            ))
        }
        return out
    }

    private static func cleanJSON(_ text: String) -> String {
        var s = text
        if let fence = s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if s.hasPrefix("json") { s = String(s.dropFirst(4)) }
            if let endFence = s.range(of: "```") {
                s = String(s[..<endFence.lowerBound])
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("{") {
            if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}") {
                s = String(s[lo...hi])
            }
        }
        return s
    }

    // MARK: - HTTP

    private func callModel(prompt: String, config: AIConfig) async -> String? {
        let trackID = "discussion:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "事项提取")
        defer { AIActivityTracker.shared.end(trackID) }
        let base = normalizeURL(config.baseURL)
        guard let url = URL(string: "\(base)/chat/completions") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "你是对话事项提取助手。不要进入 thinking 模式。只输出 JSON。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": 800,
            "enable_thinking": false
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    private func normalizeURL(_ url: String) -> String {
        var u = url
        if !u.contains("://") { u = "http://\(u)" }
        while u.hasSuffix("/") { u.removeLast() }
        if !u.hasSuffix("/v1") { u += "/v1" }
        return u
    }
}
