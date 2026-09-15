import Foundation

enum DetectedMediaType: String {
    case text, image, voice, file, link, sticker, system
}

struct MessageFeatures {
    let hasQuestionMark: Bool
    let hasSecondPerson: Bool
    let hasRequestVerb: Bool
    let hasTimeReference: Bool
    let hasUrgencyWord: Bool
    let hasCommitmentSignal: Bool
    let detectedMediaType: DetectedMediaType
    let messageLength: Int
}

enum MessageFeatureExtractor {
    private static let questionMarks: Set<Character> = ["?", "？", "❓"]
    private static let secondPersonWords = ["你", "您", "你们"]
    private static let requestVerbs = ["帮", "请", "麻烦", "发", "给", "看看", "确认", "回复", "处理", "安排", "跟进", "协调", "转发", "审批", "签字"]
    private static let timeWords = ["明天", "后天", "下周", "今天", "今天内", "月底", "周五", "周一", "周二", "周三", "周四", "周六", "周日", "下个月", "尽快", "马上", "立即", "稍后", "一会儿", "等会", "今晚", "明早", "上午", "下午", "晚上"]
    private static let urgencyWords = ["紧急", "急", "尽快", "ASAP", "马上", "立即", "催", "截止", "deadline", "赶紧", "加急", "着急"]
    private static let commitmentSignals = ["我去", "我来", "我发", "我问", "我看看", "我处理", "我安排", "我跟进", "我确认", "帮你", "给你", "发你", "回头", "等我", "好的", "没问题", "可以", "行", "OK", "ok", "收到", "了解", "明天给", "下周给"]

    /// Outgoing message is the user asking the current peer, not promising to
    /// do something for them. "问一下报价" is an inquiry; "我去问一下老板再回你"
    /// is a follow-up commitment and must not match.
    static func isOutgoingInquiryToPeer(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if hasSelfFollowupCommitment(trimmed) { return false }

        if trimmed.hasSuffix("？") || trimmed.hasSuffix("?") { return true }
        if opensAsInquiry(trimmed) { return true }
        if ["吗", "么"].contains(where: { trimmed.hasSuffix($0) }) { return true }

        if trimmed.hasSuffix("呢") {
            return hasQuestionStem(trimmed)
        }

        return hasQuestionPhrase(trimmed)
    }

    /// First-person follow-up that turns a question into "I'll ask someone
    /// else, then come back to you". Keep this tighter than "我发/我问":
    /// "问一下我发的那个" is still an inquiry to the peer.
    static func hasSelfFollowupCommitment(_ text: String) -> Bool {
        let markers = [
            "我去", "我明天", "我今天内", "我稍后",
            "回头告诉", "回头回你", "回头回您",
            "再回你", "再回您", "回你一声", "回您一声",
            "我处理", "我安排", "我跟进", "我确认下", "我确认一下",
            "之后回你", "之后回您", "之后回复你", "之后回复您"
        ]
        return markers.contains(where: { text.contains($0) })
    }

    private static let inquiryPrefixes = [
        "问一下", "问下", "请问", "咨询一下", "咨询下",
        "打听一下", "打听下", "请教一下", "请教下",
        "想问", "想请问", "想了解"
    ]

    private static func opensAsInquiry(_ text: String) -> Bool {
        let bodies: [String]
        if text.hasPrefix("我") {
            bodies = [text, String(text.dropFirst())]
        } else {
            bodies = [text]
        }
        if bodies.contains(where: { body in
            inquiryPrefixes.contains(where: { body.hasPrefix($0) })
        }) {
            return true
        }
        // "我来问一下" = asking the current peer; "我去问一下" is handled as a follow-up.
        if text.hasPrefix("我来问") { return true }
        // "谢潘，问一下报价" — inquiry after a vocative pause.
        let paused = inquiryPrefixes.flatMap { prefix in
            ["，" + prefix, "," + prefix, "。" + prefix]
        }
        return paused.contains(where: { text.contains($0) })
    }

    private static func hasQuestionStem(_ text: String) -> Bool {
        ["什么", "怎么", "哪", "谁", "几", "多少", "为啥", "为何", "为什"].contains(where: { text.contains($0) })
    }

    private static func hasQuestionPhrase(_ text: String) -> Bool {
        let phrases = [
            "怎么样", "多少钱", "什么时候", "哪天", "怎么卖", "什么情况",
            "能否", "可否", "是否"
        ]
        if phrases.contains(where: { text.contains($0) }) { return true }
        // "如何" is a question word; "无论如何" is not.
        if text.contains("如何"), !text.contains("无论如何") { return true }
        return false
    }

    /// Saved commitment/todo that inverted "I asked them" into "I will go ask, then reply".
    static func isInvertedInquiryRecord(sourceText: String, summary: String) -> Bool {
        // Only the original message can be classified as an inquiry. The AI
        // summary often contains 是否/什么时候 because it describes a task
        // ("确认是否周五交货"), which is a real commitment.
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isOutgoingInquiryToPeer(sourceText) {
            return true
        }
        return isInvertedAskThenReplySummary(summary)
            && !hasSelfFollowupCommitment(sourceText)
    }

    /// Rewrite a persisted discussion row that treated the user's question as their todo.
    static func repairedInquiryDiscussion(
        kind: DiscussionItemKind,
        owner: DiscussionItemOwner,
        content: String
    ) -> (kind: DiscussionItemKind, owner: DiscussionItemOwner, content: String)? {
        guard owner == .mine,
              kind == .todo || kind == .decision || kind == .question else { return nil }
        // Content is an extracted summary, not the original utterance.
        // "确认是否周五交货" is a real todo; only the inverted "去问…之后回复"
        // shape is safe to rewrite without the source message.
        let inverted = isInvertedAskThenReplySummary(content)
        guard inverted else { return nil }
        return (.question, .theirs, cleanedInquiryContent(content))
    }

    static func isInvertedAskThenReplySummary(_ content: String) -> Bool {
        if hasSelfFollowupCommitment(content) { return false }
        let reply = ["之后回复", "然后再回", "再回复", "之后回"].contains(where: { content.contains($0) })
        let ask = content.contains("去问") || content.contains("问一下") || content.contains("打听")
        return reply && ask
    }

    static func cleanedInquiryContent(_ content: String) -> String {
        var text = content
        for marker in ["，之后回复", "，然后再回", "，再回复", "，之后回", " 之后回复"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
                break
            }
        }
        if text.hasPrefix("去问") {
            text = "问" + text.dropFirst(2)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extract(_ text: String) -> MessageFeatures {
        MessageFeatures(
            hasQuestionMark: text.contains(where: { questionMarks.contains($0) }),
            hasSecondPerson: secondPersonWords.contains(where: { text.contains($0) }),
            hasRequestVerb: requestVerbs.contains(where: { text.contains($0) }),
            hasTimeReference: timeWords.contains(where: { text.contains($0) }),
            hasUrgencyWord: urgencyWords.contains(where: { text.contains($0) }),
            hasCommitmentSignal: commitmentSignals.contains(where: { text.contains($0) }),
            detectedMediaType: detectMediaType(text),
            messageLength: text.count
        )
    }

    private static func detectMediaType(_ text: String) -> DetectedMediaType {
        if text.hasPrefix("[图片]") || text.hasPrefix("<img") { return .image }
        if text.hasPrefix("[语音]") || text.hasPrefix("[语音消息]") { return .voice }
        if text.hasPrefix("[文件]") { return .file }
        if text.contains("http://") || text.contains("https://") || text.contains("mp.weixin.qq.com") { return .link }
        if text.hasPrefix("[动画表情]") || text.hasPrefix("[表情]") { return .sticker }
        if text.hasPrefix("[系统消息]") || text.contains("拍了拍") || text.contains("撤回了一条消息") { return .system }
        return .text
    }
}
