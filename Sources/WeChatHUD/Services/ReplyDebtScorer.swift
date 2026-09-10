import Foundation

enum ReplyDebtScorer {
    struct Seed {
        let session: SessionInfo
        let chatName: String
        let isWhitelisted: Bool
        let isVIP: Bool
        let latestInbound: MessageInfo?
        let latestOutbound: MessageInfo?
        let inboundCountSinceLastOutbound: Int
        let isAtMention: Bool
        let chatAction: HUDStore.ChatActionState?
        let now: Date
        let contactReplyWindowMinutes: Int?  // NEW: from contacts table, nil = use global
        /// Whether this conversation is allowed to surface at all.
        ///
        /// Admission used to be implied right here by an ad-hoc
        /// whitelist-or-group-@ rule. It now arrives decided, so the inbox, the
        /// banners and the analysis queues all answer "who may reach me" the
        /// same way. Defaults to admitted so a seed built without the new field
        /// keeps its previous behaviour.
        var admission: AdmissionPolicy.Decision = .admit(.followed)
    }

    private static let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]
    private static let askSignals = ["?", "？", "麻烦", "请", "帮忙", "发我", "确认", "看看"]

    /// Messages that don't warrant a reply — ack words, emoji, stickers, media-only.
    private static let ackPatterns: [String] = [
        "好", "好的", "嗯", "嗯嗯", "收到", "ok", "OK", "Ok", "行", "哈哈",
        "哈哈哈", "哈哈哈哈", "嗯嗯嗯", "谢谢", "感谢", "👍", "🙏", "666",
        "了解", "明白", "知道了", "没问题", "可以"
    ]

    /// Returns true if the message is a short ack that doesn't need a reply.
    private static func isAckMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // Media-only messages from WeChat parser
        if trimmed.hasPrefix("[表情]") || trimmed.hasPrefix("[图片]")
            || trimmed.hasPrefix("[视频]") || trimmed.hasPrefix("[语音]")
            || trimmed.hasPrefix("[动画表情]") || trimmed.hasPrefix("[通话]")
            || trimmed.hasPrefix("[链接]") || trimmed.hasPrefix("[文件]")
            || trimmed.hasPrefix("[位置]") || trimmed.hasPrefix("[名片]") { return true }
        // Unparsed XML messages (files, mini-programs, etc.)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<msg>") { return true }
        // "null" from parser failures
        if trimmed == "null" { return true }
        // Exact match on ack words (case-insensitive for english)
        if ackPatterns.contains(where: { trimmed.caseInsensitiveCompare($0) == .orderedSame }) { return true }
        // Very short text (<=3 chars) with no ask signal
        if trimmed.count <= 3 && !askSignals.contains(where: { trimmed.contains($0) }) { return true }
        return false
    }

    /// Grace period: if user replied and counterpart responds within N seconds,
    /// treat the conversation as "done" (no new debt).
    private static let postReplyGraceSeconds = 120

    /// If both sides are silent for this long after the last inbound,
    /// the conversation is considered naturally ended (no debt).
    private static let conversationEndedSeconds = 7200  // 2 hours

    static func build(seeds: [Seed], config: ReplyDebtConfig) -> [ReplyDebtItem] {
        seeds.compactMap { buildItem(seed: $0, config: config) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.timestamp > rhs.timestamp
            }
    }

    private static func buildItem(seed: Seed, config: ReplyDebtConfig) -> ReplyDebtItem? {
        // The gate is admission. It still covers the old rule — an @ in a group
        // you never added is a clear request that deserves to surface, while a
        // stranger's private message does not — but it is now decided in one
        // place so the settings can actually change it.
        guard seed.admission.isAdmitted else { return nil }
        guard let latestInbound = seed.latestInbound else { return nil }
        if let latestOutbound = seed.latestOutbound,
           MessageHelpers.isSameOrAfter(latestOutbound, latestInbound) {
            // User "replied" but — did they actually answer? If the
            // inbound was substantive (money / specific time /
            // decision ask / commitment ref) and the reply was an
            // ack ("嗯嗯"), flag it as an unsubstantive-reply debt
            // instead of silently treating the conversation as done.
            let signals = ImportanceDetector.signals(latestInbound.text)
            if !signals.isEmpty, ImportanceDetector.isAckOnly(latestOutbound.text) {
                return buildUnsubstantiveItem(
                    seed: seed,
                    latestInbound: latestInbound,
                    latestOutbound: latestOutbound,
                    signals: signals,
                    config: config
                )
            }
            return nil
        }

        // After user replied, if counterpart's follow-up is just an ack ("好"、表情等)
        // or arrives within grace period, don't create new debt.
        if let latestOutbound = seed.latestOutbound {
            let gap = latestInbound.createTime - latestOutbound.createTime
            if gap > 0 && gap <= postReplyGraceSeconds { return nil }
            if gap > 0 && isAckMessage(latestInbound.text) { return nil }
        }

        let text = latestInbound.text
        let hasUrgentKeyword = urgentKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        let hasAskSignal = askSignals.contains { text.contains($0) }
        let hasRepeatedInbound = seed.inboundCountSinceLastOutbound >= 2

        // Conversation naturally ended: if both sides are silent for a long time
        // after the last inbound, the conversation is done — no debt.
        let nowTs = Int(seed.now.timeIntervalSince1970)
        let silenceSinceInbound = nowTs - latestInbound.createTime
        if let latestOutbound = seed.latestOutbound,
           MessageHelpers.isAfter(latestInbound, latestOutbound) {
            // User replied earlier, counterpart followed up, then silence.
            // Only low-signal follow-ups are naturally concluded by silence.
            // Real asks / VIP / unread / repeated nudges must not disappear
            // just because the user was away for two hours.
            let hasActionSignal = seed.isVIP
                || seed.session.unreadCount > 0
                || seed.isAtMention
                || hasUrgentKeyword
                || hasAskSignal
                || hasRepeatedInbound
                || ImportanceDetector.isSubstantive(latestInbound.text)
            if silenceSinceInbound > conversationEndedSeconds && !hasActionSignal {
                return nil
            }
        }

        if let action = seed.chatAction {
            if action.snoozedUntil > nowTs { return nil }
            if action.silencedAt >= latestInbound.createTime { return nil }
        }

        let isPrivateChat = !seed.session.isGroup

        if seed.session.isGroup {
            // Group chats require explicit signals directed at the user:
            // @mention or urgent keywords. Generic ask signals ("看看", "确认")
            // fire too often on messages not addressed to us.
            guard seed.isAtMention || hasUrgentKeyword else { return nil }
        }

        let ageMinutes = max(0, nowTs - latestInbound.createTime) / 60
        let overdueMinutes: Int
        if let contactWindow = seed.contactReplyWindowMinutes, contactWindow > 0 {
            overdueMinutes = contactWindow
        } else if seed.session.isGroup && seed.isAtMention {
            overdueMinutes = config.groupAtOverdueMinutes
        } else if seed.isVIP {
            overdueMinutes = config.vipOverdueMinutes
        } else {
            overdueMinutes = config.normalOverdueMinutes
        }
        let isOverdue = ageMinutes >= overdueMinutes

        var score = 0
        var reasons: [ReplyDebtReason] = []

        if seed.isAtMention {
            score += 5
            reasons.append(ReplyDebtReason(code: .atMention))
        }
        if isPrivateChat {
            score += 4
            reasons.append(ReplyDebtReason(code: .privateChat))
        }
        if seed.isWhitelisted {
            score += 3
            reasons.append(ReplyDebtReason(code: .whitelisted))
        }
        if hasUrgentKeyword {
            score += 3
            reasons.append(ReplyDebtReason(code: .urgentKeyword))
        }
        if hasAskSignal {
            score += 2
            reasons.append(ReplyDebtReason(code: .askSignal))
        }
        if seed.session.unreadCount > 0 {
            score += 1
            reasons.append(ReplyDebtReason(code: .unread))
        }
        if hasRepeatedInbound {
            score += 1
            reasons.append(ReplyDebtReason(code: .repeatedInbound))
        }
        if isOverdue {
            score += 1
            reasons.append(ReplyDebtReason(code: .overdue))
        }

        let priority: ReplyDebtPriority
        if score >= 8 {
            priority = .p0
        } else if score >= 5 {
            priority = .p1
        } else {
            priority = .p2
        }

        return ReplyDebtItem(
            id: seed.session.username,
            chatUsername: seed.session.username,
            chatName: seed.chatName,
            senderName: latestInbound.senderName,
            preview: String(text.prefix(80)),
            latestOutboundPreview: seed.latestOutbound.map { String($0.text.prefix(80)) },
            // Use the more recent of message createTime and session lastTimestamp.
            // WeChat's create_time can be stale for certain message types (bots,
            // forwarded messages), but session.lastTimestamp is always updated
            // when new activity happens.
            timestamp: Date(timeIntervalSince1970: Double(max(latestInbound.createTime, seed.session.lastTimestamp))),
            priority: priority,
            score: score,
            unreadCount: seed.session.unreadCount,
            isGroup: seed.session.isGroup,
            isWhitelisted: seed.isWhitelisted,
            isVIP: seed.isVIP,
            isAtMention: seed.isAtMention,
            inboundCountSinceLastOutbound: seed.inboundCountSinceLastOutbound,
            reasons: reasons,
            suggestedReplyMinutes: predictReplyWindow(seed: seed, priority: priority),
            contextNotification: contextNotification(seed: seed, message: latestInbound)
        )
    }

    private static func contextNotification(seed: Seed, message: MessageInfo) -> HUDNotification {
        HUDNotification(
            chatUsername: seed.session.username, chatName: seed.chatName,
            senderUsername: message.senderUsername, senderName: message.senderName,
            attentionLevel: seed.isVIP ? .vip : .watch,
            messageID: message.id, rawText: message.text,
            snippet: String(message.text.prefix(80)), isAtMention: seed.isAtMention,
            timestamp: Date(timeIntervalSince1970: Double(message.createTime)),
            kind: seed.session.isGroup ? (seed.isAtMention ? .groupAt : .groupMessage) : .privateChat
        )
    }

    /// Build a debt item for the "user acked but didn't really answer"
    /// case. Scoring is deliberately milder than a fresh unreplied
    /// message — the user DID at least register the message — but
    /// we still surface it so they don't leave important things on
    /// "嗯嗯". Priority caps at P1 so it never dominates over true
    /// unanswered items.
    private static func buildUnsubstantiveItem(
        seed: Seed,
        latestInbound: MessageInfo,
        latestOutbound: MessageInfo,
        signals: [String],
        config: ReplyDebtConfig
    ) -> ReplyDebtItem? {
        let nowTs = Int(seed.now.timeIntervalSince1970)

        // Silence / snooze honored just like the normal path.
        if let action = seed.chatAction {
            if action.snoozedUntil > nowTs { return nil }
            if action.silencedAt >= latestInbound.createTime { return nil }
        }

        var score = 2  // base — lower than overdue etc.
        var reasons: [ReplyDebtReason] = [
            ReplyDebtReason(code: .unsubstantiveReply,
                            label: "未实质回应（\(signals.joined(separator: "、"))）")
        ]

        if seed.isVIP {
            score += 2
            reasons.append(ReplyDebtReason(code: .whitelisted, label: "VIP"))
        } else if seed.isWhitelisted {
            score += 1
            reasons.append(ReplyDebtReason(code: .whitelisted))
        }

        if !seed.session.isGroup {
            score += 1
            reasons.append(ReplyDebtReason(code: .privateChat))
        }

        let priority: ReplyDebtPriority = score >= 5 ? .p1 : .p2

        return ReplyDebtItem(
            id: seed.session.username,
            chatUsername: seed.session.username,
            chatName: seed.chatName,
            senderName: latestInbound.senderName,
            preview: String(latestInbound.text.prefix(80)),
            latestOutboundPreview: String(latestOutbound.text.prefix(80)),
            timestamp: Date(timeIntervalSince1970: Double(
                max(latestInbound.createTime, seed.session.lastTimestamp)
            )),
            priority: priority,
            score: score,
            unreadCount: seed.session.unreadCount,
            isGroup: seed.session.isGroup,
            isWhitelisted: seed.isWhitelisted,
            isVIP: seed.isVIP,
            isAtMention: seed.isAtMention,
            inboundCountSinceLastOutbound: seed.inboundCountSinceLastOutbound,
            reasons: reasons,
            suggestedReplyMinutes: predictReplyWindow(seed: seed, priority: priority),
            contextNotification: contextNotification(seed: seed, message: latestInbound)
        )
    }

    /// Predict recommended reply window based on contact level + urgency.
    static func predictReplyWindow(seed: Seed, priority: ReplyDebtPriority) -> Int {
        // VIP → tight window
        if seed.isVIP {
            return priority == .p0 ? 10 : 20
        }
        // @mention in group → medium urgency
        if seed.isAtMention {
            return 30
        }
        // Whitelist private chat
        if seed.isWhitelisted && !seed.session.isGroup {
            return priority == .p0 ? 15 : 60
        }
        // Default
        return priority == .p0 ? 30 : 120
    }
}
