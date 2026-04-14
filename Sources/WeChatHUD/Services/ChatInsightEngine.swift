import Foundation

enum ChatInsightEngine {

    static func computeStats(
        messages: [MessageInfo],
        selfUsername: String,
        selfDisplayName: String = "",
        selfNames: Set<String> = [],
        chatUsername: String,
        chatName: String,
        isGroup: Bool,
        category: WhitelistCategory
    ) -> ChatStatsData {
        let messageCount = messages.count
        let isSelf: (MessageInfo) -> Bool = { msg in
            MessageHelpers.isFromSelf(msg, chatUsername: chatUsername, myUsername: selfUsername, myDisplayName: selfDisplayName, mySelfNames: selfNames)
        }
        let myMessageCount = messages.filter(isSelf).count
        let participants = Set(messages.map { $0.senderUsername })
        let participantCount = participants.count

        var byHour = Array(repeating: 0, count: 24)
        for m in messages {
            let date = Date(timeIntervalSince1970: Double(m.createTime))
            let hour = Calendar.current.component(.hour, from: date)
            byHour[hour] += 1
        }

        var senderCounts: [String: Int] = [:]
        for m in messages { senderCounts[m.senderName, default: 0] += 1 }
        let topSenders = senderCounts.sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }

        let othersCount = messageCount - myMessageCount
        let symmetryRatio: Double
        if messageCount == 0 {
            symmetryRatio = 1.0
        } else {
            let minC = Double(min(myMessageCount, othersCount))
            let maxC = Double(max(myMessageCount, othersCount))
            symmetryRatio = maxC > 0 ? minC / maxC : 1.0
        }

        let avgResponse = computeAvgResponseTime(messages: messages, isSelf: isSelf)

        return ChatStatsData(
            chatUsername: chatUsername,
            chatName: chatName,
            isGroup: isGroup,
            category: category,
            messageCount: messageCount,
            myMessageCount: myMessageCount,
            participantCount: participantCount,
            messagesByHour: byHour,
            avgResponseTimeSeconds: avgResponse,
            symmetryRatio: symmetryRatio,
            trend7d: 0,
            topSenders: topSenders,
            silentMembers: [],
            ignoredMessages: []
        )
    }

    private static func computeAvgResponseTime(
        messages: [MessageInfo],
        isSelf: (MessageInfo) -> Bool
    ) -> Double {
        let sorted = messages.sorted { $0.createTime < $1.createTime }
        var responseTimes: [Double] = []
        var lastOtherTime: Int?

        for m in sorted {
            if !isSelf(m) {
                lastOtherTime = m.createTime
            } else if let otherTime = lastOtherTime {
                let delta = Double(m.createTime - otherTime)
                if delta > 0 && delta < 86400 {
                    responseTimes.append(delta)
                }
                lastOtherTime = nil
            }
        }

        guard !responseTimes.isEmpty else { return 0 }
        return responseTimes.reduce(0, +) / Double(responseTimes.count)
    }

    static func detectSilence(
        historicalDailyCounts: [String: Int],
        todayCounts: [String: Int]
    ) -> [(name: String, usualDaily: Int, today: Int)] {
        var results: [(name: String, usualDaily: Int, today: Int)] = []
        for (name, usual) in historicalDailyCounts {
            guard usual >= 3 else { continue }
            let today = todayCounts[name] ?? 0
            if Double(today) < Double(usual) * 0.3 {
                results.append((name: name, usualDaily: usual, today: today))
            }
        }
        return results.sorted { $0.usualDaily > $1.usualDaily }
    }

    static func detectIgnored(
        messages: [MessageInfo],
        windowSeconds: Int = 600
    ) -> [(sender: String, text: String, time: Int)] {
        let sorted = messages.sorted { $0.createTime < $1.createTime }
        guard sorted.count >= 2 else { return [] }

        var results: [(sender: String, text: String, time: Int)] = []

        for i in 0..<(sorted.count - 1) {
            let current = sorted[i]

            // Collect distinct senders (other than the current message's sender)
            // who posted within the window after this message.
            var otherSenders = Set<String>()
            for j in (i + 1)..<sorted.count {
                let future = sorted[j]
                if future.createTime - current.createTime > windowSeconds { break }
                if future.senderUsername != current.senderUsername {
                    otherSenders.insert(future.senderUsername)
                }
            }

            // A message is "ignored" if the conversation moved on past it:
            // 2+ different participants posted (without addressing this sender),
            // indicating the thread shifted topics rather than responding.
            if otherSenders.count >= 2 {
                results.append((
                    sender: current.senderName,
                    text: current.text,
                    time: current.createTime
                ))
            }
        }

        return results
    }

    static func sortingScore(_ stats: ChatStatsData, hasActionForMe: Bool) -> Int {
        let categoryWeight: Int
        switch stats.category {
        case .work: categoryWeight = 3
        case .life: categoryWeight = 2
        case .other: categoryWeight = 1
        }
        return categoryWeight * 1000
            + stats.messageCount * 10
            + (hasActionForMe ? 500 : 0)
    }
}
