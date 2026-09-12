import Foundation

enum ReplyDebtScorer {
    /// 会话窗口里的一条消息 + 两个由 ScanEngine 预先算好的身份标记。
    ///
    /// self 与 @ 的判定需要 myUsername/myDisplayName/mySelfNames，这些身份信息
    /// 属于 ScanEngine 一侧；评分器只消费结论，不重新推导身份。
    struct TimelineEntry {
        let message: MessageInfo
        let isFromSelf: Bool
        let isAtMe: Bool
    }

    struct Seed {
        let session: SessionInfo
        let chatName: String
        let isWhitelisted: Bool
        let isVIP: Bool
        /// 最新一条入站。评分时会被「锚点」（最近一条未被实质回应的入站）覆盖，
        /// 因此是 var —— 见 buildItem / anchorInbound。
        var latestInbound: MessageInfo?
        /// 最近一条我方消息。宽限期与"对话自然结束"判断始终以它为准。
        var latestOutbound: MessageInfo?
        let inboundCountSinceLastOutbound: Int
        /// 最新一条入站是否 @ 了我。评分时同样会被锚点对应的值覆盖。
        var isAtMention: Bool
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
        /// 该会话最近一批消息（顺序不限，评分器自己按 createTime/localId 排序）。
        ///
        /// 为什么需要窗口而不是只看最新一条：对方先说正事、我用一句「嗯」回完、
        /// 对方再补个「好」收尾时，只有翻回窗口里那条正事才能认出「没被实质回应」。
        /// 默认空数组 = 退回只看 latestInbound/latestOutbound 的旧行为，手工构造
        /// Seed 的既有测试不受影响。
        var timeline: [TimelineEntry] = []
    }

    private static let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]
    private static let askSignals = ["?", "？", "麻烦", "请", "帮忙", "发我", "确认", "看看"]

    /// Messages that don't warrant a reply — ack words, emoji, stickers, media-only.
    /// Returns true if the message is a short ack that doesn't need a reply.
    ///
    /// 词表来自 AckVocabulary（与 ImportanceDetector.isAckOnly 共用同一份），
    /// 这里只保留评分器特有的两条补充规则：媒体/XML 占位文本，以及「≤3 字且没有
    /// 问句信号」的短句。两条路径曾各自维护词表，导致「哈哈」在一处算 ack、在
    /// 另一处算实质内容。
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
        if AckVocabulary.isAckToken(trimmed) { return true }
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
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                // 末级 tiebreaker：同优先级、同分、同时间的两条债务必须每次排出
                // 同一个顺序，否则 SwiftUI 会整行重建（看起来没变，实际全刷新）。
                return lhs.chatUsername < rhs.chatUsername
            }
    }

    // MARK: - 窗口排序与评分锚点

    /// 窗口内消息按「新→旧」排序。带 timeline 的 seed 用真实窗口；只有
    /// latestInbound/latestOutbound 的 seed 退化成这两条，行为与旧实现一致。
    private static func orderedTimeline(seed: Seed) -> [TimelineEntry] {
        if !seed.timeline.isEmpty {
            return seed.timeline.sorted {
                if $0.message.createTime != $1.message.createTime {
                    return $0.message.createTime > $1.message.createTime
                }
                return $0.message.localId > $1.message.localId
            }
        }
        var fallback: [TimelineEntry] = []
        if let inbound = seed.latestInbound {
            fallback.append(TimelineEntry(
                message: inbound,
                isFromSelf: false,
                isAtMe: seed.isAtMention
            ))
        }
        if let outbound = seed.latestOutbound {
            fallback.append(TimelineEntry(message: outbound, isFromSelf: true, isAtMe: false))
        }
        return fallback.sorted {
            if $0.message.createTime != $1.message.createTime {
                return $0.message.createTime > $1.message.createTime
            }
            return $0.message.localId > $1.message.localId
        }
    }

    private static func inboundsNewestFirst(seed: Seed) -> [TimelineEntry] {
        orderedTimeline(seed: seed).filter { !$0.isFromSelf }
    }

    private static func outboundsNewestFirst(seed: Seed) -> [TimelineEntry] {
        orderedTimeline(seed: seed).filter(\.isFromSelf)
    }

    /// 评分锚点：窗口里最近一条「还没有被实质回应」的入站。
    ///
    /// 从新到旧扫入站消息，逐条看它之后的我方消息：
    /// - 有我方实质回复 → 它已经被回应，继续往前找。
    /// - 对方自己发来的短 ack（「好」「收到」）且它前面已有我方消息 → 它只是
    ///   收尾语，不构成新债务（保持旧行为），跳过它继续往前找。
    /// - 否则它就是锚点。若锚点之后只有 ack 回复、或根本没有回复，就交给后面的
    ///   评分路径：要么记「未实质回应」（ack 只降权，不再把整条债务抹掉），要么
    ///   按「对方发了一句短消息我还没回」维持旧行为。
    ///
    /// 群聊里 @我 是债务的必要条件（见 buildItem 里的 group guard），所以群聊
    /// 跳过既没有被 @、也不含紧急词的入站：@ 之后如果只有闲聊，锚点仍是那条 @，
    /// 债务不会因为后面有人插话「收到」就消失，也不会被闲聊凭空复活。
    private static func anchorInbound(
        seed: Seed,
        inbounds: [TimelineEntry],
        outbounds: [TimelineEntry]
    ) -> TimelineEntry? {
        for inbound in inbounds {
            if seed.session.isGroup, !inbound.isAtMe, !hasUrgentKeywordInText(inbound.message.text) {
                continue
            }
            let myReplies = outbounds.filter { MessageHelpers.isSameOrAfter($0.message, inbound.message) }
            let hasSubstantiveReply = myReplies.contains {
                !ImportanceDetector.isAckOnly($0.message.text)
            }
            if hasSubstantiveReply { continue }
            // 对方自己发来的短 ack，且它前面已经有我说过话 → 收尾语，跳过。
            let isPeerTrailingAck = isAckMessage(inbound.message.text) && outbounds.contains {
                !MessageHelpers.isSameOrAfter($0.message, inbound.message)
            }
            if isPeerTrailingAck { continue }
            return inbound
        }
        return nil
    }

    private static func hasUrgentKeywordInText(_ text: String) -> Bool {
        urgentKeywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func buildItem(seed: Seed, config: ReplyDebtConfig) -> ReplyDebtItem? {
        // The gate is admission. It still covers the old rule — an @ in a group
        // you never added is a clear request that deserves to surface, while a
        // stranger's private message does not — but it is now decided in one
        // place so the settings can actually change it.
        guard seed.admission.isAdmitted else { return nil }
        let outbounds = outboundsNewestFirst(seed: seed)
        let inbounds = inboundsNewestFirst(seed: seed)
        guard let newestInbound = inbounds.first?.message else { return nil }

        // 评分锚点 = 最近一条「还没被实质回应」的入站（见 anchorInbound）。
        // 旧实现只看最新一条入站并让 ack 直接短路整条债务：对方先说正事、我用
        // 一句「嗯」回完、对方再补个「好」收尾时，前面那条没被回应的正事就消失了。
        guard let anchor = anchorInbound(seed: seed, inbounds: inbounds, outbounds: outbounds) else {
            return nil
        }
        let latestInbound = anchor.message

        // 锚点取代「最新一条入站」参与后面的评分；latestOutbound 仍是最近一条
        // 我方消息（宽限期与自然结束判断都依赖它）。
        var effective = seed
        effective.latestInbound = latestInbound
        effective.latestOutbound = outbounds.first?.message
        effective.isAtMention = anchor.isAtMe

        // 「我回了个 ack 敷衍过去」必须优先于宽限期：对方说完正事、我 ack 一句、
        // 对方再在两分钟内补个「好」收尾，正是宽限期会误伤的形态（gap 很小）。
        // 闸门与旧实现一致：只有对方那条本身是要紧事（金额/时间/决策/承诺信号）、
        // 我方回复又是纯 ack 时才记债 —— ack 只降权，不再把整条债务抹掉。
        if let reply = outbounds.first(where: {
            MessageHelpers.isSameOrAfter($0.message, latestInbound)
        })?.message {
            let signals = ImportanceDetector.signals(latestInbound.text)
            // 对方本来也没说要紧事（例如问我一声「在吗」、我回了个「嗯」）：
            // 维持旧行为，不制造债务。
            guard !signals.isEmpty else { return nil }
            return buildUnsubstantiveItem(
                seed: effective,
                latestInbound: latestInbound,
                latestOutbound: reply,
                signals: signals,
                config: config
            )
        }

        // 宽限期（语义未变，见 postReplyGraceSeconds）：我回完之后对方 2 分钟内
        // 补的话，算这次交流还在进行，不记新债务。仍然按「最新一条入站」衡量，
        // 旧行为分毫不差。
        if let newestOutbound = outbounds.first {
            let gap = newestInbound.createTime - newestOutbound.message.createTime
            if gap > 0 && gap <= postReplyGraceSeconds { return nil }
        }

        let text = latestInbound.text
        let hasUrgentKeyword = urgentKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        let hasAskSignal = askSignals.contains { text.contains($0) }
        let hasRepeatedInbound = seed.inboundCountSinceLastOutbound >= 2

        // Conversation naturally ended: if both sides are silent for a long time
        // after the last inbound, the conversation is done — no debt.
        let nowTs = Int(seed.now.timeIntervalSince1970)
        let silenceSinceInbound = nowTs - latestInbound.createTime
        if let latestOutbound = effective.latestOutbound,
           MessageHelpers.isAfter(latestInbound, latestOutbound) {
            // User replied earlier, counterpart followed up, then silence.
            // Only low-signal follow-ups are naturally concluded by silence.
            // Real asks / VIP / unread / repeated nudges must not disappear
            // just because the user was away for two hours.
            let hasActionSignal = seed.isVIP
                || seed.session.unreadCount > 0
                || effective.isAtMention
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
            guard effective.isAtMention || hasUrgentKeyword else { return nil }
        }

        let ageMinutes = max(0, nowTs - latestInbound.createTime) / 60
        let overdueMinutes: Int
        if let contactWindow = seed.contactReplyWindowMinutes, contactWindow > 0 {
            overdueMinutes = contactWindow
        } else if seed.session.isGroup && effective.isAtMention {
            overdueMinutes = config.groupAtOverdueMinutes
        } else if seed.isVIP {
            overdueMinutes = config.vipOverdueMinutes
        } else {
            overdueMinutes = config.normalOverdueMinutes
        }
        let isOverdue = ageMinutes >= overdueMinutes

        var score = 0
        var reasons: [ReplyDebtReason] = []

        if effective.isAtMention {
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
            latestOutboundPreview: effective.latestOutbound.map { String($0.text.prefix(80)) },
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
            isAtMention: effective.isAtMention,
            inboundCountSinceLastOutbound: seed.inboundCountSinceLastOutbound,
            reasons: reasons,
            suggestedReplyMinutes: predictReplyWindow(seed: effective, priority: priority),
            contextNotification: contextNotification(seed: effective, message: latestInbound)
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
