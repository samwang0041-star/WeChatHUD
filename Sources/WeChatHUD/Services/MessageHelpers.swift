import Foundation

/// Pure utility functions shared across the monitoring pipeline.
/// Extracted from ChatMonitor to keep the coordinator small.
enum MessageHelpers {
    /// Epoch seconds from a Date derived from WeChat's `create_time`, safe to
    /// persist as a watermark. Two hazards in one: `Double(Int64.max)` rounds up
    /// to 2^63 and `Int()` traps on it (the resident process dies), and a row
    /// dated ahead of now written as「已处理到这条」lands past the
    /// permanent-silence threshold — `rebuildInbox` then treats that chat as
    /// muted forever and it never resurfaces. Both collapse to "now".
    static func watermarkSeconds(_ date: Date) -> Int {
        let now = Int(Date().timeIntervalSince1970)
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(now) ? now : Int(seconds)
    }

    /// Multi-party chats are not only `xxx@chatroom`: WeChat also uses
    /// `@openim` (work/open groups) and `@im.chatroom`. Anything that is not
    /// a plain one-to-one wxid/chat id must take the group safety path —
    /// the autopilot pass must not auto-send into a group just because the
    /// id has a different suffix.
    static func isMultiPartyChat(_ username: String) -> Bool {
        username.contains("@chatroom")
            || username.contains("@openim")
            || username.contains("@im.chatroom")
    }

    /// True group-chat ids only — `…@chatroom` (personal) and
    /// `…@im.chatroom` (WeCom). `@openim` is a WeCom *user* id: it belongs
    /// in the multi-party safety path above (fail closed for autopilot),
    /// but an `@openim` 1:1 contact must not be labeled a group in
    /// whitelist attention levels or sender-parse flags.
    static func isGroupChat(_ username: String) -> Bool {
        username.contains("@chatroom") || username.contains("@im.chatroom")
    }

    /// True when a sender key is already a resolved WeChat account id rather
    /// than a name2id nickname hint. `wxid_…`, anything `…@…`, and `gh_…`
    /// cover modern accounts; a legacy short id ("alice") can't be told from
    /// a nickname by shape alone, so identity-sensitive paths treat those as
    /// unresolved.
    static func looksLikeWeChatID(_ username: String) -> Bool {
        username.hasPrefix("wxid_") || username.hasPrefix("gh_")
            || username.contains("@")
    }

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
        // When senderUsername is already a resolved account id, senderName
        // holds the CONTACT's nickname — a peer who happens to share my
        // nickname must not classify as self (it poisons style profiling,
        // commitment extraction, fulfillment evidence, and debt suppression
        // all at once). Name-hint matching only applies to unresolved senders.
        let senderIsResolvedID = looksLikeWeChatID(msg.senderUsername)
        // Check learned self aliases against BOTH senderUsername and
        // senderName. WeChat's group tables sometimes store the user's
        // own messages with `senderUsername` left as the raw nickname
        // hint (un-promoted) while `senderName` holds the same hint;
        // checking only one field missed these cases and AI
        // summaries ended up attributing the user's own "收到" to a
        // bystander named the same as their group nickname.
        if !mySelfNames.isEmpty {
            // senderUsername equality stays ungated: an ID-shaped entry can
            // only be MY OWN id — peers' wxids never reach mySelfNames (their
            // rows never carry realSenderId==0, the only learning path), and
            // `names.insert(me)` puts my wxid in legitimately. Gating it broke
            // self-classification when myUsername is empty.
            if mySelfNames.contains(msg.senderUsername) { return true }
            // The senderName leg is the actual collision vector — a resolved
            // peer's nickname can equal my alias, so it requires an
            // unresolved senderUsername.
            if !senderIsResolvedID, !msg.senderName.isEmpty, mySelfNames.contains(msg.senderName) {
                return true
            }
        }
        // Group chat fallback: senderUsername might be a display name instead of wxid
        if isMultiPartyChat(chatUsername) && !myDisplayName.isEmpty {
            if msg.senderUsername == myDisplayName { return true }
            if !senderIsResolvedID, msg.senderName == myDisplayName { return true }
        }
        // Multi-party covers @chatroom + @im.chatroom + @openim: the
        // private-chat fallback below would call every member message
        // self-sent in a WeCom group (@im.chatroom), and the same-name
        // fallback above must cover them too.
        if !isMultiPartyChat(chatUsername) && !msg.senderUsername.isEmpty {
            if msg.senderUsername != chatUsername && msg.senderUsername != msg.chatUsername {
                // A peer whose name2id entry stores a legacy short id
                // ("alice" for chat "alice_b1c2") is still the peer —
                // without this check every inbound message in that chat
                // would be classified as self and never surface.
                if let shortId = WeChatReader.legacyShortUsername(for: chatUsername),
                   msg.senderUsername == shortId { return false }
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
        // An ID-shaped senderKey matching selfNames can only be my own id —
        // peer wxids never enter selfNames (only realSenderId==0 hints are
        // learned, which are my messages). Only name-shaped collisions need
        // no gate at all here.
        if !senderKey.isEmpty && selfNames.contains(senderKey) { return true }
        if !looksLikeWeChatID(senderKey), !myDisplayName.isEmpty && senderKey == myDisplayName { return true }
        if isMultiPartyChat(chatUsername) { return false }
        if !senderKey.isEmpty && senderKey != chatUsername {
            // Same legacy-short-id carve-out as isFromSelf: the peer's
            // sender key can be "alice" while the chat is "alice_b1c2".
            if let shortId = WeChatReader.legacyShortUsername(for: chatUsername),
               senderKey == shortId { return false }
            return true
        }
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
    ///
    /// The value is model output: `Double("+1e400")` parses to +inf, and a
    /// huge finite number overflows `Int(Date.timeIntervalSince1970)`
    /// downstream — an *uncatchable* trap that re-fires on every queue
    /// drain because the poisoned row is never acked. Same guard the
    /// commitment resolver already carries: finite, positive, and the
    /// result stays under a sane horizon (~400 days).
    static func resolveDeadline(_ relative: String, relativeTo anchor: Date = Date()) -> Date? {
        let cleaned = relative.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.hasPrefix("+"), cleaned.count >= 3 else { return nil }
        let numStr = String(cleaned.dropFirst().dropLast())
        guard let num = Double(numStr), num.isFinite, num > 0 else { return nil }
        let unit = cleaned.last
        let scale: TimeInterval
        switch unit {
        case "m": scale = 60
        case "h": scale = 3600
        case "d": scale = 86400
        case "w": scale = 604800
        default: return nil
        }
        let seconds = num * scale
        guard seconds.isFinite, seconds <= 400 * 86400 else { return nil }
        return anchor.addingTimeInterval(seconds)
    }

    /// getMessages / recentMessages return newest-first. A chat
    /// transcript must show that same window oldest-at-top, newest-at-bottom.
    /// Taking .suffix(visible) on the newest-first array does the opposite:
    /// it keeps the oldest rows and drops the messages the user actually
    /// opened the thread to see.
    static func chronologicalWindow<T>(newestFirst: [T], visible: Int) -> [T] {
        let count = max(0, visible)
        return Array(newestFirst.prefix(count).reversed())
    }

    /// WeChat group @mentions terminate with U+2005, and some nicknames pad
    /// themselves with enclosing/nonspacing marks (U+0489 and friends) that
    /// render as a cloud of tofu in any font except WeChat's. Strip those for
    /// display without touching the raw bytes used for @-matching.
    static func displayText(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                continue
            default:
                break
            }
            switch scalar.value {
            case 0x00A0, 0x00AD, 0x2004, 0x2005, 0x2006, 0x202F:
                scalars.append(" ")
            case 0xFFFC:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let stripped = String(String.UnicodeScalarView(scalars))
        let collapsed = stripped.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
