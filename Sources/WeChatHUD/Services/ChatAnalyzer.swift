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
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    // MARK: - Public API

    /// Analyze a group chat. `messages` come newest-first from the reader.
    func analyzeGroup(
        chatUsername: String,
        chatName: String,
        messages: [MessageInfo],
        myUsername: String,
        myName: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
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
            myName: myName,
            myDisplayName: myDisplayName,
            mySelfNames: mySelfNames
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
        myName: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
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
            myName: myName,
            myDisplayName: myDisplayName,
            mySelfNames: mySelfNames
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
        myName: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) -> String {
        let chronological = messages.reversed()
        return chronological.map { msg in
            let isSelf = MessageHelpers.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
            let sender = isSelf
                ? (myName.isEmpty ? "我" : myName)
                : (msg.senderName.isEmpty ? msg.senderUsername : msg.senderName)
            let time = MessageInfo.formatRelative(msg.createTime)
            let body = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(time)] \(sender): \(body)"
        }.joined(separator: "\n")
    }

    // MARK: - AI call

    private func call(_ userPrompt: String) async -> String {
        let started = Date()
        let trackID = "chatanalyzer:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "聊天分析")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let content = try await aiService.complete(
                system: "你是一个消息分析助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 512)
            )
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            await writeAudit(input: userPrompt, output: content, latencyMs: latencyMs, status: .ok, error: nil)
            return content
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            let status: AIAuditStatus = (error as? URLError)?.code == .timedOut ? .timeout : .httpError
            await writeAudit(input: userPrompt, output: "", latencyMs: latencyMs, status: status, error: error.localizedDescription)
            return ""
        }
    }

    private func writeAudit(input: String, output: String, latencyMs: Int, status: AIAuditStatus, error: String?) async {
        let model = await aiService.currentConfig().model
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .chatAnalyzer,
            model: model,
            promptVersion: "chat_analyzer",
            inputText: String(input.prefix(200)),
            outputText: String(output.prefix(400)),
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] ChatAnalyzer: audit write failed: \(error)")
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

}
