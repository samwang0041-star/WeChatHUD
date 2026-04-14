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

    // MARK: - Global Overview

    struct GlobalOverview {
        // Volume
        let totalMessages: Int
        let myMessages: Int
        let activeChats: Int
        let totalChats: Int
        let participants: Int
        let messagesByHour: [Int]           // 24 buckets

        // Response health
        let avgResponseSeconds: Double      // my avg response time to others
        let responseRate: Double            // % of inbound messages I replied to
        let overdueChats: Int               // chats where I haven't replied in time

        // Communication balance
        let myRatio: Double                 // my messages / total
        let topContacts: [(name: String, count: Int, isGroup: Bool)]  // top 10
        let oneWayChats: [(name: String, theirCount: Int, myCount: Int)]  // mostly them
        let neglectedVIPs: [(name: String, lastMsgAge: Int)]  // VIPs with no recent msg

        // Work/life
        let workMessages: Int
        let lifeMessages: Int
        let otherMessages: Int
        let afterHoursRatio: Double         // messages outside 9-18 / total
        let workHourMessages: Int           // 9-18
        let eveningMessages: Int            // 18-23
        let nightMessages: Int              // 23-6
        let morningMessages: Int            // 6-9

        // Category by chat type
        let groupMessages: Int
        let privateMessages: Int
        let groupChats: Int
        let privateChats: Int

        // Commitments
        let pendingCommitments: Int
        let overdueCommitments: Int
        let fulfilledCommitments: Int

        // Relationship network
        let tierDistribution: [(tier: String, count: Int)]  // VIP/whitelist/greylist
        let roleDistribution: [(role: String, count: Int)]  // boss/colleague/client/...

        // Engagement
        let busiestHour: Int
        let quietestHour: Int               // min non-zero hour
        let avgMessagesPerChat: Double
        let mostSymmetric: (name: String, ratio: Double)?   // healthiest conversation
        let leastSymmetric: (name: String, ratio: Double)?  // most one-sided
    }

    static func computeGlobalOverview(
        allStats: [String: ChatStatsData],
        contacts: [ContactEntry],
        commitments: [Commitment],
        replyDebtItems: [ReplyDebtItem],
        vipUsernames: Set<String>,
        selfUsernames: Set<String> = [],
        now: Date = Date()
    ) -> GlobalOverview {
        let statsArr = Array(allStats.values)
        let totalMessages = statsArr.reduce(0) { $0 + $1.messageCount }
        let myMessages = statsArr.reduce(0) { $0 + $1.myMessageCount }
        let activeChats = statsArr.filter { $0.messageCount > 0 }.count
        let totalChats = allStats.count
        let allParticipants = Set(statsArr.flatMap { $0.topSenders.map(\.name) })

        // Hourly aggregation
        var hourly = Array(repeating: 0, count: 24)
        for s in statsArr { for i in 0..<24 { hourly[i] += s.messagesByHour[i] } }

        // Response health
        let responseTimes = statsArr.compactMap { $0.avgResponseTimeSeconds > 0 ? $0.avgResponseTimeSeconds : nil }
        let avgResponse = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count)
        let inbound = totalMessages - myMessages
        let responseRate = inbound > 0 ? min(Double(myMessages) / Double(inbound), 1.0) : 0
        let overdueChats = replyDebtItems.filter { $0.reasons.contains(where: { $0.code == .overdue }) }.count

        // Communication balance
        let topContacts = statsArr
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(10)
            .map { (name: $0.chatName, count: $0.messageCount, isGroup: $0.isGroup) }

        let oneWay = statsArr.filter { s in
            let others = s.messageCount - s.myMessageCount
            return others > 10 && s.myMessageCount < others / 4
        }.map { (name: $0.chatName, theirCount: $0.messageCount - $0.myMessageCount, myCount: $0.myMessageCount) }

        // Neglected VIPs: VIP contacts with no messages or very old
        let nowTs = Int(now.timeIntervalSince1970)
        let neglectedVIPs = vipUsernames.compactMap { vip -> (name: String, lastMsgAge: Int)? in
            guard let s = allStats[vip] else { return nil }
            if s.messageCount == 0 { return (name: s.chatName, lastMsgAge: 999999) }
            return nil
        }

        // Work/life
        let workCount = statsArr.filter { $0.category == .work }.reduce(0) { $0 + $1.messageCount }
        let lifeCount = statsArr.filter { $0.category == .life }.reduce(0) { $0 + $1.messageCount }
        let otherCount = statsArr.filter { $0.category == .other }.reduce(0) { $0 + $1.messageCount }

        let workHourMsgs = (9..<18).reduce(0) { $0 + hourly[$1] }
        let eveningMsgs = (18..<23).reduce(0) { $0 + hourly[$1] }
        let nightMsgs = (0..<6).reduce(0) { $0 + hourly[$1] } + hourly[23]
        let morningMsgs = (6..<9).reduce(0) { $0 + hourly[$1] }
        let afterHours = totalMessages > 0 ? Double(eveningMsgs + nightMsgs) / Double(totalMessages) : 0

        // Chat type
        let groupMsgs = statsArr.filter { $0.isGroup }.reduce(0) { $0 + $1.messageCount }
        let privateMsgs = statsArr.filter { !$0.isGroup }.reduce(0) { $0 + $1.messageCount }
        let groupChats = statsArr.filter { $0.isGroup && $0.messageCount > 0 }.count
        let privateChats = statsArr.filter { !$0.isGroup && $0.messageCount > 0 }.count

        // Commitments
        let pending = commitments.filter { $0.status == .pending }.count
        let overdue = commitments.filter { $0.status == .overdue }.count
        let fulfilled = commitments.filter { $0.status == .fulfilled }.count

        // Relationship network
        var tierCounts: [String: Int] = [:]
        var roleCounts: [String: Int] = [:]
        for c in contacts {
            tierCounts[c.attentionLevel.label, default: 0] += 1
            roleCounts[c.role.label, default: 0] += 1
        }
        let tierDist = tierCounts.sorted { $0.value > $1.value }.map { (tier: $0.key, count: $0.value) }
        let roleDist = roleCounts.sorted { $0.value > $1.value }.map { (role: $0.key, count: $0.value) }

        // Engagement
        let nonZeroHours = hourly.enumerated().filter { $0.element > 0 }
        let busiestHour = nonZeroHours.max(by: { $0.element < $1.element })?.offset ?? 0
        let quietestHour = nonZeroHours.min(by: { $0.element < $1.element })?.offset ?? 0
        let avgPerChat = activeChats > 0 ? Double(totalMessages) / Double(activeChats) : 0

        let symmetricStats = statsArr.filter {
            $0.messageCount >= 5 && !$0.isGroup
            && !selfUsernames.contains($0.chatUsername)
            && $0.myMessageCount > 0 && $0.myMessageCount < $0.messageCount  // exclude one-sided
        }
        let mostSymmetric = symmetricStats.max(by: { $0.symmetryRatio < $1.symmetryRatio })
            .map { (name: $0.chatName, ratio: $0.symmetryRatio) }
        let leastSymmetric = symmetricStats.filter { $0.symmetryRatio < 0.9 }
            .min(by: { $0.symmetryRatio < $1.symmetryRatio })
            .map { (name: $0.chatName, ratio: $0.symmetryRatio) }

        return GlobalOverview(
            totalMessages: totalMessages,
            myMessages: myMessages,
            activeChats: activeChats,
            totalChats: totalChats,
            participants: allParticipants.count,
            messagesByHour: hourly,
            avgResponseSeconds: avgResponse,
            responseRate: min(responseRate, 1),
            overdueChats: overdueChats,
            myRatio: totalMessages > 0 ? Double(myMessages) / Double(totalMessages) : 0,
            topContacts: Array(topContacts),
            oneWayChats: oneWay,
            neglectedVIPs: neglectedVIPs,
            workMessages: workCount,
            lifeMessages: lifeCount,
            otherMessages: otherCount,
            afterHoursRatio: afterHours,
            workHourMessages: workHourMsgs,
            eveningMessages: eveningMsgs,
            nightMessages: nightMsgs,
            morningMessages: morningMsgs,
            groupMessages: groupMsgs,
            privateMessages: privateMsgs,
            groupChats: groupChats,
            privateChats: privateChats,
            pendingCommitments: pending,
            overdueCommitments: overdue,
            fulfilledCommitments: fulfilled,
            tierDistribution: tierDist,
            roleDistribution: roleDist,
            busiestHour: busiestHour,
            quietestHour: quietestHour,
            avgMessagesPerChat: avgPerChat,
            mostSymmetric: mostSymmetric,
            leastSymmetric: leastSymmetric
        )
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
