import Foundation

/// Analyzes the user's outgoing messages to build a communication style
/// profile per contact/relationship type. Used by AutoReplyGenerator to
/// make AI replies sound like the real user.
actor StyleProfiler {
    private let reader: WeChatReader
    private let store: HUDStore

    /// Cached style profiles keyed by chatUsername, with per-chat refresh time.
    private var profileCache: [String: (profile: StyleProfile, refreshedAt: Date)] = [:]

    init(reader: WeChatReader, store: HUDStore) {
        self.reader = reader
        self.store = store
    }

    /// A snapshot of the user's communication style with a specific contact.
    struct StyleProfile {
        let contactRole: ContactRole
        let replyTone: ReplyTone
        /// Average message length in characters.
        let avgLength: Int
        /// Message length distribution (P25/P50/P75).
        let lengthP25: Int
        let lengthP50: Int
        let lengthP75: Int
        /// Whether the user frequently uses emoji with this contact.
        let usesEmoji: Bool
        /// Common greeting/closing patterns.
        let frequentPhrases: [String]
        /// Recent outgoing messages as few-shot examples (max 10).
        let fewShotExamples: [String]
        /// Message pairs: "peer said → user replied" for contextual few-shot (max 5).
        let messagePairs: [(question: String, answer: String)]
        /// General tone description derived from analysis.
        let toneDescription: String
        /// Punctuation habits description (e.g., "不加句号，偶尔用...").
        let punctuationStyle: String
        /// Sentence structure style (e.g., "碎片化短句，省略主语").
        let sentenceStyle: String
        /// Typing rhythm: single long message or split into multiple short ones.
        let typingRhythm: TypingRhythm

        var isEmpty: Bool { fewShotExamples.isEmpty }

        /// How the user typically sends messages.
        enum TypingRhythm {
            case singleMessage    // One message covers everything
            case multiMessage     // Splits thoughts into 2-3 consecutive messages
            case mixed

            var description: String {
                switch self {
                case .singleMessage: return "一条消息说完"
                case .multiMessage: return "习惯分多条发送（每次表达2-3条连发）"
                case .mixed: return "有时一条说完，有时分几条"
                }
            }
        }
    }

    /// Build or retrieve a cached style profile for a specific chat.
    /// - Parameter excludeMsgUIDs: Message UIDs to exclude (autopilot-sent messages to prevent style drift).
    func getProfile(chatUsername: String, excludeMsgUIDs: Set<String> = []) async -> StyleProfile {
        // M2 fix: per-chat cache timestamps
        if let cached = profileCache[chatUsername],
           Date().timeIntervalSince(cached.refreshedAt) < 1800 {
            return cached.profile
        }

        let profile = await buildProfile(chatUsername: chatUsername, excludeMsgUIDs: excludeMsgUIDs)
        profileCache[chatUsername] = (profile, Date())
        return profile
    }

    /// Build a generic profile for a contact role (when no chat history).
    func getDefaultProfile(role: ContactRole) -> StyleProfile {
        let len = defaultLength(for: role)
        return StyleProfile(
            contactRole: role,
            replyTone: role.defaultReplyTone,
            avgLength: len,
            lengthP25: max(1, len / 2),
            lengthP50: len,
            lengthP75: len * 2,
            usesEmoji: role == .friend || role == .family,
            frequentPhrases: defaultPhrases(for: role),
            fewShotExamples: [],
            messagePairs: [],
            toneDescription: describeTone(avgLen: len, usesEmoji: role == .friend || role == .family, role: role),
            punctuationStyle: "（暂无数据）",
            sentenceStyle: "（暂无数据）",
            typingRhythm: .singleMessage
        )
    }

    /// Force refresh all cached profiles.
    func invalidateCache() {
        profileCache.removeAll()
    }

    // MARK: - Private

    private func buildProfile(chatUsername: String, excludeMsgUIDs: Set<String> = []) async -> StyleProfile {
        let contact = store.getContact(username: chatUsername)
        let role = contact?.role ?? .acquaintance
        let tone = role.defaultReplyTone

        // Get recent messages for this chat (increased to 500 for deeper analysis)
        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: chatUsername, limit: 500)
        } catch {
            return getDefaultProfile(role: role)
        }

        let myUname = reader.myUsername()
        let outgoing = messages.filter { msg in
            Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUname)
                && !excludeMsgUIDs.contains(msg.id)
        }

        // Cold start: < 20 messages → unreliable analysis, use role-based defaults
        guard outgoing.count >= 20 else {
            return getDefaultProfile(role: role)
        }

        // --- Length distribution ---
        let lengths = outgoing.map { $0.text.count }.sorted()
        let avgLen = lengths.reduce(0, +) / max(lengths.count, 1)
        let n = lengths.count
        let lP25 = lengths[n / 4]
        let lP50 = lengths[n / 2]
        let lP75 = lengths[n * 3 / 4]

        // --- Emoji analysis ---
        let emojiPattern = "\\p{Emoji_Presentation}|\\p{Emoji}\\uFE0F"
        let emojiRegex = try? NSRegularExpression(pattern: emojiPattern)
        let emojiCount = outgoing.filter { msg in
            let range = NSRange(msg.text.startIndex..., in: msg.text)
            return (emojiRegex?.firstMatch(in: msg.text, range: range)) != nil
        }.count
        let usesEmoji = Double(emojiCount) / Double(outgoing.count) > 0.2

        // --- Punctuation analysis ---
        let punctStyle = analyzePunctuation(outgoing)

        // --- Sentence structure analysis ---
        let sentStyle = analyzeSentenceStructure(outgoing)

        // --- N-gram frequent phrases (replaces hardcoded list) ---
        let phrases = extractNgramPhrases(from: outgoing)

        // --- Message pairs (question → answer) ---
        let chrono = Array(messages.reversed())
        let pairs = extractMessagePairs(chrono: chrono, chatUsername: chatUsername, myUsername: myUname, excludeMsgUIDs: excludeMsgUIDs)

        // --- Few-shot examples (diverse, skip very short or system-like) ---
        let examples = outgoing
            .filter { $0.text.count >= 4 && $0.text.count <= 200 && !$0.text.hasPrefix("[") }
            .prefix(10)
            .map { $0.text }

        // --- Typing rhythm ---
        let rhythm = analyzeTypingRhythm(outgoing: outgoing)

        let toneDesc = describeTone(avgLen: avgLen, usesEmoji: usesEmoji, role: role)

        return StyleProfile(
            contactRole: role,
            replyTone: tone,
            avgLength: avgLen,
            lengthP25: lP25,
            lengthP50: lP50,
            lengthP75: lP75,
            usesEmoji: usesEmoji,
            frequentPhrases: phrases,
            fewShotExamples: Array(examples),
            messagePairs: pairs,
            toneDescription: toneDesc,
            punctuationStyle: punctStyle,
            sentenceStyle: sentStyle,
            typingRhythm: rhythm
        )
    }

    /// Classify whether a message is from the user themselves.
    /// Mirrors the logic in ChatMonitor.isFromSelf (which is private).
    private nonisolated static func isFromSelf(
        _ msg: MessageInfo,
        chatUsername: String,
        myUsername: String
    ) -> Bool {
        // Primary check: match against the known wxid from db_storage path.
        if !myUsername.isEmpty && msg.senderUsername == myUsername { return true }
        // 1-on-1 fallback: for private chats, if the sender field is
        // populated and doesn't match the peer, it must be self.
        if !chatUsername.contains("@chatroom") && !msg.senderUsername.isEmpty {
            if msg.senderUsername != chatUsername && msg.senderUsername != msg.chatUsername {
                return true
            }
        }
        return false
    }

    // MARK: - Deep Style Analysis

    /// Analyze punctuation habits from outgoing messages.
    private func analyzePunctuation(_ msgs: [MessageInfo]) -> String {
        var noPunct = 0, period = 0, ellipsis = 0, exclaim = 0, question = 0, tilde = 0
        let total = msgs.count
        guard total > 0 else { return "（暂无数据）" }

        for msg in msgs {
            let t = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let last = t.last!
            // Check ellipsis BEFORE period — "..." ends with "." too
            if t.hasSuffix("...") || t.hasSuffix("…") || t.hasSuffix("。。。") { ellipsis += 1 }
            else if last == "。" || last == "." { period += 1 }
            else if last == "！" || last == "!" { exclaim += 1 }
            else if last == "？" || last == "?" { question += 1 }
            else if last == "~" || last == "～" { tilde += 1 }
            else if !last.isPunctuation { noPunct += 1 }
        }

        var parts: [String] = []
        let pct: (Int) -> String = { "\(Int(Double($0) / Double(total) * 100))%" }
        if noPunct > total / 3 { parts.append("不加标点(\(pct(noPunct)))") }
        if period > total / 5 { parts.append("用句号(\(pct(period)))") }
        if ellipsis > total / 10 { parts.append("用省略号(\(pct(ellipsis)))") }
        if exclaim > total / 10 { parts.append("用感叹号(\(pct(exclaim)))") }
        if tilde > total / 10 { parts.append("用波浪号(\(pct(tilde)))") }
        return parts.isEmpty ? "标点使用均匀" : parts.joined(separator: "，")
    }

    /// Analyze sentence structure: complete vs fragmented, subject omission.
    private func analyzeSentenceStructure(_ msgs: [MessageInfo]) -> String {
        var shortFrag = 0, mediumComplete = 0, longDetailed = 0
        var subjectOmitted = 0
        let total = msgs.count
        guard total > 0 else { return "（暂无数据）" }

        let subjectStarters = ["我", "你", "他", "她", "它", "我们", "你们", "他们", "这", "那"]

        for msg in msgs {
            let t = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= 6 { shortFrag += 1 }
            else if t.count <= 20 { mediumComplete += 1 }
            else { longDetailed += 1 }

            // Check if message starts without a typical subject
            if !t.isEmpty && !subjectStarters.contains(where: { t.hasPrefix($0) }) {
                subjectOmitted += 1
            }
        }

        var parts: [String] = []
        if shortFrag > total / 2 { parts.append("碎片化短句为主") }
        else if longDetailed > total / 3 { parts.append("偏长句完整表达") }
        else { parts.append("句长适中") }

        if subjectOmitted > total * 2 / 3 { parts.append("经常省略主语") }
        return parts.joined(separator: "，")
    }

    /// Extract frequent whole-message phrases from outgoing messages.
    /// Only keeps short complete messages (≤8 chars) that appear 2+ times —
    /// these capture real user catchphrases without character-level n-gram noise.
    private func extractNgramPhrases(from msgs: [MessageInfo]) -> [String] {
        var freq: [String: Int] = [:]

        for msg in msgs {
            let t = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 1 && t.count <= 8 else { continue }
            // Skip system-like messages
            guard !t.hasPrefix("[") else { continue }
            freq[t, default: 0] += 1
        }

        let minCount = max(2, msgs.count / 30)
        return freq.filter { $0.value >= minCount }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.count > rhs.key.count
            }
            .prefix(10)
            .map { $0.key }
    }

    /// Extract message pairs: "peer said → user replied" for contextual few-shot.
    /// Only includes pairs where reply came within 5 minutes (same conversation context).
    private func extractMessagePairs(
        chrono: [MessageInfo], chatUsername: String,
        myUsername: String, excludeMsgUIDs: Set<String>
    ) -> [(question: String, answer: String)] {
        var pairs: [(String, String)] = []
        var lastPeerMsg: (text: String, time: Int)?

        for msg in chrono {
            let fromSelf = Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUsername)
            if !fromSelf {
                lastPeerMsg = (msg.text, msg.createTime)
            } else if let peer = lastPeerMsg, !excludeMsgUIDs.contains(msg.id) {
                let interval = msg.createTime - peer.time
                // Only include pairs where reply was within 5 minutes
                guard interval > 0, interval <= 300 else {
                    lastPeerMsg = nil
                    continue
                }
                let q = peer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let a = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if q.count >= 2 && a.count >= 2 && q.count <= 100 && a.count <= 100 {
                    pairs.append((q, a))
                }
                lastPeerMsg = nil
            }
        }
        return Array(pairs.suffix(5))  // keep last 5 (most recent)
    }

    /// Analyze typing rhythm: single message vs multi-message bursts.
    private func analyzeTypingRhythm(outgoing: [MessageInfo]) -> StyleProfile.TypingRhythm {
        guard outgoing.count >= 5 else { return .singleMessage }

        // Messages are newest-first; reverse to chronological
        let chrono = outgoing.reversed()
        var burstCount = 0  // consecutive message groups (< 30s apart)
        var singleCount = 0
        var prev: MessageInfo?

        var currentBurstSize = 1
        for msg in chrono {
            if let p = prev {
                let gap = abs(msg.createTime - p.createTime)
                if gap < 30 {
                    currentBurstSize += 1
                } else {
                    if currentBurstSize > 1 { burstCount += 1 }
                    else { singleCount += 1 }
                    currentBurstSize = 1
                }
            }
            prev = msg
        }
        // Flush last group
        if currentBurstSize > 1 { burstCount += 1 }
        else { singleCount += 1 }

        let total = burstCount + singleCount
        guard total > 0 else { return .singleMessage }
        let burstRatio = Double(burstCount) / Double(total)
        if burstRatio > 0.5 { return .multiMessage }
        if burstRatio > 0.2 { return .mixed }
        return .singleMessage
    }

    private func describeTone(avgLen: Int, usesEmoji: Bool, role: ContactRole) -> String {
        var parts: [String] = []
        if avgLen < 10 {
            parts.append("极简风格，喜欢短消息")
        } else if avgLen < 30 {
            parts.append("简洁风格，言简意赅")
        } else {
            parts.append("详细风格，喜欢完整表达")
        }
        if usesEmoji {
            parts.append("经常使用 emoji")
        }
        switch role.defaultReplyTone {
        case .reporting:
            parts.append("语气偏汇报式")
        case .professional:
            parts.append("语气正式专业")
        case .collaborative:
            parts.append("语气协作平等")
        case .casual:
            parts.append("语气随意自然")
        case .polite:
            parts.append("语气礼貌客气")
        }
        return parts.joined(separator: "，")
    }

    private func defaultLength(for role: ContactRole) -> Int {
        switch role {
        case .boss, .keyClient: return 20
        case .family, .friend: return 15
        case .colleague, .client, .partner, .supplier: return 25
        case .acquaintance, .groupOnly, .service: return 10
        }
    }

    private func defaultPhrases(for role: ContactRole) -> [String] {
        switch role {
        case .boss: return ["好的", "收到", "马上"]
        case .keyClient: return ["好的", "收到", "您放心"]
        case .family: return ["嗯", "好", "知道了"]
        case .friend: return ["哈哈", "好", "行"]
        case .colleague: return ["好的", "收到", "OK"]
        default: return ["好的", "收到"]
        }
    }

    // MARK: - Reply Timing Analysis

    /// Cached timing profiles keyed by chatUsername.
    private var timingCache: [String: (profile: ReplyTimingProfile, refreshedAt: Date)] = [:]

    /// Analyze historical reply intervals and build a timing profile.
    /// Cached for 1 hour since historical patterns change slowly.
    func getTimingProfile(chatUsername: String) async -> ReplyTimingProfile {
        // Check memory cache
        if let cached = timingCache[chatUsername],
           Date().timeIntervalSince(cached.refreshedAt) < 3600 {
            return cached.profile
        }
        // Check DB cache (refreshed < 24h ago)
        if let stored = store.loadReplyTimingProfile(chatUsername: chatUsername),
           Date().timeIntervalSince(stored.lastUpdated) < 86400 {
            timingCache[chatUsername] = (stored, Date())
            return stored
        }

        let profile = buildTimingProfile(chatUsername: chatUsername)
        timingCache[chatUsername] = (profile, Date())
        try? store.upsertReplyTimingProfile(profile)
        return profile
    }

    /// Build timing profile by analyzing "peer sent → I replied" intervals.
    private func buildTimingProfile(chatUsername: String) -> ReplyTimingProfile {
        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: chatUsername, limit: 500)
        } catch {
            return defaultTimingProfile(chatUsername: chatUsername)
        }

        let myUname = reader.myUsername()
        // Collect reply pairs: (peer message → my reply) with interval
        var workDelays: [Int] = []
        var eveningDelays: [Int] = []
        var weekendDelays: [Int] = []
        var lateNightDelays: [Int] = []
        var pairedPeerIndices: Set<Int> = []  // track which peer messages got a reply

        // Messages are ordered newest-first; reverse to chronological
        let chronoArray = Array(messages.reversed())
        var lastPeerMsgTime: Int?
        var lastPeerIndex: Int?

        for (idx, msg) in chronoArray.enumerated() {
            let fromSelf = Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUname)
            if !fromSelf {
                lastPeerMsgTime = msg.createTime
                lastPeerIndex = idx
            } else if let peerTime = lastPeerMsgTime, let peerIdx = lastPeerIndex {
                let delay = msg.createTime - peerTime
                guard delay > 0, delay < 86400 else { // ignore > 24h gaps
                    lastPeerMsgTime = nil
                    lastPeerIndex = nil
                    continue
                }

                let period = Self.timePeriod(unixTime: peerTime)
                switch period {
                case .workHours: workDelays.append(delay)
                case .evening: eveningDelays.append(delay)
                case .weekend: weekendDelays.append(delay)
                case .lateNight: lateNightDelays.append(delay)
                }
                pairedPeerIndices.insert(peerIdx)
                lastPeerMsgTime = nil // consumed
                lastPeerIndex = nil
            }
        }

        // Count ALL late-night incoming messages (paired + unpaired)
        var totalLateNightIncoming = 0
        for msg in chronoArray {
            if !Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUname) {
                if Self.timePeriod(unixTime: msg.createTime) == .lateNight {
                    totalLateNightIncoming += 1
                }
            }
        }
        // Late-night replies = paired peer messages that were in late-night period
        let lateNightReplies = pairedPeerIndices.filter { idx in
            Self.timePeriod(unixTime: chronoArray[idx].createTime) == .lateNight
        }.count
        let lnReplyRate = totalLateNightIncoming > 0
            ? Double(lateNightReplies) / Double(totalLateNightIncoming)
            : 0.0
        // Default: silent if < 20% reply rate with sufficient data
        let silentAtNight = totalLateNightIncoming > 3 && lnReplyRate < 0.2

        let totalSamples = workDelays.count + eveningDelays.count + weekendDelays.count + lateNightDelays.count

        return ReplyTimingProfile(
            chatUsername: chatUsername,
            workHours: Self.computeDistribution(workDelays),
            evening: Self.computeDistribution(eveningDelays),
            weekend: Self.computeDistribution(weekendDelays),
            lateNight: Self.computeDistribution(lateNightDelays),
            silentAtNight: silentAtNight,
            lateNightReplyRate: lnReplyRate,
            sampleCount: totalSamples,
            lastUpdated: Date()
        )
    }

    private func defaultTimingProfile(chatUsername: String) -> ReplyTimingProfile {
        let defaultDist = ReplyTimingProfile.DelayDistribution(p25: 30, p50: 60, p75: 180, count: 0)
        return ReplyTimingProfile(
            chatUsername: chatUsername,
            workHours: defaultDist,
            evening: ReplyTimingProfile.DelayDistribution(p25: 15, p50: 45, p75: 120, count: 0),
            weekend: defaultDist,
            lateNight: .zero,
            silentAtNight: true,
            lateNightReplyRate: 0.0,
            sampleCount: 0,
            lastUpdated: Date()
        )
    }

    /// Determine time period from a unix timestamp.
    enum TimePeriod { case workHours, evening, weekend, lateNight }

    nonisolated static func timePeriod(unixTime: Int) -> TimePeriod {
        let date = Date(timeIntervalSince1970: Double(unixTime))
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date) // 1=Sun, 7=Sat

        // Late night: 23:00-7:00
        if hour >= 23 || hour < 7 { return .lateNight }
        // Weekend: Sat & Sun, 7:00-23:00
        if weekday == 1 || weekday == 7 { return .weekend }
        // Work hours: Mon-Fri 9:00-18:00
        if hour >= 9 && hour < 18 { return .workHours }
        // Evening: Mon-Fri 18:00-23:00 (and 7:00-9:00)
        return .evening
    }

    /// Compute P25/P50/P75 from a sorted array of delays.
    nonisolated private static func computeDistribution(_ delays: [Int]) -> ReplyTimingProfile.DelayDistribution {
        guard !delays.isEmpty else { return .zero }
        let sorted = delays.sorted()
        let n = sorted.count
        return ReplyTimingProfile.DelayDistribution(
            p25: sorted[n / 4],
            p50: sorted[n / 2],
            p75: sorted[n * 3 / 4],
            count: n
        )
    }
}
