import Foundation

/// Analyzes WeChat chat messages to produce structured summaries for groups
/// and private chats. Uses the AI service with dedicated prompt templates.
///
/// Two entry points:
/// - `analyzeGroup(...)` → `(GroupAnalysis?, error)`
/// - `analyzePrivate(...)` → `(PrivateAnalysis?, error)`
actor ChatAnalyzer {

    // MARK: - Result types

    struct GroupAnalysis: Decodable {
        let topics: String
        let decisions: String?
        let my_action_items: String?
        let key_speakers: String?
        let status: String
        let one_liner: String

        enum CodingKeys: String, CodingKey {
            case topics, decisions, my_action_items, key_speakers, status, one_liner
        }

        init(
            topics: String,
            decisions: String?,
            my_action_items: String?,
            key_speakers: String?,
            status: String,
            one_liner: String
        ) {
            self.topics = topics
            self.decisions = decisions
            self.my_action_items = my_action_items
            self.key_speakers = key_speakers
            self.status = status
            self.one_liner = one_liner
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            topics = try c.decodeFlexibleStringIfPresent(forKey: .topics) ?? ""
            decisions = try c.decodeFlexibleStringIfPresent(forKey: .decisions)
            my_action_items = try c.decodeFlexibleStringIfPresent(forKey: .my_action_items)
            key_speakers = try c.decodeFlexibleStringIfPresent(forKey: .key_speakers)
            status = try c.decodeFlexibleStringIfPresent(forKey: .status) ?? "discussing"
            one_liner = try c.decodeFlexibleStringIfPresent(forKey: .one_liner) ?? topics
        }
    }

    struct PrivateAnalysis: Decodable {
        let intent: String
        let urgency: String
        let urgency_reason: String
        let mood: String
        let mood_evidence: String
        let context: String?
        let one_liner: String

        enum CodingKeys: String, CodingKey {
            case intent, urgency, urgency_reason, mood, mood_evidence, context, one_liner
        }

        init(
            intent: String,
            urgency: String,
            urgency_reason: String,
            mood: String,
            mood_evidence: String,
            context: String?,
            one_liner: String
        ) {
            self.intent = intent
            self.urgency = urgency
            self.urgency_reason = urgency_reason
            self.mood = mood
            self.mood_evidence = mood_evidence
            self.context = context
            self.one_liner = one_liner
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            intent = try c.decodeFlexibleStringIfPresent(forKey: .intent) ?? ""
            urgency = try c.decodeFlexibleStringIfPresent(forKey: .urgency) ?? "normal"
            urgency_reason = try c.decodeFlexibleStringIfPresent(forKey: .urgency_reason) ?? ""
            mood = try c.decodeFlexibleStringIfPresent(forKey: .mood) ?? "neutral"
            mood_evidence = try c.decodeFlexibleStringIfPresent(forKey: .mood_evidence) ?? ""
            context = try c.decodeFlexibleStringIfPresent(forKey: .context)
            one_liner = try c.decodeFlexibleStringIfPresent(forKey: .one_liner) ?? intent
        }
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
    ) async -> (GroupAnalysis?, String?) {
        let template: String
        do {
            template = try promptLoader.load(version: "group_analysis_v1")
        } catch {
            print("[WCHUD] ChatAnalyzer: failed to load group_analysis_v1 prompt: \(error)")
            return (nil, "加载群聊分析 Prompt 失败: \(error.localizedDescription)")
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
        let first = await call(userPrompt)
        if first.text.isEmpty {
            print("[WCHUD] ChatAnalyzer: group analysis got empty response")
            return (nil, first.error ?? "AI 返回空内容")
        }

        if let result: GroupAnalysis = parseJSON(first.text) {
            print("[WCHUD] ChatAnalyzer: group analysis success for \(chatName)")
            return (result, nil)
        }
        print("[WCHUD] ChatAnalyzer: group analysis parse failed, retrying. Raw: \(first.text.prefix(200))")

        // Retry with stricter instruction
        let strict = userPrompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let result: GroupAnalysis = parseJSON(second.text) {
            print("[WCHUD] ChatAnalyzer: group analysis retry success")
            return (result, nil)
        }
        print("[WCHUD] ChatAnalyzer: group analysis retry also failed. Raw2: \(second.text.prefix(200))")
        return (nil, second.error ?? "AI JSON 解析失败: \(String(second.text.prefix(120)))")
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
    ) async -> (PrivateAnalysis?, String?) {
        let template: String
        do {
            template = try promptLoader.load(version: "private_analysis_v1")
        } catch {
            print("[WCHUD] ChatAnalyzer: failed to load private_analysis_v1 prompt: \(error)")
            return (nil, "加载私聊分析 Prompt 失败: \(error.localizedDescription)")
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

        let first = await call(userPrompt)
        guard !first.text.isEmpty else {
            return (nil, first.error ?? "AI 返回空内容")
        }

        if let result: PrivateAnalysis = parseJSON(first.text) {
            return (result, nil)
        }

        // Retry with stricter instruction
        let strict = userPrompt + "\n\n严格要求：只输出符合 schema 的 JSON 对象，不要任何其它文字或代码围栏。"
        let second = await call(strict)
        if let result: PrivateAnalysis = parseJSON(second.text) {
            return (result, nil)
        }
        return (nil, second.error ?? "AI JSON 解析失败: \(String(second.text.prefix(120)))")
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
            let body = AIService.sanitizeForAI(msg.text)
            return "[\(time)] \(sender): \(body)"
        }.joined(separator: "\n")
    }

    // MARK: - AI call

    private struct CallResult {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> CallResult {
        let started = Date()
        let trackID = "chatanalyzer:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "聊天分析")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是一个消息分析助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 120, temperature: 0.2, maxTokens: 4096, responseFormatJSON: true)
            )
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            await writeAudit(input: userPrompt, output: result.text, latencyMs: latencyMs, status: .ok, error: nil, model: result.model)
            return CallResult(text: result.text, error: nil, model: result.model)
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            let status: AIAuditStatus = (error as? URLError)?.code == .timedOut ? .timeout : .httpError
            print("[WCHUD] ChatAnalyzer: call failed (\(status)) latencyMs=\(latencyMs) err=\(error.localizedDescription)")
            await writeAudit(input: userPrompt, output: "", latencyMs: latencyMs, status: status, error: error.localizedDescription, model: nil)
            return CallResult(text: "", error: error.localizedDescription, model: nil)
        }
    }

    private func writeAudit(input: String, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
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
        AIJSONExtractor.decodeFirstObject(from: raw, as: T.self)
    }

}

private struct FlexibleStringAtom: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = String(i)
        } else if let d = try? c.decode(Double.self) {
            value = String(d)
        } else if let b = try? c.decode(Bool.self) {
            value = b ? "true" : "false"
        } else {
            value = ""
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        if !contains(key) {
            return nil
        }
        if try decodeNil(forKey: key) {
            return nil
        }
        if let value = try? decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let values = try? decode([FlexibleStringAtom].self, forKey: key) {
            let joined = values
                .map(\.value)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "；")
            return joined.isEmpty ? nil : joined
        }
        if let value = try? decode(FlexibleStringAtom.self, forKey: key) {
            let trimmed = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
