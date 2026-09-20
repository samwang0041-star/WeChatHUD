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
            /// Splits thoughts into several messages. `burstSize` is the
            /// measured median length of those runs — the prompt used to
            /// hard-code "2-3 条" no matter how many the user actually sent.
            case multiMessage(burstSize: Int)
            case mixed

            var description: String {
                switch self {
                case .singleMessage: return "一条消息说完"
                case .multiMessage(let burstSize): return "习惯分多条发送（一次连发约 \(burstSize) 条）"
                case .mixed: return "有时一条说完，有时分几条"
                }
            }
        }
    }

    /// Build or retrieve a cached style profile for a specific chat.
    /// - Parameter excludeMsgUIDs: Message UIDs to exclude (autopilot-sent messages to prevent style drift).
    func getProfile(chatUsername: String, excludeMsgUIDs: Set<String> = []) async -> StyleProfile {
        // M2 fix: per-chat cache timestamps.
        //
        // The exclusion set is part of the cache key. Caching on the chat alone
        // let the two callers fight over one entry: the autopilot asks with its
        // own sent messages excluded, the manual suggester asked with no
        // exclusions, and whichever ran first handed its profile to the other
        // for the next 30 minutes. A user who had just auto-replied could have
        // the autopilot's own wording presented back as "your style".
        let key = Self.cacheKey(chatUsername: chatUsername, excludeMsgUIDs: excludeMsgUIDs)
        if let cached = profileCache[key],
           Self.isFresh(refreshedAt: cached.refreshedAt, window: Self.profileCacheTTL) {
            return cached.profile
        }

        let profile = await buildProfile(chatUsername: chatUsername, excludeMsgUIDs: excludeMsgUIDs)
        profileCache[key] = (profile, Date())
        pruneProfileCache()
        return profile
    }

    /// Cache age, trusted only in one direction.
    ///
    /// `Date()` steps: an NTP correction, a DST bug, or the user setting the
    /// clock can move it either way. A negative `elapsed` used to satisfy every
    /// `< window` comparison here, so one backwards jump froze the style profile
    /// — and the late-night rate that gates the 3 a.m. hold — permanently, with
    /// nothing left to expire the entry. Treating "from the future" as expired
    /// costs one re-read and keeps the cache honest.
    nonisolated static func isFresh(refreshedAt: Date, window: TimeInterval, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(refreshedAt)
        return elapsed >= 0 && elapsed < window
    }

    static let profileCacheTTL: TimeInterval = 1800
    /// The key carries a hash of the exclusion set, and that set changes on every
    /// send — so without a bound this dictionary grew one entry per reply
    /// decision for the life of a process meant to run 24/7.
    static let profileCacheCap = 64

    private func pruneProfileCache() {
        profileCache = Self.pruning(profileCache, ttl: Self.profileCacheTTL,
                                    cap: Self.profileCacheCap, now: Date())
    }

    /// The bound, as a pure function so the growth it prevents is testable
    /// without a 24-hour process. Expired entries go first, then the oldest.
    nonisolated static func pruning<Value>(
        _ cache: [String: (profile: Value, refreshedAt: Date)],
        ttl: TimeInterval, cap: Int, now: Date
    ) -> [String: (profile: Value, refreshedAt: Date)] {
        var kept = cache.filter { isFresh(refreshedAt: $0.value.refreshedAt, window: ttl, now: now) }
        guard kept.count > cap else { return kept }
        kept = Dictionary(uniqueKeysWithValues: kept.sorted {
            $0.value.refreshedAt > $1.value.refreshedAt
        }.prefix(cap).map { ($0.key, $0.value) })
        return kept
    }

    /// The exclusion set can hold hundreds of ids; hashing it keeps the cache
    /// key small while staying stable for a given caller.
    private static func cacheKey(chatUsername: String, excludeMsgUIDs: Set<String>) -> String {
        guard !excludeMsgUIDs.isEmpty else { return chatUsername }
        var hasher = Hasher()
        for uid in excludeMsgUIDs.sorted() { hasher.combine(uid) }
        return "\(chatUsername)#excl\(hasher.finalize())"
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
        let myDisplay = reader.displayName(for: myUname)
        let mySelfNames = reader.mySelfNames
        let outgoing = messages.filter { msg in
            Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUname, myDisplayName: myDisplay, mySelfNames: mySelfNames)
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
        let pairs = extractMessagePairs(chrono: chrono, chatUsername: chatUsername, myUsername: myUname, myDisplayName: myDisplay, mySelfNames: mySelfNames, excludeMsgUIDs: excludeMsgUIDs)

        // --- Few-shot examples (diverse, skip very short or system-like) ---
        // oneLine + sanitize at ingest: these strings are interpolated
        // verbatim into autopilot/reply prompts — a multi-line or
        // instruction-looking self message becomes prompt structure.
        let examples = outgoing
            .filter { $0.text.count >= 4 && $0.text.count <= 200 && !$0.text.hasPrefix("[") }
            .prefix(10)
            .map { AIService.sanitizeForAI(AIService.oneLine($0.text)) }
            .filter { !$0.isEmpty }

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

    /// Delegate to the canonical implementation in MessageHelpers.
    /// `mySelfNames` carries the learned display-name aliases for the
    /// user — critical for group chats where WeChat stores the
    /// sender's identifier as a display name rather than the wxid. Must
    /// be forwarded at every call site, otherwise the user's own
    /// group-chat messages get classified as "peer" and pollute the
    /// tone/rhythm analytics.
    private nonisolated static func isFromSelf(
        _ msg: MessageInfo,
        chatUsername: String,
        myUsername: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) -> Bool {
        MessageHelpers.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
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
        myUsername: String, myDisplayName: String = "",
        mySelfNames: Set<String> = [],
        excludeMsgUIDs: Set<String>
    ) -> [(question: String, answer: String)] {
        var pairs: [(String, String)] = []
        var lastPeerMsg: (text: String, time: Int)?

        for msg in chrono {
            let fromSelf = Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
            if !fromSelf {
                lastPeerMsg = (msg.text, msg.createTime)
            } else if let peer = lastPeerMsg, !excludeMsgUIDs.contains(msg.id) {
                let interval = msg.createTime - peer.time
                // Only include pairs where reply was within 5 minutes
                guard interval > 0, interval <= 300 else {
                    lastPeerMsg = nil
                    continue
                }
                let q = AIService.sanitizeForAI(peer.text)
                let a = AIService.sanitizeForAI(msg.text)
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
        var burstSizes: [Int] = []
        var prev: MessageInfo?

        var currentBurstSize = 1
        for msg in chrono {
            if let p = prev {
                let gap = abs(msg.createTime - p.createTime)
                if gap < 30 {
                    currentBurstSize += 1
                } else {
                    if currentBurstSize > 1 {
                        burstCount += 1
                        burstSizes.append(currentBurstSize)
                    } else {
                        singleCount += 1
                    }
                    currentBurstSize = 1
                }
            }
            prev = msg
        }
        // Flush last group
        if currentBurstSize > 1 {
            burstCount += 1
            burstSizes.append(currentBurstSize)
        } else {
            singleCount += 1
        }

        let total = burstCount + singleCount
        guard total > 0 else { return .singleMessage }
        let burstRatio = Double(burstCount) / Double(total)
        if burstRatio > 0.5 {
            let median = burstSizes.sorted()[burstSizes.count / 2]
            return .multiMessage(burstSize: max(2, median))
        }
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

    func testingProfileCacheCount() -> Int { profileCache.count }

    static let unmeasuredRetrySeconds: TimeInterval = 60

    /// Cached timing profiles keyed by chatUsername.
    private var timingCache: [String: (profile: ReplyTimingProfile, refreshedAt: Date)] = [:]

    /// Analyze historical reply intervals and build a timing profile.
    /// Cached for 1 hour since historical patterns change slowly.
    func getTimingProfile(chatUsername: String) async -> ReplyTimingProfile {
        // Check memory cache
        if let cached = timingCache[chatUsername],
           Self.isFresh(refreshedAt: cached.refreshedAt,
                        window: cached.profile.lateNightReplyRate == nil
                            ? Self.unmeasuredRetrySeconds : 3600) {
            return cached.profile
        }
        // Check DB cache (refreshed < 24h ago). A row with no rate is a
        // pre-persistence row: it cannot answer the threshold question, so it is
        // re-measured rather than trusted — the old loader answered it with a
        // 0.0 / 1.0 rebuilt from the silent bit.
        if let stored = store.loadReplyTimingProfile(chatUsername: chatUsername),
           stored.lateNightReplyRate != nil,
           Date().timeIntervalSince(stored.lastUpdated) < 86400 {
            timingCache[chatUsername] = (stored, Date())
            return stored
        }

        guard let profile = buildTimingProfile(chatUsername: chatUsername) else {
            // The history read failed (WeChat closed, key rotated, DB locked).
            // That is not a measurement, so it is neither cached nor written:
            // doing either used to lock the late-night hold for 24 hours on one
            // transient error, and print 「回复率0%」 as if it had been measured.
            // Held briefly so a closed WeChat does not turn every reply decision
            // into a fresh 500-message read under the reader's global lock.
            // 60s, not an hour: the next successful read must be able to land.
            let unmeasured = Self.unmeasuredTimingProfile(chatUsername: chatUsername)
            timingCache[chatUsername] = (unmeasured, Date())
            return unmeasured
        }
        timingCache[chatUsername] = (profile, Date())
        try? store.upsertReplyTimingProfile(profile)
        return profile
    }

    /// Build timing profile by analyzing "peer sent → I replied" intervals.
    /// nil means the history could not be read at all — distinct from "read, and
    /// there is nothing there".
    private func buildTimingProfile(chatUsername: String) -> ReplyTimingProfile? {
        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: chatUsername, limit: 500)
        } catch {
            return nil
        }

        let myUname = reader.myUsername()
        let myDisplay = reader.displayName(for: myUname)
        let mySelfNames = reader.mySelfNames
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
            let fromSelf = Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUname, myDisplayName: myDisplay, mySelfNames: mySelfNames)
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
            if !Self.isFromSelf(msg, chatUsername: chatUsername, myUsername: myUname, myDisplayName: myDisplay, mySelfNames: mySelfNames) {
                if Self.timePeriod(unixTime: msg.createTime) == .lateNight {
                    totalLateNightIncoming += 1
                }
            }
        }
        // Late-night replies = paired peer messages that were in late-night period
        let lateNightReplies = pairedPeerIndices.filter { idx in
            Self.timePeriod(unixTime: chronoArray[idx].createTime) == .lateNight
        }.count
        // A chat with no late-night inbound traffic was never observed — that is
        // not a measured 0%, and printing 「回复率0%」 for it would be the same
        // fabrication the loader used to commit.
        let lnReplyRate: Double? = totalLateNightIncoming > 0
            ? Double(lateNightReplies) / Double(totalLateNightIncoming)
            : nil
        // Default: silent if < 20% reply rate with sufficient data
        let silentAtNight = totalLateNightIncoming > 3 && (lnReplyRate ?? 0) < 0.2

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

    nonisolated static func unmeasuredTimingProfile(chatUsername: String) -> ReplyTimingProfile {
        let defaultDist = ReplyTimingProfile.DelayDistribution(p25: 30, p50: 60, p75: 180, count: 0)
        return ReplyTimingProfile(
            chatUsername: chatUsername,
            workHours: defaultDist,
            evening: ReplyTimingProfile.DelayDistribution(p25: 15, p50: 45, p75: 120, count: 0),
            weekend: defaultDist,
            lateNight: .zero,
            silentAtNight: true,
            lateNightReplyRate: nil,
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
