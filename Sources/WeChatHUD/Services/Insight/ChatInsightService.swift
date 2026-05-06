import Foundation

/// Prepares data and runs AI chat insight analysis for a single whitelist entry.
/// Extracted from `InsightCoordinator` to separate data preparation from scheduling.
actor ChatInsightService {
    private let reader: WeChatReader
    private let store: HUDStore
    private let chatInsight: AIChatInsight

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

        guard let messages = try? reader.getMessages(chatUsername: entry.id, limit: 500) else { return nil }
        let dayMessages = messages.filter {
            let msgDate = Date(timeIntervalSince1970: Double($0.createTime))
            return msgDate >= dayStart && msgDate < dayEnd
                && MessageHelpers.isReadableAIContent($0.text, allowMediaPlaceholder: false)
        }
        guard !dayMessages.isEmpty else { return nil }

        let selfAliases = buildSelfAliases(username: selfUsername, displayName: selfDisplayName)
        let selfLabel = buildSelfLabel(aliases: selfAliases, fallback: selfDisplayName.isEmpty ? selfUsername : selfDisplayName)

        let formatted = dayMessages
            .sorted { $0.createTime < $1.createTime }
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

        let memory = store.loadConversationMemory(chatUsername: entry.id)
        let memoryStr = memory?.formatForPrompt() ?? ""
        let recentContext: String
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

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "zh_CN")
        let dateLabel = dateFormatter.string(from: date)

        return await chatInsight.analyzeChat(
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
