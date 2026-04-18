import Foundation

/// Pure-algorithm helpers that decide whether a message carries
/// "substantive content" — money, specific times, decisions, or
/// references to prior commitments — and whether a subsequent reply
/// from the user is merely an ack instead of a real answer.
///
/// Used by the reply-debt pipeline to surface the
/// `.unsubstantiveReply` reason: someone raised something important,
/// and the user's "嗯嗯" isn't going to cut it.
enum ImportanceDetector {

    /// Signals that a message is discussing a concrete number /
    /// amount of money. Matches Chinese + ASCII patterns:
    ///
    /// - `30万`, `1,000 元`, `¥500`, `$ 1200`, `RMB 800`
    /// - Tolerates leading/trailing whitespace and common separators.
    private static let moneyRegex = try? NSRegularExpression(
        pattern: #"""
        (?xi)
        (?:[¥$￥]\s*\d[\d,]*(?:\.\d+)?            # ¥500, $1,200.50
        |\d[\d,]*(?:\.\d+)?\s*(?:元|块|人民币|万|千|RMB|CNY|USD)
        |RMB\s*\d[\d,]*(?:\.\d+)?
        )
        """#
    )

    /// Specific time / date references that make the message
    /// actionable. Broad by design — we'd rather false-positive
    /// here than miss. The ack-only check later filters anyway.
    private static let timeMarkers: [String] = [
        "明天", "后天", "今天", "今晚", "今早", "今日", "明日",
        "下周", "下月", "本周", "本月", "周一", "周二", "周三", "周四", "周五", "周六", "周日",
        "号前", "号之前", "号以前", "日前", "日之前",
        "月底", "月初", "月中", "年底", "年初",
        "上午", "下午", "傍晚", "晚上", "中午",
        "点前", "点之前", "点钟", "点整",
        "deadline", "DDL", "ddl", "截止", "截至", "之前完成", "之前交"
    ]

    /// Markers that the message is asking for a decision or input.
    private static let decisionMarkers: [String] = [
        "要不要", "行不行", "可以吗", "可不可以", "能不能",
        "同意吗", "你看呢", "怎么办", "怎么样", "如何",
        "选哪个", "选一个", "选A", "选B", "怎么回复",
        "要吗", "需要吗", "用不用", "去不去"
    ]

    /// Markers that reference a prior commitment.
    private static let commitmentMarkers: [String] = [
        "上次说的", "之前说的", "答应过", "说过要", "说好的",
        "之前答应", "你答应", "之前承诺", "说给我",
        "欠我", "还欠", "还没", "还没有"
    ]

    /// True when the message contains at least one substantive signal.
    static func isSubstantive(_ text: String) -> Bool {
        return hasMoney(text)
            || hasTimeMarker(text)
            || hasDecisionMarker(text)
            || hasCommitmentMarker(text)
    }

    /// Returns all signals found (for UI/debugging). Empty if none.
    static func signals(_ text: String) -> [String] {
        var out: [String] = []
        if hasMoney(text)           { out.append("金额") }
        if hasTimeMarker(text)      { out.append("时间") }
        if hasDecisionMarker(text)  { out.append("决策") }
        if hasCommitmentMarker(text) { out.append("承诺引用") }
        return out
    }

    static func hasMoney(_ text: String) -> Bool {
        guard let regex = moneyRegex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    static func hasTimeMarker(_ text: String) -> Bool {
        timeMarkers.contains { text.contains($0) }
    }

    static func hasDecisionMarker(_ text: String) -> Bool {
        decisionMarkers.contains { text.contains($0) }
    }

    static func hasCommitmentMarker(_ text: String) -> Bool {
        commitmentMarkers.contains { text.contains($0) }
    }

    // MARK: - Ack-only reply detection

    /// Patterns the user types when acknowledging without actually
    /// answering. Trimmed/lowercased comparison in the checker.
    private static let ackPatterns: Set<String> = [
        "嗯", "嗯嗯", "嗯呢", "嗯好", "嗯啊",
        "好", "好的", "好好", "好哒", "好嘞", "好呢",
        "ok", "ok的", "okok", "okk", "oky",
        "收到", "知道了", "晓得了", "了解", "明白",
        "行", "行吧", "可以", "好叭", "好吧",
        "👌", "👍", "🆗", "🙏", "👏"
    ]

    /// True if `text` is, effectively, an ack — empty after trim, or
    /// one of the known ack tokens (case-insensitive), or a very
    /// short emoji-only message (≤2 grapheme clusters).
    static func isAckOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // Strip trailing punctuation that shouldn't change meaning.
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".。！!~～、，,"))
        let lower = stripped.lowercased()
        if ackPatterns.contains(lower) { return true }
        // Pure-emoji or single-grapheme responses.
        if stripped.count <= 2 {
            let isAllNonLetters = stripped.unicodeScalars.allSatisfy {
                !CharacterSet.letters.contains($0) && !CharacterSet.decimalDigits.contains($0)
            }
            if isAllNonLetters { return true }
        }
        return false
    }

    // MARK: - Combined check

    /// Result of scanning a peer message + the user's subsequent
    /// messages in the same chat.
    enum Verdict {
        /// Peer message was substantive AND the only subsequent
        /// self-reply within the window was an ack (or no reply yet,
        /// which is already handled by the reply-debt pipeline).
        case unsubstantiveReply(signals: [String])
        /// Peer message was substantive, user gave a real reply.
        case answered
        /// Peer message wasn't substantive — don't track.
        case notImportant
    }

    /// Given a single peer (inbound) message and all messages that
    /// came AFTER it in the same conversation, decide if the user
    /// failed to respond substantively.
    ///
    /// `selfMessages` must be messages flagged as from-self ordered
    /// by time; `windowSeconds` caps how far we look (ack that came
    /// 3 days later isn't useful for current triage).
    static func evaluate(
        peerMessage: MessageInfo,
        subsequentSelfMessages: [MessageInfo],
        windowSeconds: Int = 7200
    ) -> Verdict {
        let matches = signals(peerMessage.text)
        guard !matches.isEmpty else { return .notImportant }

        let cutoff = peerMessage.createTime + windowSeconds
        let repliesInWindow = subsequentSelfMessages.filter {
            $0.createTime > peerMessage.createTime && $0.createTime <= cutoff
        }

        // No reply yet — the reply-debt scorer owns this case; we
        // don't double-flag. Only flag when there IS a reply but
        // it's an ack.
        guard !repliesInWindow.isEmpty else { return .notImportant }

        let allAck = repliesInWindow.allSatisfy { isAckOnly($0.text) }
        return allAck ? .unsubstantiveReply(signals: matches) : .answered
    }
}
