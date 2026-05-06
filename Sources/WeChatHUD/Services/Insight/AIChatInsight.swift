import CryptoKit
import Foundation

/// AI-powered chat insight analysis.
/// Analyzes individual chats and generates global briefings.
///
/// Uses `AIAnalysisPipeline` for all AI calls, retry, JSON parsing, and audit logging.
actor AIChatInsight {
    private static let analysisType = "chat_insight_v2"
    private let store: HUDStore
    private let aiService: AIService
    private let pipeline: AIAnalysisPipeline
    private let promptLoader: PromptLoader

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader()
    ) {
        self.store = store
        self.aiService = aiService
        self.pipeline = AIAnalysisPipeline(aiService: aiService, store: store)
        self.promptLoader = promptLoader
    }

    // MARK: - Single chat analysis

    /// Analyze a single chat's messages and return structured insight.
    func analyzeChat(
        chatUsername: String,
        chatName: String,
        chatType: String,  // "group" or "private"
        category: String,  // "work", "life", "other"
        selfName: String,
        selfAliases: [String] = [],
        timeRange: String,
        messages: [(sender: String, body: String, time: Int)],
        recalledMessages: [(sender: String, content: String)],
        memory: String
    ) async -> ChatInsightResult? {
        // Check cache first. The key must reflect the actual evidence, not just count,
        // otherwise same-size message windows can reuse stale analysis.
        let inputHash = Self.stableInsightInputHash(
            chatUsername: chatUsername,
            chatType: chatType,
            category: category,
            selfName: selfName,
            selfAliases: selfAliases,
            timeRange: timeRange,
            messages: messages,
            recalledMessages: recalledMessages,
            memory: memory
        )
        if let cached = store.loadAnalysisCache(
            chatUsername: chatUsername,
            analysisType: Self.analysisType,
            inputHash: inputHash
        ) {
            return parseAndNormalize(cached, selfAliases: selfAliases, selfName: selfName)
        }

        // Load and fill prompt template
        let template: String
        do {
            template = try promptLoader.load(version: "chat_insight_v1")
        } catch {
            print("[ChatInsight] Failed to load prompt template: \(error)")
            return nil
        }

        let prompt = buildPrompt(
            template: template,
            chatName: chatName,
            chatType: chatType,
            category: category,
            selfName: selfName,
            selfAliases: selfAliases,
            timeRange: timeRange,
            messages: messages,
            recalledMessages: recalledMessages,
            memory: memory
        )

        let result = await pipeline.execute(
            prompt: prompt,
            configuration: .init(
                options: CompleteOptions(timeout: 60, temperature: 0.15, maxTokens: 1200, responseFormatJSON: true),
                auditRole: .contextAnalyzer,
                promptVersion: "chat_insight_v1",
                inputSummary: "[\(chatUsername)] \(prompt.prefix(100))",
                trackLabel: "对话洞察"
            ),
            decodeAs: ChatInsightResult.self
        )

        guard let (parsed, _) = result else {
            return nil
        }

        let normalized = normalizeSelfReferences(parsed, selfAliases: selfAliases, selfName: selfName)

        // Write cache
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let cacheData = try? encoder.encode(normalized),
           let cacheText = String(data: cacheData, encoding: .utf8) {
            try? store.writeAnalysisCache(
                chatUsername: chatUsername,
                analysisType: Self.analysisType,
                inputHash: inputHash,
                result: cacheText,
                ttlHours: 2
            )
        }

        return normalized
    }

    // MARK: - Global briefing

    /// Generate a global briefing from all per-chat insights.
    func generateGlobalBriefing(
        selfName: String,
        date: String,
        chatInsights: [(chatName: String, result: ChatInsightResult)],
        globalStats: BriefingStats
    ) async -> GlobalBriefing? {
        let template: String
        do {
            template = try promptLoader.load(version: "chat_insight_global_v1")
        } catch {
            print("[ChatInsight] Failed to load global prompt template: \(error)")
            return nil
        }

        // Serialize chat insights to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let insightsJSON: String
        do {
            let data = try encoder.encode(chatInsights.map { $0.result })
            insightsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            insightsJSON = "[]"
        }

        let statsJSON: String
        do {
            let data = try encoder.encode(globalStats)
            statsJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            statsJSON = "{}"
        }

        let prompt = template
            .replacingOccurrences(of: "{self_name}", with: selfName)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{chat_insights}", with: insightsJSON)
            .replacingOccurrences(of: "{global_stats}", with: statsJSON)

        let result = await pipeline.executeRaw(
            prompt: prompt,
            configuration: .init(
                options: CompleteOptions(timeout: 60, temperature: 0.15, maxTokens: 1200, responseFormatJSON: true),
                auditRole: .briefer,
                promptVersion: "chat_insight_global_v1",
                inputSummary: "[global briefing] \(prompt.prefix(100))",
                trackLabel: "全局简报",
                enableRetry: false
            )
        )

        guard let (text, _) = result else { return nil }
        return AIJSONExtractor.decodeFirstObject(from: text, as: GlobalBriefing.self)
    }

    // MARK: - Prompt building

    private func buildPrompt(
        template: String,
        chatName: String,
        chatType: String,
        category: String,
        selfName: String,
        selfAliases: [String],
        timeRange: String,
        messages: [(sender: String, body: String, time: Int)],
        recalledMessages: [(sender: String, content: String)],
        memory: String
    ) -> String {
        let formattedMessages = messages.enumerated().map { index, message in
            "[m\(index + 1)][\(message.time)][\(message.sender)] \(message.body)"
        }.joined(separator: "\n")
        let formattedRecalled = recalledMessages.isEmpty
            ? "无"
            : recalledMessages.map { "[\($0.sender)] \($0.content)" }.joined(separator: "\n")

        return template
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{chat_type}", with: chatType)
            .replacingOccurrences(of: "{category}", with: category)
            .replacingOccurrences(of: "{self_name}", with: selfName)
            .replacingOccurrences(of: "{self_aliases}", with: selfAliases.isEmpty ? selfName : selfAliases.joined(separator: " / "))
            .replacingOccurrences(of: "{time_range}", with: timeRange)
            .replacingOccurrences(of: "{messages}", with: formattedMessages)
            .replacingOccurrences(of: "{recalled_messages}", with: formattedRecalled)
            .replacingOccurrences(of: "{memory}", with: memory.isEmpty ? "无" : memory)
    }

    // MARK: - Parsing & normalization

    private func parseAndNormalize(
        _ raw: String,
        selfAliases: [String],
        selfName: String
    ) -> ChatInsightResult? {
        guard let result = AIJSONExtractor.decodeFirstObject(from: raw, as: ChatInsightResult.self) else {
            return nil
        }
        return normalizeSelfReferences(result, selfAliases: selfAliases, selfName: selfName)
    }

    // MARK: - Helpers

    static func stableInsightInputHash(
        chatUsername: String,
        chatType: String,
        category: String,
        selfName: String,
        selfAliases: [String],
        timeRange: String,
        messages: [(sender: String, body: String, time: Int)],
        recalledMessages: [(sender: String, content: String)],
        memory: String
    ) -> String {
        var parts: [String] = [
            "prompt=chat_insight_v2",
            "chat=\(chatUsername)",
            "type=\(chatType)",
            "category=\(category)",
            "self=\(selfName)",
            "aliases=\(selfAliases.joined(separator: "|"))",
            "range=\(timeRange)",
            "memory=\(memory)"
        ]

        for message in messages {
            parts.append("m|\(message.time)|\(message.sender)|\(message.body)")
        }
        for recalled in recalledMessages {
            parts.append("r|\(recalled.sender)|\(recalled.content)")
        }

        let data = Data(parts.joined(separator: "\u{1f}").utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizeSelfReferences(
        _ result: ChatInsightResult,
        selfAliases: [String],
        selfName: String
    ) -> ChatInsightResult {
        let aliases = Self.normalizedSelfAliases(selfAliases + [selfName])
        guard !aliases.isEmpty else { return result }

        func s(_ value: String) -> String {
            Self.replaceSelfAliases(in: value, aliases: aliases)
        }
        func so(_ value: String?) -> String? {
            value.map(s)
        }
        func dict(_ value: [String: String]?) -> [String: String]? {
            value.map { source in
                source.reduce(into: [String: String]()) { result, item in
                    result[s(item.key)] = s(item.value)
                }
            }
        }

        return ChatInsightResult(
            headline: s(result.headline),
            topics: result.topics.map { topic in
                TopicInsight(
                    name: s(topic.name),
                    messageCount: topic.messageCount,
                    participantCount: topic.participantCount,
                    summary: s(topic.summary),
                    status: s(topic.status),
                    myInvolvement: so(topic.myInvolvement),
                    crossChats: topic.crossChats?.map(s)
                )
            },
            decisions: result.decisions.map(s),
            actionItems: result.actionItems.map {
                InsightActionItem(what: s($0.what), who: s($0.who), deadline: so($0.deadline))
            },
            mentionsMe: result.mentionsMe,
            waitingForMe: result.waitingForMe.map {
                WaitingItem(source: s($0.source), what: s($0.what), waitingHours: $0.waitingHours)
            },
            myCommitments: result.myCommitments.map(s),
            needsMyAttention: result.needsMyAttention,
            overallMood: s(result.overallMood),
            signalNoiseRatio: result.signalNoiseRatio,
            decisionEfficiency: s(result.decisionEfficiency),
            importanceToMe: ImportanceLevel(level: s(result.importanceToMe.level), reason: s(result.importanceToMe.reason)),
            crossChatTopics: result.crossChatTopics?.map(s),
            insight: s(result.insight),
            suggestion: s(result.suggestion)
        )
    }

    private static func normalizedSelfAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "我" }
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0).inserted }
    }

    private static func replaceSelfAliases(in value: String, aliases: [String]) -> String {
        var output = value
        for alias in aliases {
            output = output.replacingOccurrences(of: "我（\(alias)）", with: "我")
            output = output.replacingOccurrences(of: "@\(alias)", with: "@我")
            output = output.replacingOccurrences(of: alias, with: "我")
        }
        output = output.replacingOccurrences(of: "我（我）", with: "我")
        output = output.replacingOccurrences(of: "我/我", with: "我")
        return output
    }
}
