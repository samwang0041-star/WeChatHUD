import Foundation

/// Analyzes WeChat chat messages to produce structured summaries for groups
/// and private chats. Uses the AI service with dedicated prompt templates.
///
/// Two entry points:
/// - `analyzeGroup(...)` → `(GroupAnalysis?, error)`
/// - `analyzePrivate(...)` → `(PrivateAnalysis?, error)`
///
/// All AI calls go through `AIAnalysisPipeline` for unified retry, parsing, and audit.
actor ChatAnalyzer {

    // MARK: - Result types

    struct GroupAnalysis: Codable {
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

    struct PrivateAnalysis: Codable {
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
    private let pipeline: AIAnalysisPipeline
    private let promptLoader: PromptLoader

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.pipeline = AIAnalysisPipeline(aiService: aiService, store: store)
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

        let readableMessages = messages.filter {
            MessageHelpers.isReadableAIContent($0.text, allowMediaPlaceholder: false)
        }
        guard !readableMessages.isEmpty else {
            return (Self.noReadableGroupAnalysis(), nil)
        }

        let formatted = formatMessages(
            readableMessages,
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

        print("[WCHUD] ChatAnalyzer: group analysis starting for \(chatName), \(readableMessages.count)/\(messages.count) readable messages")

        let result = await pipeline.execute(
            prompt: userPrompt,
            configuration: .init(
                systemPrompt: "你是一个消息分析助手，严格按要求输出 JSON。",
                options: CompleteOptions(timeout: 120, temperature: 0.2, maxTokens: 4096, responseFormatJSON: true),
                auditRole: .chatAnalyzer,
                promptVersion: "group_analysis_v1",
                inputSummary: "[\(chatName)] group analysis",
                trackLabel: "聊天分析"
            ),
            decodeAs: GroupAnalysis.self
        )

        guard let (parsed, _) = result else {
            print("[WCHUD] ChatAnalyzer: group analysis failed for \(chatName)")
            return (nil, "AI 返回空内容或解析失败")
        }

        print("[WCHUD] ChatAnalyzer: group analysis success for \(chatName)")
        return (parsed, nil)
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

        let readableMessages = messages.filter {
            MessageHelpers.isReadableAIContent($0.text, allowMediaPlaceholder: false)
        }
        guard !readableMessages.isEmpty else {
            return (Self.noReadablePrivateAnalysis(), nil)
        }

        let formatted = formatMessages(
            readableMessages,
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

        let result = await pipeline.execute(
            prompt: userPrompt,
            configuration: .init(
                systemPrompt: "你是一个消息分析助手，严格按要求输出 JSON。",
                options: CompleteOptions(timeout: 120, temperature: 0.2, maxTokens: 4096, responseFormatJSON: true),
                auditRole: .chatAnalyzer,
                promptVersion: "private_analysis_v1",
                inputSummary: "[\(contactName)] private analysis",
                trackLabel: "聊天分析"
            ),
            decodeAs: PrivateAnalysis.self
        )

        guard let (parsed, _) = result else {
            return (nil, "AI 返回空内容或解析失败")
        }

        return (parsed, nil)
    }

    // MARK: - Message formatting

    private static func noReadableGroupAnalysis() -> GroupAnalysis {
        GroupAnalysis(
            topics: "暂无可读内容",
            decisions: nil,
            my_action_items: nil,
            key_speakers: nil,
            status: "concluded",
            one_liner: "暂无可读内容"
        )
    }

    private static func noReadablePrivateAnalysis() -> PrivateAnalysis {
        PrivateAnalysis(
            intent: "暂无可读内容",
            urgency: "normal",
            urgency_reason: "",
            mood: "neutral",
            mood_evidence: "",
            context: nil,
            one_liner: "暂无可读内容"
        )
    }

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
            return Self.normalizedFlexibleString(trimmed)
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
            return Self.normalizedFlexibleString(trimmed)
        }
        return nil
    }

    private static func normalizedFlexibleString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sentinel = trimmed.lowercased()
        if ["null", "nil", "none", "n/a", "无", "没有", "暂无"].contains(sentinel) {
            return nil
        }
        return trimmed
    }
}
