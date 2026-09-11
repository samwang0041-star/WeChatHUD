import Foundation

/// On-demand chat analysis + reply suggestion context building.
/// Extracted from ChatMonitor to reduce the God Object. Extension on
/// the same class — all @Published properties stay in the main file.
extension ChatMonitor {

    static func filterGroupAnalysisMessages(
        _ messages: [MessageInfo],
        sourceAnchored: Bool,
        now: Date = Date()
    ) -> [MessageInfo] {
        messages.filter {
            (sourceAnchored || Date(timeIntervalSince1970: Double($0.createTime)) >= now.addingTimeInterval(-48 * 3600))
                && MessageHelpers.isReadableAIContent($0.text, allowMediaPlaceholder: false)
        }
    }

    // MARK: - On-demand chat analysis

    func analyzeGroupChat(item: InboxItem) async -> (ChatAnalyzer.GroupAnalysis?, String?) {
        let analysisType = "action_panel_group_v3"
        let messages: [MessageInfo]
        let sourceAnchored: Bool
        if let notification = item.contextNotification, notification.kind == .groupAt {
            guard let centered = GroupContextSourceLoader.load(notification: notification, reader: reader) else {
                return (nil, "找不到这条 @ 消息，未使用其他消息替代")
            }
            messages = GroupContextSourceLoader.newestFirst(centered)
            sourceAnchored = true
        } else {
            do {
                messages = try reader.getMessages(chatUsername: item.chatUsername, limit: 50)
            } catch {
                return (nil, "读取消息失败: \(error.localizedDescription)")
            }
            sourceAnchored = false
        }
        // Validate the exact source before accepting a cached analysis. A
        // stale cache must not hide that the triggering message disappeared.
        if let cached: ChatAnalyzer.GroupAnalysis = loadActionAnalysisCache(
            item: item,
            analysisType: analysisType,
            as: ChatAnalyzer.GroupAnalysis.self
        ) {
            return (cached, nil)
        }
        if messages.isEmpty { return (nil, "没有找到消息记录") }
        let filtered = Self.filterGroupAnalysisMessages(messages, sourceAnchored: sourceAnchored)
        if filtered.isEmpty {
            let fallback = ChatAnalyzer.GroupAnalysis(
                topics: "暂无可读内容",
                decisions: nil,
                my_action_items: nil,
                key_speakers: nil,
                status: "concluded",
                one_liner: "暂无可读内容"
            )
            writeActionAnalysisCache(fallback, item: item, analysisType: analysisType)
            cacheAndUpdateInboxSummary(fallback.one_liner, for: item)
            return (fallback, nil)
        }
        let myUname = reader.myUsername()
        let (result, error) = await chatAnalyzer.analyzeGroup(
            chatUsername: item.chatUsername,
            chatName: item.chatName,
            messages: filtered,
            myUsername: myUname,
            myName: "我",
            myDisplayName: reader.displayName(for: myUname),
            mySelfNames: reader.mySelfNames,
            triggerMessage: item.contextNotification.flatMap { notification in
                notification.kind == .groupAt
                    ? messages.first(where: { $0.id == notification.messageID && $0.chatUsername == notification.chatUsername })
                    : nil
            }
        )
        if let result {
            writeActionAnalysisCache(result, item: item, analysisType: analysisType)
            if let summary = inboxRowSummary(from: result) {
                cacheAndUpdateInboxSummary(summary, for: item)
            }
        }
        return (result, result == nil ? (error ?? "AI 分析返回为空，可能超时或解析失败") : nil)
    }

    func analyzePrivateChat(item: InboxItem) async -> (ChatAnalyzer.PrivateAnalysis?, String?) {
        let analysisType = "action_panel_private_v2"
        if let cached: ChatAnalyzer.PrivateAnalysis = loadActionAnalysisCache(
            item: item,
            analysisType: analysisType,
            as: ChatAnalyzer.PrivateAnalysis.self
        ) {
            return (cached, nil)
        }

        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: item.chatUsername, limit: 50)
        } catch {
            return (nil, "读取消息失败: \(error.localizedDescription)")
        }
        if messages.isEmpty { return (nil, "没有找到消息记录") }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let filtered = messages.filter {
            Date(timeIntervalSince1970: Double($0.createTime)) >= cutoff
                && MessageHelpers.isReadableAIContent($0.text, allowMediaPlaceholder: false)
        }
        if filtered.isEmpty {
            let fallback = ChatAnalyzer.PrivateAnalysis(
                intent: "暂无可读内容",
                urgency: "normal",
                urgency_reason: "",
                mood: "neutral",
                mood_evidence: "",
                context: nil,
                one_liner: "暂无可读内容"
            )
            writeActionAnalysisCache(fallback, item: item, analysisType: analysisType)
            cacheAndUpdateInboxSummary(fallback.one_liner, for: item)
            return (fallback, nil)
        }
        let myUname = reader.myUsername()
        let (result, error) = await chatAnalyzer.analyzePrivate(
            chatUsername: item.chatUsername,
            contactName: item.chatName,
            messages: filtered,
            myUsername: myUname,
            myName: "我",
            myDisplayName: reader.displayName(for: myUname),
            mySelfNames: reader.mySelfNames
        )
        if let result {
            writeActionAnalysisCache(result, item: item, analysisType: analysisType)
            if let summary = inboxRowSummary(from: result) {
                cacheAndUpdateInboxSummary(summary, for: item)
            }
        }
        return (result, result == nil ? (error ?? "AI 分析返回为空，可能超时或解析失败") : nil)
    }

    private func inboxRowSummary(from analysis: ChatAnalyzer.GroupAnalysis) -> String? {
        let candidates = [
            analysis.my_action_items,
            Optional(analysis.one_liner),
            Optional(analysis.decisions ?? ""),
            Optional(analysis.topics)
        ]
        return candidates.compactMap { candidate in
            let cleaned = trimInboxSummary(candidate ?? "")
            return cleaned.isEmpty ? nil : cleaned
        }.first
    }

    private func inboxRowSummary(from analysis: ChatAnalyzer.PrivateAnalysis) -> String? {
        let candidates = [
            Optional(analysis.intent),
            Optional(analysis.one_liner),
            analysis.context
        ]
        return candidates.compactMap { candidate in
            let cleaned = trimInboxSummary(candidate ?? "")
            return cleaned.isEmpty ? nil : cleaned
        }.first
    }

    private func loadActionAnalysisCache<T: Decodable>(
        item: InboxItem,
        analysisType: String,
        as type: T.Type
    ) -> T? {
        guard let raw = store.loadAnalysisCache(
            chatUsername: item.chatUsername,
            analysisType: analysisType,
            inputHash: item.generationKey
        ),
        let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func writeActionAnalysisCache<T: Encodable>(
        _ value: T,
        item: InboxItem,
        analysisType: String
    ) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? store.writeAnalysisCache(
            chatUsername: item.chatUsername,
            analysisType: analysisType,
            inputHash: item.generationKey,
            result: raw,
            ttlHours: 72
        )
    }

    struct ReplySuggestionContext {
        let contextWindow: String?
        let myLastReply: String?
        let analysisSummary: String?
        let knownConstraints: String?
    }

    func buildReplySuggestionContext(for item: InboxItem) -> ReplySuggestionContext {
        let messagesNewest = (try? reader.getMessages(chatUsername: item.chatUsername, limit: 50)) ?? []
        let targetSecond = Int(item.timestamp.timeIntervalSince1970)
        let target = messagesNewest.first {
            Int($0.createTime) == targetSecond
                || ($0.text == item.preview && $0.senderName == item.senderName)
        } ?? messagesNewest.first

        let contextWindow: String? = {
            guard let target else { return nil }
            let contactLookup: ContextWindowBuilder.ContactLookup = { [store] username in
                guard let contact = store.getContact(username: username) else { return nil }
                return (contact.attentionLevel, contact.role)
            }
            let chronological = messagesNewest.sorted { $0.createTime < $1.createTime }
            let chatType: ChatType = item.isGroup ? .group : .privateChat
            let window = ContextWindowBuilder.build(
                target: target,
                role: .replyGenerator,
                allMessages: chronological,
                chatType: chatType,
                contactLookup: contactLookup
            )
            let serialized = window.serialize()
            return serialized.isEmpty ? nil : serialized
        }()

        let myUname = reader.myUsername()
        let myDisplay = reader.displayName(for: myUname)
        let mySelfNames = reader.mySelfNames
        let myLastReply = messagesNewest.first {
            MessageHelpers.isFromSelf(
                $0,
                chatUsername: item.chatUsername,
                myUsername: myUname,
                myDisplayName: myDisplay,
                mySelfNames: mySelfNames
            )
        }?.text

        let analysisSummary = compactAnalysisSummary(for: item)

        var constraints: [String] = []
        if let memory = store.loadConversationMemory(chatUsername: item.chatUsername)?.formatForPrompt() {
            constraints.append("对话记忆:\n\(memory)")
        }
        let asks = store.loadPendingAsks(
            status: .pending,
            relevantSince: DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays)
        )
            .filter { $0.chatUsername == item.chatUsername }
            .prefix(3)
            .map(\.summary)
        if !asks.isEmpty {
            constraints.append("待处理请求: \(asks.joined(separator: "；"))")
        }
        let commitments = store.loadCommitments(status: .pending)
            .filter { $0.chatUsername == item.chatUsername }
            .prefix(3)
            .map(\.content)
        if !commitments.isEmpty {
            constraints.append("我的未兑现承诺: \(commitments.joined(separator: "；"))")
        }
        if item.isGroup && !item.isAtMention {
            constraints.append("安全提示: 群聊未明确 @ 我，不要替我表态或承诺。")
        }

        return ReplySuggestionContext(
            contextWindow: contextWindow,
            myLastReply: myLastReply,
            analysisSummary: analysisSummary,
            knownConstraints: constraints.isEmpty ? nil : constraints.joined(separator: "\n")
        )
    }

    func buildReplySuggestionContext(for item: ReplyDebtItem, pendingAsk: PendingAsk?) -> ReplySuggestionContext {
        let messagesNewest = (try? reader.getMessages(chatUsername: item.chatUsername, limit: 50)) ?? []
        let targetSecond = Int(item.timestamp.timeIntervalSince1970)
        let target = messagesNewest.first {
            Int($0.createTime) == targetSecond
                || ($0.text == item.preview && $0.senderName == item.senderName)
        } ?? messagesNewest.first

        let contextWindow: String? = {
            guard let target else { return nil }
            let contactLookup: ContextWindowBuilder.ContactLookup = { [store] username in
                guard let contact = store.getContact(username: username) else { return nil }
                return (contact.attentionLevel, contact.role)
            }
            let chronological = messagesNewest.sorted { $0.createTime < $1.createTime }
            let chatType: ChatType = item.isGroup ? .group : .privateChat
            let window = ContextWindowBuilder.build(
                target: target,
                role: .replyGenerator,
                allMessages: chronological,
                chatType: chatType,
                contactLookup: contactLookup
            )
            let serialized = window.serialize()
            return serialized.isEmpty ? nil : serialized
        }()

        let myUname = reader.myUsername()
        let myDisplay = reader.displayName(for: myUname)
        let mySelfNames = reader.mySelfNames
        let myLastReply = messagesNewest.first {
            MessageHelpers.isFromSelf(
                $0,
                chatUsername: item.chatUsername,
                myUsername: myUname,
                myDisplayName: myDisplay,
                mySelfNames: mySelfNames
            )
        }?.text ?? item.latestOutboundPreview

        var constraints: [String] = []
        constraints.append("当前待回复: \(item.preview)")
        constraints.append("优先级: \(item.priority.rawValue)，连续未回复 \(item.inboundCountSinceLastOutbound) 条")
        if let pendingAsk {
            constraints.append("已识别请求: \(pendingAsk.summary)（\(pendingAsk.askType.rawValue)）")
        }
        if let memory = store.loadConversationMemory(chatUsername: item.chatUsername)?.formatForPrompt() {
            constraints.append("对话记忆:\n\(memory)")
        }
        let commitments = store.loadCommitments(status: .pending)
            .filter { $0.chatUsername == item.chatUsername }
            .prefix(3)
            .map(\.content)
        if !commitments.isEmpty {
            constraints.append("我的未兑现承诺: \(commitments.joined(separator: "；"))")
        }
        if item.isGroup && !item.isAtMention {
            constraints.append("安全提示: 群聊未明确 @ 我，不要替我表态或承诺。")
        }

        return ReplySuggestionContext(
            contextWindow: contextWindow,
            myLastReply: myLastReply,
            analysisSummary: pendingAsk.map { "对方需要: \($0.summary)" },
            knownConstraints: constraints.joined(separator: "\n")
        )
    }

    private func compactAnalysisSummary(for item: InboxItem) -> String? {
        guard let entry = actionPrefetch[item.chatUsername],
              entry.generationKey == item.generationKey else {
            return nil
        }
        if let group = entry.groupAnalysis {
            var parts: [String] = []
            if !group.one_liner.isEmpty { parts.append("结论: \(group.one_liner)") }
            if let action = group.my_action_items, !action.isEmpty { parts.append("需要我: \(action)") }
            if !group.topics.isEmpty { parts.append("话题: \(group.topics)") }
            if let decisions = group.decisions, !decisions.isEmpty { parts.append("已有决议: \(decisions)") }
            if !group.status.isEmpty { parts.append("状态: \(group.status)") }
            return parts.isEmpty ? nil : parts.joined(separator: "。")
        }
        if let privateAnalysis = entry.privateAnalysis {
            var parts: [String] = []
            if !privateAnalysis.intent.isEmpty { parts.append("意图: \(privateAnalysis.intent)") }
            if let context = privateAnalysis.context, !context.isEmpty { parts.append("背景: \(context)") }
            if !privateAnalysis.urgency.isEmpty { parts.append("紧急度: \(privateAnalysis.urgency)") }
            if !privateAnalysis.mood.isEmpty { parts.append("语气: \(privateAnalysis.mood)") }
            return parts.isEmpty ? nil : parts.joined(separator: "。")
        }
        return nil
    }

    func buildRichStyleHint(_ style: StyleProfiler.StyleProfile) -> String? {
        guard !style.isEmpty else { return nil }
        var parts: [String] = [
            "用户风格: \(style.toneDescription)",
            "长度: 通常 \(style.lengthP25)-\(style.lengthP75) 字，中位数 \(style.lengthP50) 字",
            "标点: \(style.punctuationStyle)",
            "句式: \(style.sentenceStyle)",
            "节奏: \(style.typingRhythm.description)"
        ]
        if !style.frequentPhrases.isEmpty {
            parts.append("常用语: \(style.frequentPhrases.prefix(5).joined(separator: "、"))")
        }
        if !style.fewShotExamples.isEmpty {
            parts.append("真实例句: \(style.fewShotExamples.prefix(3).joined(separator: " / "))")
        }
        return parts.joined(separator: "。")
    }

    func loadReplySuggestions(for item: InboxItem) async -> [SuggestedReply]? {
        let profile = store.getRelationshipProfile(username: item.chatUsername)
        let fallback = fallbackRelationshipSignal(for: item)
        let relationship = profile.map {
            "\($0.relationship) (\($0.hierarchy.rawValue)/\($0.hierarchy.label))"
        } ?? fallback.relationship
        let style = await styleProfiler.getProfile(chatUsername: item.chatUsername)
        let replyContext = buildReplySuggestionContext(for: item)

        let input = AIReplySuggester.Input(
            messageBody: item.preview,
            senderName: item.senderName,
            chatName: item.chatName,
            isGroup: item.isGroup,
            askType: item.askType,
            relationship: relationship,
            styleHint: buildRichStyleHint(style),
            feedbackContext: buildFeedbackHint(),
            contextWindow: replyContext.contextWindow,
            myLastReply: replyContext.myLastReply,
            analysisSummary: replyContext.analysisSummary,
            relationshipHierarchy: profile?.hierarchy.rawValue ?? fallback.hierarchy,
            tonePreference: profile?.tonePreference.rawValue ?? fallback.tone,
            knownConstraints: replyContext.knownConstraints
        )

        guard let suggestions = await replySuggester.suggest(input) else { return nil }
        return suggestions.enumerated().map { idx, s in
            SuggestedReply(
                text: s.text,
                tone: idx == 0 ? "recommended" : s.tone,
                recommended: idx == 0,
                rationale: s.rationale.isEmpty ? s.intent : s.rationale
            )
        }
    }

    private struct FallbackRelationshipSignal {
        let relationship: String
        let hierarchy: String
        let tone: String
    }

    /// RelationshipProfile should improve personalization, not decide
    /// whether a reply suggestion exists at all. When the AI profile
    /// has not been inferred yet, derive a conservative relationship
    /// signal from the contact/whitelist metadata so actionable rows
    /// still get useful replies.
    private func fallbackRelationshipSignal(for item: InboxItem) -> FallbackRelationshipSignal {
        if let contact = store.getContact(username: item.chatUsername) {
            return FallbackRelationshipSignal(
                relationship: "\(contact.role.label) (\(contact.attentionLevel.label)，未建关系画像)",
                hierarchy: fallbackHierarchy(for: contact.role),
                tone: fallbackTone(for: contact.role)
            )
        }

        if let whitelist = store.getWhitelistEntry(username: item.chatUsername) {
            let kind = whitelist.isGroup ? "白名单群聊" : "白名单联系人"
            return FallbackRelationshipSignal(
                relationship: "\(kind) (\(whitelist.attentionLevel.label)，未建关系画像)",
                hierarchy: whitelist.isGroup ? "peer" : "external",
                tone: "formal"
            )
        }

        return FallbackRelationshipSignal(
            relationship: item.isGroup ? "群聊联系人 (未建关系画像)" : "私聊联系人 (未建关系画像)",
            hierarchy: item.isGroup ? "peer" : "external",
            tone: item.isGroup ? "brief" : "formal"
        )
    }

    private func fallbackHierarchy(for role: ContactRole) -> String {
        switch role {
        case .boss, .keyClient:
            return "superior"
        case .family, .friend, .partner:
            return "personal"
        case .colleague, .groupOnly:
            return "peer"
        case .client, .supplier, .service, .acquaintance:
            return "external"
        }
    }

    private func fallbackTone(for role: ContactRole) -> String {
        switch role {
        case .family, .friend, .partner:
            return "casual"
        case .service, .groupOnly:
            return "brief"
        case .boss, .keyClient, .colleague, .client, .supplier, .acquaintance:
            return "formal"
        }
    }

    func hasRelationshipProfile(for username: String) -> Bool {
        store.getRelationshipProfile(username: username) != nil
    }

    /// Fetch the relationship profile for a chat (used by the weekly
    /// report to decide whether a counterpart is superior / peer /
    /// subordinate). Returns nil when the user hasn't inferred a
    /// profile for this contact yet — the caller must handle that
    /// gracefully (those items flow through "未分类" sections).
    func relationshipProfile(for username: String) -> RelationshipProfile? {
        store.getRelationshipProfile(username: username)
    }

}
