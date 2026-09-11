import Foundation

/// AI role determining context window sizing.
enum ContextRole {
    case classifier           // max 20
    case commitmentTracker    // max 8
    case contextAnalyzer      // max 50
    case replyGenerator       // max 30
    case vipAggregator        // max 80
    case groupDigestor        // max 200
    case retrospector         // 0 (uses AI outputs, not raw messages)
    case autopilot            // max 15

    var maxMessages: Int {
        switch self {
        case .classifier: return 20
        case .commitmentTracker: return 8
        case .contextAnalyzer: return 50
        case .replyGenerator: return 30
        case .vipAggregator: return 80
        case .groupDigestor: return 200
        case .retrospector: return 0
        case .autopilot: return 15
        }
    }

    var lookBehind: Int {
        switch self {
        case .classifier: return 10
        case .commitmentTracker: return 5
        case .contextAnalyzer: return 40
        case .replyGenerator: return 15
        case .vipAggregator: return 3
        case .groupDigestor: return 0
        case .retrospector: return 0
        case .autopilot: return 10
        }
    }

    var lookAhead: Int {
        switch self {
        case .classifier: return 2
        case .commitmentTracker: return 0
        case .contextAnalyzer: return 5
        case .replyGenerator: return 2
        case .vipAggregator: return 1
        case .groupDigestor: return 0
        case .retrospector: return 0
        case .autopilot: return 2
        }
    }
}

/// Message annotated with sender role for prompt injection.
struct AnnotatedMessage: Identifiable {
    let id: String
    let senderUsername: String
    let senderName: String
    let senderLevel: AttentionLevel?
    let senderRole: ContactRole?
    let text: String
    let createTime: Int
    let isTarget: Bool
}

/// Assembled context window ready for prompt embedding.
struct ContextWindow {
    let messages: [AnnotatedMessage]
    let chatType: ChatType
    let role: ContextRole

    func serialize() -> String {
        messages.map { msg in
            let time = MessageInfo.formatRelative(msg.createTime)
            let roleTag: String
            if let level = msg.senderLevel, let role = msg.senderRole {
                roleTag = "[\(level.label)/\(role.label)]"
            } else {
                roleTag = ""
            }
            let marker = msg.isTarget ? " ← 目标消息" : ""
            return "[\(time)] \(roleTag)\(msg.senderName): \(AIService.sanitizeForAI(msg.text))\(marker)"
        }.joined(separator: "\n")
    }
}

enum ContextWindowBuilder {
    typealias ContactLookup = (String) -> (AttentionLevel, ContactRole)?

    /// Build a window around `target`.
    ///
    /// `allMessages` may arrive in EITHER order. `WeChatReader.getMessages`
    /// defaults to `oldestFirst: false`, i.e. newest-first, while this builder
    /// slices by *index* around the target (`targetIdx - lookBehind` …
    /// `targetIdx + lookAhead`) and `serialize()` renders that slice in array
    /// order — both of which only mean "before/after" and "chronological" if
    /// the input is oldest-first. Callers that skipped the sort silently got a
    /// reversed window: the reply generator asked for 15 messages behind the
    /// target and received the newest few in reverse order, and the commitment
    /// extractor saw its look-behind as look-ahead. Sorting here makes the
    /// contract structural instead of a convention each caller has to remember.
    static func build(
        target: MessageInfo,
        role: ContextRole,
        allMessages: [MessageInfo],
        chatType: ChatType,
        contactLookup: ContactLookup
    ) -> ContextWindow {
        guard !allMessages.isEmpty else {
            return ContextWindow(messages: [], chatType: chatType, role: role)
        }

        // Same tie-break as the reader's own `ORDER BY create_time, local_id`,
        // so messages sharing a second keep their real sequence.
        let ordered = allMessages.sorted {
            $0.createTime == $1.createTime ? $0.localId < $1.localId : $0.createTime < $1.createTime
        }

        let targetIdx = ordered.firstIndex(where: { $0.id == target.id }) ?? ordered.count - 1
        let start = max(0, targetIdx - role.lookBehind)
        let end = min(ordered.count - 1, targetIdx + role.lookAhead)
        let slice = Array(ordered[start...end])

        let annotated = slice.map { msg -> AnnotatedMessage in
            let lookup = contactLookup(msg.senderUsername)
            return AnnotatedMessage(
                id: msg.id,
                senderUsername: msg.senderUsername,
                senderName: msg.senderName,
                senderLevel: lookup?.0,
                senderRole: lookup?.1,
                text: msg.text,
                createTime: msg.createTime,
                isTarget: msg.id == target.id
            )
        }

        let limited: [AnnotatedMessage]
        if annotated.count > role.maxMessages {
            let targetPos = annotated.firstIndex(where: { $0.isTarget }) ?? annotated.count - 1
            let keepFromEnd = min(role.maxMessages, annotated.count - targetPos)
            let keepFromStart = role.maxMessages - keepFromEnd
            let startSlice = Array(annotated.prefix(keepFromStart))
            let endSlice = Array(annotated.suffix(keepFromEnd))
            limited = startSlice + endSlice
        } else {
            limited = annotated
        }

        return ContextWindow(messages: limited, chatType: chatType, role: role)
    }
}
