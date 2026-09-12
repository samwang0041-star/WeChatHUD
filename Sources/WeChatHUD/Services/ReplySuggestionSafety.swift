import Foundation

/// Shared safety gate for reply suggestions. The model is allowed to draft
/// wording; it is not allowed to invent a personal decision (vaccinate or
/// not, already signed a relay, pay, resign) that the user has not said.
enum ReplySuggestionSafety {
    static let semanticSourceKeywords: [String] = [
        "报价", "付款", "打款", "支付", "签", "签字", "签约",
        "审批", "批准", "同意", "可以吗", "能不能", "确认付款",
        "合同", "发票", "人事", "离职", "辞退", "医疗", "法务",
        "疫苗", "接种", "流感", "体检", "手术", "处方", "过敏"
    ]

    static func sourceHasSensitiveSignal(
        _ texts: [String],
        extraKeywords: [String] = []
    ) -> Bool {
        containsAnyKeyword(
            texts.joined(separator: "\n"),
            keywords: extraKeywords + semanticSourceKeywords
        )
    }

    static func allows(
        text: String,
        intent: String?,
        sourceHasSensitiveSignal: Bool
    ) -> Bool {
        guard sourceHasSensitiveSignal else { return true }
        let normalizedIntent = intent?.lowercased() ?? ""
        let highCommitment: Set<String> = ["accept", "decline"]
        return !highCommitment.contains(normalizedIntent)
            && isConservativeHandoff(text)
    }

    static func sanitize(
        _ replies: [SuggestedReply],
        sourceTexts: [String],
        extraKeywords: [String] = []
    ) -> [SuggestedReply] {
        let sensitive = sourceHasSensitiveSignal(sourceTexts, extraKeywords: extraKeywords)
        let kept = replies.filter {
            allows(text: $0.text, intent: nil, sourceHasSensitiveSignal: sensitive)
        }
        if kept.isEmpty && sensitive {
            return [
                SuggestedReply(
                    text: "我确认下再回你",
                    tone: "recommended",
                    recommended: true,
                    rationale: "涉及需你本人确认的事项"
                )
            ]
        }
        return kept
    }

    static func containsAnyKeyword(_ text: String, keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        let lower = text.lowercased()
        return keywords.contains { keyword in
            !keyword.isEmpty && lower.contains(keyword.lowercased())
        }
    }

    static func isConservativeHandoff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 30 else { return false }
        let allowPatterns = ["看下", "确认", "核实", "晚点", "稍后", "回你", "再回", "查一下"]
        let denyPatterns = ["可以", "没问题", "同意", "确认签", "转", "汇", "付款", "报价", "辞退", "离职"]
        return allowPatterns.contains { trimmed.contains($0) }
            && !denyPatterns.contains { trimmed.contains($0) }
    }
}
