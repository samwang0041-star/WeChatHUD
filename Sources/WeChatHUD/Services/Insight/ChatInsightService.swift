import Foundation

/// Prepares data and runs AI chat insight analysis for a single whitelist entry.
/// Extracted from `InsightCoordinator` to separate data preparation from scheduling.
actor ChatInsightService {
    private let reader: WeChatReader
    private let store: HUDStore
    private let chatInsight: AIChatInsight
    static let analysisMessageLimit = 500

    init(reader: WeChatReader, store: HUDStore, aiService: AIService) {
        self.reader = reader
        self.store = store
        self.chatInsight = AIChatInsight(store: store, aiService: aiService)
    }

    /// Analyze a single whitelist entry for a specific date.
    func analyzeEntry(
        _ entry: WhitelistEntry,
        date: Date,
        selfUsername: String,
        selfDisplayName: String
    ) async -> ChatInsightResult? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

        guard let messages = try? reader.getMessages(
            chatUsername: entry.id, limit: Self.analysisMessageLimit + 1, afterCursor: nil,
            startTime: Int(dayStart.timeIntervalSince1970), endTime: Int(dayEnd.timeIntervalSince1970)
        ) else { return nil }
        let isTruncated = messages.count > Self.analysisMessageLimit
        let dayMessages = messages.prefix(Self.analysisMessageLimit).filter {
            let msgDate = Date(timeIntervalSince1970: Double($0.createTime))
            return msgDate >= dayStart && msgDate < dayEnd
                && MessageHelpers.isReadableAIContent($0.text, allowMediaPlaceholder: false)
        }
        guard !dayMessages.isEmpty else { return nil }

        let selfAliases = buildSelfAliases(username: selfUsername, displayName: selfDisplayName)
        let selfLabel = buildSelfLabel(aliases: selfAliases, fallback: selfDisplayName.isEmpty ? selfUsername : selfDisplayName)

        let formatted = dayMessages
            .sorted {
                $0.createTime == $1.createTime ? $0.localId < $1.localId : $0.createTime < $1.createTime
            }
            .map { message in
                let isSelf = MessageHelpers.isFromSelf(
                    message,
                    chatUsername: entry.id,
                    myUsername: selfUsername,
                    myDisplayName: selfDisplayName,
                    mySelfNames: reader.mySelfNames
                )
                let sender = isSelf
                    ? "我（\(selfLabel)）"
                    : (message.senderName.isEmpty ? message.senderUsername : message.senderName)
                return (sender: sender, body: reader.normalizeContactMentions(in: message.text), time: message.createTime)
            }

        let memory = Self.memoryForAnalysis(
            store.loadConversationMemory(chatUsername: entry.id), dayStart: dayStart, dayEnd: dayEnd
        )
        let memoryStr = memory?.formatForPrompt() ?? ""
        var recentContext: String
        if let memory {
            var parts: [String] = []
            if !memory.keyTopics.isEmpty {
                parts.append("过去7天话题: \(memory.keyTopics.joined(separator: "、"))")
            }
            if !memory.pendingItems.isEmpty {
                parts.append("未完成事项: \(memory.pendingItems.joined(separator: "、"))")
            }
            if !memory.sharedContext.isEmpty {
                parts.append("共同背景: \(memory.sharedContext.joined(separator: "、"))")
            }
            recentContext = parts.joined(separator: "\n")
        } else {
            recentContext = ""
        }

        recentContext += "\n" + Self.coverageNotice(analyzedCount: dayMessages.count, isTruncated: isTruncated)
        if memory == nil {
            recentContext += "\n没有符合该日期的历史记忆快照。只分析给定消息，不推断跨日关系变化。"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "zh_CN")
        let dateLabel = dateFormatter.string(from: date)

        guard let result = await chatInsight.analyzeChat(
            chatUsername: entry.id,
            chatName: entry.displayName,
            chatType: entry.isGroup ? "group" : "private",
            category: entry.category.rawValue,
            selfName: selfLabel,
            selfAliases: selfAliases,
            timeRange: dateLabel,
            messages: formatted,
            recalledMessages: [],
            memory: memoryStr,
            recentContext: recentContext
        ) else { return nil }
        return Self.addingCoverageNotice(to: result, analyzedCount: dayMessages.count, isTruncated: isTruncated)
    }

    /// Rolling memory is a current snapshot, not historical evidence. Exclude
    /// snapshots newer than the selected day or older than its seven-day window.
    static func memoryForAnalysis(_ memory: ConversationMemory?, dayStart: Date, dayEnd: Date) -> ConversationMemory? {
        guard let memory,
              memory.lastUpdated < dayEnd,
              memory.lastUpdated >= dayStart.addingTimeInterval(-7 * 86400) else { return nil }
        return memory
    }

    static func coverageNotice(analyzedCount: Int, isTruncated: Bool) -> String {
        isTruncated
            ? "分析范围：该日消息超过 \(analysisMessageLimit) 条，本次仅读取最后 \(analysisMessageLimit) 条，其中 \(analyzedCount) 条可分析文本；更早内容未覆盖，不能据此判断全天没有遗漏。"
            : "分析范围：已读取该日全部消息，其中 \(analyzedCount) 条可分析文本；图片、语音等媒体内容未纳入语义分析。"
    }

    static func addingCoverageNotice(to result: ChatInsightResult, analyzedCount: Int, isTruncated: Bool) -> ChatInsightResult {
        let notice = coverageNotice(analyzedCount: analyzedCount, isTruncated: isTruncated)
        return ChatInsightResult(
            headline: result.headline, topics: result.topics, decisions: result.decisions,
            actionItems: result.actionItems, mentionsMe: result.mentionsMe, waitingForMe: result.waitingForMe,
            myCommitments: result.myCommitments, needsMyAttention: result.needsMyAttention,
            overallMood: result.overallMood, signalNoiseRatio: result.signalNoiseRatio,
            decisionEfficiency: result.decisionEfficiency, importanceToMe: result.importanceToMe,
            crossChatTopics: result.crossChatTopics, insight: notice + "\n\n" + result.insight,
            suggestion: result.suggestion
        )
    }

    /// Generate a global briefing from all per-chat insights.
    func generateGlobalBriefing(
        selfName: String,
        date: String,
        chatInsights: [(chatName: String, result: ChatInsightResult)],
        globalStats: BriefingStats
    ) async -> GlobalBriefing? {
        await chatInsight.generateGlobalBriefing(
            selfName: selfName,
            date: date,
            chatInsights: chatInsights,
            globalStats: globalStats
        )
    }

    // MARK: - Helpers

    private func buildSelfAliases(username: String, displayName: String) -> [String] {
        var aliases: [String] = []
        var seen = Set<String>()

        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            aliases.append(trimmed)
            seen.insert(trimmed)
        }

        add(username)
        add(displayName)
        for alias in reader.mySelfNames.sorted() {
            add(alias)
        }

        return aliases
    }

    private func buildSelfLabel(aliases: [String], fallback: String) -> String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return aliases.first ?? "我"
    }
}
