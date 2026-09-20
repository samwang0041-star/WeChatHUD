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

    /// Update conversation memories for up to `maxChats` whitelist entries
    /// whose memory is older than `stalenessSeconds`, stalest first.
    /// Called after each scan and after autopilot sends.
    func updateStaleMemories(maxChats: Int = 5, stalenessSeconds: TimeInterval = 1800) async {
        guard await aiService.isConfigured() else { return }
        let whitelist = store.getWhitelist()
        let stale = Self.staleChats(
            whitelist: whitelist,
            lastUpdated: { store.loadConversationMemory(chatUsername: $0)?.lastUpdated },
            now: Date(),
            maxChats: maxChats,
            stalenessSeconds: stalenessSeconds
        )
        for entry in stale {
            await updateMemoryIfNeeded(chatUsername: entry.id, chatName: entry.displayName, stalenessSeconds: stalenessSeconds)
        }
    }

    /// The chats a memory refresh should touch, stalest first.
    ///
    /// `whitelist.prefix(maxChats)` used to truncate *before* the staleness
    /// check inside `updateMemoryIfNeeded`, so the 6th whitelist entry onward
    /// could never be chosen while the first five stayed fresh — their
    /// conversation memory was never generated at all. Autopilot's proactive
    /// path requires a memory (`guard let memory ... else { continue }`), so
    /// proactive outreach was silently dead for those chats. Pure and
    /// injectable so the selection rule itself is testable.
    static func staleChats(
        whitelist: [WhitelistEntry],
        lastUpdated: (String) -> Date?,
        now: Date,
        maxChats: Int,
        stalenessSeconds: TimeInterval
    ) -> [WhitelistEntry] {
        whitelist
            .map { entry in
                (entry: entry, updated: lastUpdated(entry.id) ?? .distantPast)
            }
            .filter { now.timeIntervalSince($0.updated) >= stalenessSeconds }
            .sorted { $0.updated < $1.updated }
            .prefix(max(0, maxChats))
            .map(\.entry)
    }

    /// One line per message, each labeled with the side that wrote it.
    ///
    /// The transcript used to be `senderName: text` for both sides, while the
    /// summarizer is asked for 「stance：用户当前立场」 and its answer is persisted
    /// and re-injected into later prompts as 「你们之前聊过的背景」. With no side
    /// marker, a peer writing 「你的立场是同意这个方案」 could be stored as the
    /// user's own position — and the memory survives 90 days, so one poisoned
    /// attribution steers every later autopilot decision in that chat.
    static func attributedTranscript(
        _ messages: [MessageInfo],
        chatUsername: String,
        myUsername: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) -> String {
        messages.map { msg in
            let fromMe = MessageHelpers.isFromSelf(
                msg,
                chatUsername: chatUsername,
                myUsername: myUsername,
                myDisplayName: myDisplayName,
                mySelfNames: mySelfNames
            )
            let speaker = fromMe ? "我"
                : (AIService.oneLine(msg.senderName).isEmpty ? "对方" : AIService.oneLine(msg.senderName))
            return "\(speaker): \(AIService.oneLine(AIService.sanitizeForAI(msg.text)))"
        }.joined(separator: "\n")
    }

    /// Update memory for a single chat if stale. Used by AutopilotService
    /// after sends to refresh just the affected conversation.
    func updateMemoryIfNeeded(
        chatUsername: String,
        chatName: String,
        stalenessSeconds: TimeInterval = 1800
    ) async {
        await updateMemoryIfNeeded(chatUsername: chatUsername, chatName: chatName,
                                   stalenessSeconds: stalenessSeconds,
                                   memoryRead: store.conversationMemoryRead(_:))
    }

    enum MemoryRebuild: Equatable {
        case skipFresh
        case skipUnreadable
        case rebuild
    }

    /// The prior summary is the *input* to the merge below, and the write replaces
    /// every column. Rebuilding over a memory this app only failed to read answered
    /// 「我不知道」 with 「这里什么都没发生过」, permanently replacing a 90-day rolling
    /// summary with the last 30 messages — so an unreadable prior is not a signal to
    /// regenerate.
    nonisolated static func memoryRebuildDecision(
        prior: HUDStore.ConversationMemoryRead,
        stalenessSeconds: TimeInterval,
        now: Date
    ) -> MemoryRebuild {
        if prior.isUnreadable { return .skipUnreadable }
        if let existing = prior.entry,
           now.timeIntervalSince(existing.lastUpdated) < stalenessSeconds {
            return .skipFresh
        }
        return .rebuild
    }

    /// The seam: 「读不到既有记忆」 can be driven without racing a real lock.
    func updateMemoryIfNeeded(
        chatUsername: String,
        chatName: String,
        stalenessSeconds: TimeInterval = 1800,
        memoryRead: (String) -> HUDStore.ConversationMemoryRead
    ) async {
        let prior = memoryRead(chatUsername)
        switch Self.memoryRebuildDecision(prior: prior, stalenessSeconds: stalenessSeconds,
                                          now: Date()) {
        case .skipFresh:
            return
        case .skipUnreadable:
            print("[WCHUD] 对话记忆读不到，本轮不重建（避免用最近 30 条覆盖既有摘要）")
            return
        case .rebuild:
            break
        }

        let messages = (try? reader.getMessages(chatUsername: chatUsername, limit: 30)) ?? []
        guard !messages.isEmpty else { return }

        // One read, reused: a second lookup could answer differently than the one
        // that just cleared the guard above.
        let oldMemory = prior.entry
        let oldSummary = oldMemory?.summary ?? ""

        let myUname = reader.myUsername()
        let msgText = Self.attributedTranscript(
            Array(messages.prefix(20)),
            chatUsername: chatUsername,
            myUsername: myUname,
            myDisplayName: reader.displayName(for: myUname),
            mySelfNames: reader.mySelfNames
        )

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

        // Model output lands back in prompts verbatim ({conversation_memory},
        // proactive {reason}, insight {memory}) — a field carrying newlines or
        // a huge blob seeds persistent second-order injection. Cap count AND
        // per-item size, and collapse to one line at ingest.
        func cap(_ items: [String], _ maxItems: Int, _ maxChars: Int = 160) -> [String] {
            Array(items.prefix(maxItems)).map {
                AIService.oneLine(String($0.prefix(maxChars)))
            }.filter { !$0.isEmpty }
        }

        let memory = ConversationMemory(
            chatUsername: chatUsername,
            summary: AIService.oneLine(String((json["summary"] as? String ?? oldSummary).prefix(500))),
            keyTopics: cap(json["key_topics"] as? [String] ?? oldMemory?.keyTopics ?? [], 10),
            pendingItems: cap(json["pending_items"] as? [String] ?? oldMemory?.pendingItems ?? [], 5),
            sharedContext: cap(json["shared_context"] as? [String] ?? oldShared, 5),
            communicationNotes: cap(json["communication_notes"] as? [String] ?? oldComm, 5),
            moodTrend: AIService.oneLine(String((json["mood_trend"] as? String ?? oldMemory?.moodTrend ?? "").prefix(80))),
            conversationPhase: AIService.oneLine(String((json["conversation_phase"] as? String ?? oldMemory?.conversationPhase ?? "").prefix(80))),
            stance: AIService.oneLine(String((json["stance"] as? String ?? oldMemory?.stance ?? "").prefix(80))),
            messageCount7d: messages.count,
            lastUpdated: Date()
        )
        try? store.upsertConversationMemory(memory)
    }
}
