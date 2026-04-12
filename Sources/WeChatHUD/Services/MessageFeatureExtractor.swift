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
