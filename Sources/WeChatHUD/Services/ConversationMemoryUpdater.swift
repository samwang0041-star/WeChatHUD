import Foundation

/// Shared conversation-memory updater — extracted from ChatMonitor
/// (post-scan) and AutopilotService (post-send refresh) to eliminate
/// duplicate inline logic. Both callers now route through this actor.
actor ConversationMemoryUpdater {
    private let reader: WeChatReader
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader

    init(
        reader: WeChatReader,
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader()
    ) {
        self.reader = reader
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    /// Update conversation memories for the top `maxChats` whitelist
    /// entries whose memory is older than `stalenessSeconds`.
    /// Called after each scan and after autopilot sends.
    func updateStaleMemories(maxChats: Int = 5, stalenessSeconds: TimeInterval = 1800) async {
        guard await aiService.isConfigured() else { return }
        let whitelist = store.getWhitelist()
        for entry in whitelist.prefix(maxChats) {
            await updateMemoryIfNeeded(chatUsername: entry.id, chatName: entry.displayName, stalenessSeconds: stalenessSeconds)
        }
    }

    /// Update memory for a single chat if stale. Used by AutopilotService
    /// after sends to refresh just the affected conversation.
    func updateMemoryIfNeeded(
        chatUsername: String,
        chatName: String,
        stalenessSeconds: TimeInterval = 1800
    ) async {
        // Rate limit: skip if updated recently
        if let existing = store.loadConversationMemory(chatUsername: chatUsername),
           Date().timeIntervalSince(existing.lastUpdated) < stalenessSeconds {
            return
        }

        let messages = (try? reader.getMessages(chatUsername: chatUsername, limit: 30)) ?? []
        guard !messages.isEmpty else { return }

        let oldMemory = store.loadConversationMemory(chatUsername: chatUsername)
        let oldSummary = oldMemory?.summary ?? ""

        let msgText = messages.prefix(20).map {
            "\($0.senderName): \(AIService.sanitizeForAI($0.text))"
        }.joined(separator: "\n")

        let oldShared = oldMemory?.sharedContext ?? []
        let oldComm = oldMemory?.communicationNotes ?? []

        let memoryTemplate = (try? promptLoader.load(version: "conversation_memory_v1")) ?? ""
        let prompt = memoryTemplate
            .replacingOccurrences(of: "{chat_name}", with: chatName)
            .replacingOccurrences(of: "{old_summary}", with: oldSummary.isEmpty ? "（首次生成）" : oldSummary)
            .replacingOccurrences(of: "{old_shared}", with: oldShared.isEmpty ? "（无）" : oldShared.joined(separator: "、"))
            .replacingOccurrences(of: "{old_notes}", with: oldComm.isEmpty ? "（无）" : oldComm.joined(separator: "、"))
            .replacingOccurrences(of: "{recent_messages}", with: msgText)

        guard let response = try? await aiService.complete(
            system: "你是对话摘要助手。只输出JSON。",
            user: prompt,
            options: CompleteOptions(timeout: 30, temperature: 0.2, maxTokens: 256, responseFormatJSON: true)
        ) else { return }

        guard let jsonText = AIJSONExtractor.firstObjectString(from: response),
              let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let memory = ConversationMemory(
            chatUsername: chatUsername,
            summary: json["summary"] as? String ?? oldSummary,
            keyTopics: Array((json["key_topics"] as? [String] ?? oldMemory?.keyTopics ?? []).prefix(10)),
            pendingItems: Array((json["pending_items"] as? [String] ?? oldMemory?.pendingItems ?? []).prefix(5)),
            sharedContext: Array((json["shared_context"] as? [String] ?? oldShared).prefix(5)),
            communicationNotes: Array((json["communication_notes"] as? [String] ?? oldComm).prefix(5)),
            moodTrend: json["mood_trend"] as? String ?? oldMemory?.moodTrend ?? "",
            conversationPhase: json["conversation_phase"] as? String ?? oldMemory?.conversationPhase ?? "",
            stance: json["stance"] as? String ?? oldMemory?.stance ?? "",
            messageCount7d: messages.count,
            lastUpdated: Date()
        )
        try? store.upsertConversationMemory(memory)
    }
}
