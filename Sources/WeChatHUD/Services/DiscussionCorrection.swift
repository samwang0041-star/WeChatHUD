import Foundation

/// Turns durable user corrections into a small, non-chat-content feedback
/// record. The prompt/evaluation layer can consume these rows without
/// reconstructing a private conversation.
enum DiscussionCorrection {
    static func feedback(
        for item: DiscussionItem,
        status: DiscussionItemStatus
    ) -> AIFeedbackEntry? {
        switch status {
        case .done:
            return entry(item, type: .truePositive, action: "marked_done")
        case .dismissed:
            return entry(item, type: .falsePositive, action: "marked_dismissed")
        case .pending, .archived:
            return nil
        }
    }

    static func feedback(
        for item: DiscussionItem,
        correctedOwner: DiscussionItemOwner
    ) -> AIFeedbackEntry? {
        guard correctedOwner != item.owner else { return nil }
        return entry(item, type: .falsePositive, action: "owner_corrected_\(correctedOwner.rawValue)")
    }

    private static func entry(
        _ item: DiscussionItem,
        type: AIFeedbackType,
        action: String
    ) -> AIFeedbackEntry {
        let payload: [String: Any] = [
            "kind": item.kind.rawValue,
            "owner": item.owner.rawValue,
            "content": item.content,
            "confidence": item.confidence,
            "prompt_version": item.promptVersion,
            "chat_username": item.chatUsername
        ]
        let output = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return AIFeedbackEntry(
            id: 0,
            ts: Date(),
            msgUID: "discussion_item:\(item.id)",
            feedbackType: type,
            originalOutput: output,
            userAction: action,
            note: item.chatUsername
        )
    }

    /// Compact hint for later extraction runs in the same chat. Old rows
    /// without a chat note are intentionally ignored.
    static func hint(entries: [AIFeedbackEntry], chatUsername: String, limit: Int = 8) -> String {
        let labels = entries
            .sorted { $0.ts > $1.ts }
            .filter { $0.note == chatUsername }
            .suffix(limit)
            .map { entry -> String in
                switch entry.userAction {
                case "owner_corrected_mine": return "责任人改为我要做"
                case "owner_corrected_theirs": return "责任人改为对方"
                case "owner_corrected_shared": return "责任人改为双方"
                case "marked_done": return "确认完成"
                case "marked_dismissed": return "确认忽略"
                default: return entry.userAction ?? "用户修正"
                }
            }
        guard !labels.isEmpty else { return "暂无" }
        return labels.joined(separator: "；")
    }
}
