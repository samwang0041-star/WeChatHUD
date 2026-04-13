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
    }

    private static let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]
    private static let askSignals = ["?", "？", "麻烦", "请", "帮忙", "发我", "确认", "看看"]

    static func build(seeds: [Seed], config: ReplyDebtConfig) -> [ReplyDebtItem] {
        seeds.compactMap { buildItem(seed: $0, config: config) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.timestamp > rhs.timestamp
            }
    }

    private static func buildItem(seed: Seed, config: ReplyDebtConfig) -> ReplyDebtItem? {
        guard seed.isWhitelisted else { return nil }
        guard let latestInbound = seed.latestInbound else { return nil }
        if let latestOutbound = seed.latestOutbound, latestOutbound.createTime >= latestInbound.createTime {
            return nil
        }

        let nowTs = Int(seed.now.timeIntervalSince1970)
        if let action = seed.chatAction {
            if action.snoozedUntil > nowTs { return nil }
            if action.silencedAt >= latestInbound.createTime { return nil }
        }

        let text = latestInbound.text
        let hasUrgentKeyword = urgentKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        let hasAskSignal = askSignals.contains { text.contains($0) }
        let hasRepeatedInbound = seed.inboundCountSinceLastOutbound >= 2
        let isPrivateChat = !seed.session.isGroup

        if seed.session.isGroup {
            let actionableWhitelistedGroup = seed.isWhitelisted && hasAskSignal
            guard seed.isAtMention || hasUrgentKeyword || actionableWhitelistedGroup else { return nil }
        }

        let ageMinutes = max(0, nowTs - latestInbound.createTime) / 60
        let overdueMinutes: Int
        if seed.session.isGroup && seed.isAtMention {
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
            timestamp: Date(timeIntervalSince1970: Double(latestInbound.createTime)),
            priority: priority,
            score: score,
            unreadCount: seed.session.unreadCount,
            isGroup: seed.session.isGroup,
            isWhitelisted: seed.isWhitelisted,
            isVIP: seed.isVIP,
            isAtMention: seed.isAtMention,
            inboundCountSinceLastOutbound: seed.inboundCountSinceLastOutbound,
            reasons: reasons,
            suggestedReplyMinutes: predictReplyWindow(seed: seed, priority: priority)
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
