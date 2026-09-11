import Foundation

/// Pure utility functions shared across the monitoring pipeline.
/// Extracted from ChatMonitor to keep the coordinator small.
enum MessageHelpers {

    /// True when a message has semantic text worth sending to an AI
    /// analyzer. WeChat DB rows can contain empty strings, generic
    /// parser fallbacks ("[消息]"), or UI-level failure copy
    /// ("内容无法显示"). Those are transport/parsing signals, not
    /// conversation content, and letting the model see them causes
    /// hallucinated summaries like "某人多次发送空白消息".
    static func isReadableAIContent(
        _ text: String,
        allowMediaPlaceholder: Bool = false
    ) -> Bool {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
        let unreadableExact: Set<String> = [
            "null", "(null)", "nil",
            "[消息]", "[未知消息]", "[不支持的消息]", "[unsupported]",
            "消息", "发送消息", "发来消息", "收到消息",
            "内容无法显示", "无法显示", "空白消息"
        ]
        if unreadableExact.contains(normalized) { return false }
        if normalized.hasPrefix("<?xml") || normalized.hasPrefix("<msg") { return false }
        if (normalized.contains("内容无法显示") || normalized.contains("无法显示")),
           normalized.count <= 12 {
            return false
        }
        if normalized.contains("空白消息") { return false }

        let mediaPlaceholders: Set<String> = [
            "[图片]", "[语音]", "[视频]", "[文件]", "[表情]",
            "[动画表情]", "[位置]", "[通话]", "[名片]"
        ]
        if mediaPlaceholders.contains(trimmed) {
            return allowMediaPlaceholder
        }
        return true
    }

    /// Check if a message text @-mentions the current user or @everyone.
    ///
    /// WeChat renders `@mention` in the saved message body using the
    /// *display name* of the target member, terminated by U+2005
    /// (FOUR-PER-EM SPACE) or an ordinary space — NOT the wxid. So a
    /// match against `myUsername` alone will miss almost every real
    /// @-mention. Pass `myDisplayName` and `mySelfNames` (learned
    /// aliases from WeChatReader) so we catch e.g. "@张三\u{2005}".
    ///
    /// Each candidate is matched as `@<name>` immediately followed by
    /// a Unicode whitespace / punctuation / end-of-string boundary —
    /// this avoids false positives like `myDisplayName == "大"`
    /// matching inside "@大家好".
    static func isAtMe(
        _ text: String,
        myUsername: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) -> Bool {
        // Gather every token we recognize as "me". Filter empties so
        // they don't degenerate into matching bare "@".
        var candidates: [String] = []
        if !myUsername.isEmpty { candidates.append(myUsername) }
        if !myDisplayName.isEmpty { candidates.append(myDisplayName) }
        for name in mySelfNames where !name.isEmpty { candidates.append(name) }

        for name in candidates {
            if containsAtMention(text: text, name: name) { return true }
        }
        if containsAtMention(text: text, name: "所有人") { return true }
        // @all is case-insensitive and can terminate at word boundary.
        if text.range(of: #"@all\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    /// Whether the message @-mentions the whole group rather than the user.
    ///
    /// `isAtMe` answers "should this interrupt me?" and correctly includes
    /// `@所有人` / `@all` — a broadcast does concern the reader. But that is not
    /// the same statement as "somebody picked you out", and UI that renders the
    /// mention has to say which one happened: a group announcement wearing a
    /// personal "@你" tells the user something false about why they were
    /// interrupted, and `@所有人` is the common case in a work group.
    static func isAtEveryone(_ text: String) -> Bool {
        if containsAtMention(text: text, name: "所有人") { return true }
        if text.range(of: #"@all\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    /// Returns true when `text` contains `@<name>` whose trailing
    /// character is a whitespace, punctuation, or end-of-string — the
    /// boundary WeChat uses to terminate an @mention. Iterates all
    /// occurrences so a non-boundary earlier hit doesn't short-circuit
    /// a boundary-matched later hit.
    private static func containsAtMention(text: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let needle = "@" + name
        var cursor = text.startIndex
        while let range = text.range(of: needle, range: cursor..<text.endIndex) {
            let after = range.upperBound
            if after == text.endIndex { return true }
            let ch = text[after]
            if ch.isWhitespace || ch.isPunctuation || ch.isNewline {
                return true
            }
            cursor = after
        }
        return false
    }

    /// Classify whether a message is from the user themselves.
    /// In group chats, WeChat DB sometimes stores senderUsername as a display
    /// name rather than wxid when the name2id lookup fails. Pass myDisplayName
    /// so we can catch that fallback case.
    static func isFromSelf(
        _ msg: MessageInfo,
        chatUsername: String,
        myUsername: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) -> Bool {
        if !myUsername.isEmpty && msg.senderUsername == myUsername { return true }
        // Check learned self aliases against BOTH senderUsername and
        // senderName. WeChat's group tables sometimes store the user's
        // own messages with `senderUsername` left as the raw nickname
        // hint (un-promoted) while `senderName` holds the same hint;
        // checking only one field missed these cases and AI
        // summaries ended up attributing the user's own "收到" to a
        // bystander named the same as their group nickname.
        if !mySelfNames.isEmpty {
            if mySelfNames.contains(msg.senderUsername) { return true }
            if !msg.senderName.isEmpty && mySelfNames.contains(msg.senderName) { return true }
        }
        // Group chat fallback: senderUsername might be a display name instead of wxid
        if chatUsername.contains("@chatroom") && !myDisplayName.isEmpty {
            if msg.senderUsername == myDisplayName || msg.senderName == myDisplayName {
                return true
            }
        }
        if !chatUsername.contains("@chatroom") && !msg.senderUsername.isEmpty {
            if msg.senderUsername != chatUsername && msg.senderUsername != msg.chatUsername {
                return true
            }
        }
        return false
    }

    /// Bulk-stats counterpart to isFromSelf when only the name2id key and sender id are available.
    static func isSelfSender(
        senderKey: String,
        senderId: Int,
        chatUsername: String,
        selfNames: Set<String>,
        myUsername: String = "",
        myDisplayName: String = ""
    ) -> Bool {
        if senderId == 0 { return true }
        if !myUsername.isEmpty && senderKey == myUsername { return true }
        if !senderKey.isEmpty && selfNames.contains(senderKey) { return true }
        if !myDisplayName.isEmpty && senderKey == myDisplayName { return true }
        if chatUsername.contains("@chatroom") { return false }
        if !senderKey.isEmpty && senderKey != chatUsername { return true }
        return false
    }

    /// Derive the unread status from raw signals.
    static func unreadStatus(
        replied: Bool,
        timestamp: Date,
        isVIP: Bool,
        thresholds: UnreadThresholds
    ) -> UnreadStatus {
        if replied { return .answered }
        let minutes = isVIP ? thresholds.vipMinutes : thresholds.normalMinutes
        let age = Date().timeIntervalSince(timestamp) / 60
        return age >= Double(minutes) ? .overdue : .pending
    }

    /// Canonical sender identifier — delegates to HUDStore's static version.
    static func senderIdentifier(
        senderUsername: String,
        senderName: String
    ) -> String {
        HUDStore.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
    }

    /// Check if a message's sender is in the ignored set for its chat.
    static func isIgnoredSender(
        _ msg: MessageInfo,
        ignoredSenderMap: [String: Set<String>]
    ) -> Bool {
        let identifier = senderIdentifier(
            senderUsername: msg.senderUsername,
            senderName: msg.senderName
        )
        return ignoredSenderMap[msg.chatUsername]?.contains(identifier) == true
    }

    /// Compare WeChat messages using second-level create_time plus local_id
    /// as a stable tie-breaker for same-second messages.
    static func isAfter(_ lhs: MessageInfo, _ rhs: MessageInfo) -> Bool {
        if lhs.createTime != rhs.createTime { return lhs.createTime > rhs.createTime }
        return lhs.localId > rhs.localId
    }

    static func isSameOrAfter(_ lhs: MessageInfo, _ rhs: MessageInfo) -> Bool {
        lhs.id == rhs.id || isAfter(lhs, rhs)
    }

    /// Parse relative deadline strings like "+30m", "+2h", "+1d", "+1w"
    /// into an absolute Date. Returns nil for invalid input.
    static func resolveDeadline(_ relative: String, relativeTo anchor: Date = Date()) -> Date? {
        let cleaned = relative.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.hasPrefix("+"), cleaned.count >= 3 else { return nil }
        let numStr = String(cleaned.dropFirst().dropLast())
        guard let num = Double(numStr), num > 0 else { return nil }
        let unit = cleaned.last
        let seconds: TimeInterval
        switch unit {
        case "m": seconds = num * 60
        case "h": seconds = num * 3600
        case "d": seconds = num * 86400
        case "w": seconds = num * 604800
        default: return nil
        }
        return anchor.addingTimeInterval(seconds)
    }
}
