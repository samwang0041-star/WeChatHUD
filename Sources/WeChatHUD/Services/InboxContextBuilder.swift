import Foundation

/// Builds InboxContext by extracting precise data from DB.
/// Pure algorithm — no AI calls. Every field is an objective fact.
enum InboxContextBuilder {

    /// Determine how many context messages to fetch based on trigger message length.
    /// Shorter messages carry less information → need more context.
    static func contextWindowSize(messageLength: Int) -> Int {
        switch messageLength {
        case ...5:   return 15
        case 6...20: return 10
        case 21...50: return 6
        default:     return 3
        }
    }

    /// Calculate interaction trend from daily message counts.
    static func calculateTrend(dailyCounts: [Int]) -> InteractionTrend {
        guard dailyCounts.count >= 4 else { return .stable }
        let mid = dailyCounts.count / 2
        let firstHalf = dailyCounts[..<mid].reduce(0, +)
        let secondHalf = dailyCounts[mid...].reduce(0, +)
        let diff = secondHalf - firstHalf
        if diff > max(firstHalf / 3, 2) { return .up }
        if diff < -max(firstHalf / 3, 2) { return .down }
        return .stable
    }

    /// Detect media type from message baseType.
    static func detectMediaType(baseType: Int) -> MediaContentType? {
        switch baseType {
        case 3:  return .image
        case 34: return .voice
        case 43: return .video
        case 47: return .sticker
        case 48: return .location
        case 49: return .link
        default: return nil
        }
    }

    /// Build InboxContext for a single conversation.
    static func build(
        chatUsername: String,
        triggerMessage: MessageInfo,
        reader: WeChatReader,
        store: HUDStore,
        myUsername: String,
        contactEntry: ContactEntry?,
        whitelistEntry: WhitelistEntry?
    ) -> InboxContext {
        let text = triggerMessage.text
        let windowSize = contextWindowSize(messageLength: text.count)

        // Fetch recent messages for context
        let recentMessages = (try? reader.getMessages(
            chatUsername: chatUsername,
            limit: windowSize
        )) ?? []

        // Find my last reply
        let myLastReply = recentMessages.first {
            MessageHelpers.isFromSelf($0, chatUsername: chatUsername, myUsername: myUsername)
        }
        let timeSinceMyLastReply: TimeInterval? = myLastReply.map {
            Date().timeIntervalSince(Date(timeIntervalSince1970: Double($0.createTime)))
        }

        // Count inbound since my last reply
        let inboundSinceReply: Int
        if let outbound = myLastReply {
            inboundSinceReply = recentMessages.filter {
                !MessageHelpers.isFromSelf($0, chatUsername: chatUsername, myUsername: myUsername)
                && $0.createTime > outbound.createTime
            }.count
        } else {
            inboundSinceReply = recentMessages.filter {
                !MessageHelpers.isFromSelf($0, chatUsername: chatUsername, myUsername: myUsername)
            }.count
        }

        // Sender profile
        let role = contactEntry?.role ?? .acquaintance
        let attentionLevel: AttentionLevel
        if let wl = whitelistEntry {
            attentionLevel = wl.attentionLevel == .vip ? .vip : .whitelist
        } else {
            attentionLevel = .stranger
        }
        let replyWindow = contactEntry?.replyWindowMinutes ?? 120

        // Overdue
        let ageMinutes = Int(Date().timeIntervalSince(
            Date(timeIntervalSince1970: Double(triggerMessage.createTime))
        ) / 60)
        let isOverdue = ageMinutes >= replyWindow
        let overdueMinutes = isOverdue ? ageMinutes - replyWindow : 0

        // Weekly stats (simplified — full trend uses chatTrend)
        let weeklyCount = recentMessages.count
        let trend: InteractionTrend = .stable

        // Related data
        let asks = store.loadPendingAsks(status: .pending)
            .filter { $0.chatUsername == chatUsername }

        // Commitments — loadCommitments has no chatUsername filter, so filter locally
        let commitments = store.loadCommitments(status: .pending)
            .filter { $0.chatUsername == chatUsername }

        // Group context
        let isGroup = chatUsername.contains("@chatroom")
        let mentionedMe = MessageHelpers.isAtMe(text, myUsername: myUsername)
        let groupContext: [MessageInfo]?
        if isGroup && mentionedMe {
            let allRecent = (try? reader.getMessages(chatUsername: chatUsername, limit: windowSize + 10)) ?? []
            let mentionIdx = allRecent.firstIndex(where: { $0.id == triggerMessage.id }) ?? 0
            let start = min(mentionIdx + 1, allRecent.count)
            let end = min(start + 10, allRecent.count)
            groupContext = start < end ? Array(allRecent[start..<end]) : nil
        } else {
            groupContext = nil
        }

        // Message signals
        let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]
        let askSignals = ["?", "？", "麻烦", "请", "帮忙", "发我", "确认", "看看"]
        let hasUrgent = urgentKeywords.contains { text.localizedCaseInsensitiveContains($0) }
        let hasAsk = askSignals.contains { text.contains($0) }

        // Media detection
        let mediaType = detectMediaType(baseType: triggerMessage.baseType)
        let mediaContext = mediaType != nil
            ? Array(recentMessages.filter { $0.baseType == 1 }.prefix(5))
            : []

        return InboxContext(
            triggerMessage: triggerMessage,
            triggerMessageText: text,
            recentMessages: recentMessages,
            myLastReply: myLastReply,
            myLastReplyText: myLastReply?.text,
            timeSinceMyLastReply: timeSinceMyLastReply,
            senderRole: role,
            senderAttentionLevel: attentionLevel,
            senderReplyWindow: replyWindow,
            isOverdue: isOverdue,
            overdueMinutes: overdueMinutes,
            weeklyInteractionCount: weeklyCount,
            weeklyTrend: trend,
            avgResponseTimeMinutes: 0,
            pendingCommitments: commitments,
            pendingAsks: asks,
            isGroupChat: isGroup,
            mentionedMe: mentionedMe,
            groupRecentContext: groupContext,
            hasUrgentKeyword: hasUrgent,
            hasAskSignal: hasAsk,
            inboundCountSinceMyLastReply: inboundSinceReply,
            mediaType: mediaType,
            mediaFilePath: nil,  // Phase B: WeChat file system mapping
            mediaContextMessages: mediaContext,
            linkTitle: nil,       // Phase B: XML extraction
            linkDescription: nil,
            linkURL: nil,
            linkBodyText: nil
        )
    }
}
