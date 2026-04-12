import Foundation

struct ConversationSegment {
    let startTime: Int
    let endTime: Int
    let messages: [MessageInfo]
    let participants: Set<String>
    var messageCount: Int { messages.count }
    var durationSeconds: Int { max(endTime - startTime, 1) }
}

enum ConversationSegmenter {
    static let privateGapThreshold: Int = 7200   // 2 hours
    static let groupGapThreshold: Int = 1800     // 30 minutes

    /// Split messages into conversation segments. Messages MUST be sorted by createTime ASC.
    static func segment(_ messages: [MessageInfo], chatType: ChatType) -> [ConversationSegment] {
        guard !messages.isEmpty else { return [] }
        let gapThreshold = chatType == .privateChat ? privateGapThreshold : groupGapThreshold
        var segments: [ConversationSegment] = []
        var currentBatch: [MessageInfo] = [messages[0]]

        for i in 1..<messages.count {
            let gap = messages[i].createTime - messages[i - 1].createTime
            let shouldSplit: Bool
            if gap >= gapThreshold {
                shouldSplit = true
            } else if chatType == .group && currentBatch.count >= 10 {
                // Check participant shift
                let recentParticipants = Set(currentBatch.suffix(5).map(\.senderUsername))
                let upcomingRange = max(0, i-2)...min(messages.count-1, i+2)
                let nextParticipants = Set(messages[upcomingRange].map(\.senderUsername))
                let overlap = recentParticipants.intersection(nextParticipants).count
                let total = recentParticipants.union(nextParticipants).count
                let overlapRatio = total > 0 ? Double(overlap) / Double(total) : 1.0
                shouldSplit = overlapRatio < 0.3 && gap >= 300
            } else {
                shouldSplit = false
            }

            if shouldSplit {
                segments.append(makeSegment(currentBatch))
                currentBatch = [messages[i]]
            } else {
                currentBatch.append(messages[i])
            }
        }
        if !currentBatch.isEmpty {
            segments.append(makeSegment(currentBatch))
        }
        return segments
    }

    /// Find the segment containing the given message time.
    static func findSegment(for messageTime: Int, in segments: [ConversationSegment]) -> ConversationSegment? {
        segments.first { $0.startTime <= messageTime && $0.endTime >= messageTime }
            ?? segments.min(by: { abs($0.endTime - messageTime) < abs($1.endTime - messageTime) })
    }

    private static func makeSegment(_ messages: [MessageInfo]) -> ConversationSegment {
        ConversationSegment(
            startTime: messages.first!.createTime,
            endTime: messages.last!.createTime,
            messages: messages,
            participants: Set(messages.map(\.senderUsername))
        )
    }
}
