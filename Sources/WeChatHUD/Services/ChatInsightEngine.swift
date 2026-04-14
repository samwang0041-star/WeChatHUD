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
            messagesByWeekday: [],
            typeCounts: [:],
            avgResponseTimeSeconds: avgResponse,
            symmetryRatio: symmetryRatio,
            trend7d: 0,
            topSenders: topSenders,
            silentMembers: [],
            ignoredMessages: [],
            selfInitiated: false,
            earliestTs: 0,
            latestTs: 0
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
        // D1: Communication Profile
        let totalMessages: Int
        let myMessages: Int
        let activeChats: Int
        let totalChats: Int
        let participants: Int
        let messagesByHour: [Int]           // 24 buckets
        let myRatio: Double                 // my messages / total
        let initiationRate: Double          // % of chats where I sent first message
        let groupMessages: Int
        let privateMessages: Int
        let groupChats: Int
        let privateChats: Int
        let typeDistribution: [(type: String, count: Int)]  // text/image/file/voice/...

        // D2: Time Patterns
        let messagesByWeekday: [Int]        // 7 buckets (Sun=0)
        let workHourMessages: Int           // 9-18
        let eveningMessages: Int            // 18-23
        let nightMessages: Int              // 23-6
        let morningMessages: Int            // 6-9
        let afterHoursRatio: Double
        let busiestHour: Int
        let busiestWeekday: Int
        let weekdayTotal: Int               // Mon-Fri total
        let weekendTotal: Int               // Sat-Sun total

        // D3: Response Health
        let avgResponseSeconds: Double
        let responseRate: Double
        let overdueChats: Int

        // D4: Relationship Network
        let topContacts: [(name: String, count: Int, isGroup: Bool)]
        let oneWayChats: [(name: String, theirCount: Int, myCount: Int)]
        let neglectedVIPs: [(name: String, lastMsgAge: Int)]
        let tierDistribution: [(tier: String, count: Int)]
        let roleDistribution: [(role: String, count: Int)]
        let mostSymmetric: (name: String, ratio: Double)?
        let leastSymmetric: (name: String, ratio: Double)?

        // D5: Work/Life Balance
        let workMessages: Int
        let lifeMessages: Int
        let otherMessages: Int
        let workAfterHoursCount: Int        // work-category messages outside 9-18
        let boundaryScore: Int              // 0-100, higher = healthier boundary

        // D6: Influence
        let atMentionChats: Int             // chats where I'm @-mentioned
        let superiorMessages: Int           // messages with boss/superior contacts
        let subordinateMessages: Int
        let peerMessages: Int
        let externalMessages: Int           // client/supplier
        let personalMessages: Int           // family/friend
        let activeGroupCount: Int           // groups where I sent messages

        // D7: Commitment Reliability
        let pendingCommitments: Int
        let overdueCommitments: Int
        let fulfilledCommitments: Int
        let commitmentCompletionRate: Double  // fulfilled / (fulfilled + overdue)

        // D8: Attention Distribution
        let vipMessageRatio: Double         // VIP messages / total
        let topTimeBlackHoles: [(name: String, count: Int)]  // chats consuming most time
        let neglectedHighValue: [(name: String, role: String)]  // important but low interaction

        // D9: Communication Style
        let avgMessagesPerChat: Double

        // D10: Pressure Signals
        let pendingAsks: Int
        let urgentAsks: Int
        let recalledMessages: Int
        let recentDensityRatio: Double      // last 7d daily avg / overall daily avg
    }

    static func computeGlobalOverview(
        allStats: [String: ChatStatsData],
        contacts: [ContactEntry],
        commitments: [Commitment],
        replyDebtItems: [ReplyDebtItem],
        vipUsernames: Set<String>,
        selfUsernames: Set<String> = [],
        pendingAskCount: Int = 0,
        urgentAskCount: Int = 0,
        recalledMessageCount: Int = 0,
        windowDays: Int = 30,
        now: Date = Date()
    ) -> GlobalOverview {
        let statsArr = Array(allStats.values)
        let totalMessages = statsArr.reduce(0) { $0 + $1.messageCount }
        let myMessages = statsArr.reduce(0) { $0 + $1.myMessageCount }
        let activeChats = statsArr.filter { $0.messageCount > 0 }.count
        let totalChats = allStats.count
        let allParticipants = Set(statsArr.flatMap { $0.topSenders.map(\.name) })

        // D1: Communication Profile
        var hourly = Array(repeating: 0, count: 24)
        for s in statsArr { for i in 0..<24 { hourly[i] += s.messagesByHour[i] } }

        let initiatedCount = statsArr.filter { $0.selfInitiated && $0.messageCount > 0 }.count
        let initiationRate = activeChats > 0 ? Double(initiatedCount) / Double(activeChats) : 0

        let groupMsgs = statsArr.filter { $0.isGroup }.reduce(0) { $0 + $1.messageCount }
        let privateMsgs = statsArr.filter { !$0.isGroup }.reduce(0) { $0 + $1.messageCount }
        let groupChatCount = statsArr.filter { $0.isGroup && $0.messageCount > 0 }.count
        let privateChatCount = statsArr.filter { !$0.isGroup && $0.messageCount > 0 }.count

        // Message type distribution
        var globalTypes: [Int: Int] = [:]
        for s in statsArr { for (t, c) in s.typeCounts { globalTypes[t, default: 0] += c } }
        let typeNames: [Int: String] = [1: "文字", 3: "图片", 34: "语音", 43: "视频", 47: "表情", 48: "位置", 49: "链接/文件", 50: "通话", 10000: "系统"]
        let typeDist = globalTypes.sorted { $0.value > $1.value }
            .map { (type: typeNames[$0.key] ?? "其他(\($0.key))", count: $0.value) }

        // D2: Time Patterns
        var wkday = Array(repeating: 0, count: 7)
        for s in statsArr where !s.messagesByWeekday.isEmpty {
            for i in 0..<7 { wkday[i] += s.messagesByWeekday[i] }
        }
        let workHourMsgs = (9..<18).reduce(0) { $0 + hourly[$1] }
        let eveningMsgs = (18..<23).reduce(0) { $0 + hourly[$1] }
        let nightMsgs = (0..<6).reduce(0) { $0 + hourly[$1] } + hourly[23]
        let morningMsgs = (6..<9).reduce(0) { $0 + hourly[$1] }
        let afterHours = totalMessages > 0 ? Double(eveningMsgs + nightMsgs) / Double(totalMessages) : 0
        let busiestHour = hourly.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let busiestWeekday = wkday.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let weekdayTotal = wkday[1] + wkday[2] + wkday[3] + wkday[4] + wkday[5]  // Mon-Fri
        let weekendTotal = wkday[0] + wkday[6]  // Sun + Sat

        // D3: Response Health
        let responseTimes = statsArr.compactMap { $0.avgResponseTimeSeconds > 0 ? $0.avgResponseTimeSeconds : nil }
        let avgResponse = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count)
        let inbound = totalMessages - myMessages
        let responseRate = inbound > 0 ? min(Double(myMessages) / Double(inbound), 1.0) : 0
        let overdueChats = replyDebtItems.filter { $0.reasons.contains(where: { $0.code == .overdue }) }.count

        // D4: Relationship Network
        let topContacts = statsArr.sorted { $0.messageCount > $1.messageCount }.prefix(10)
            .map { (name: $0.chatName, count: $0.messageCount, isGroup: $0.isGroup) }
        let oneWay = statsArr.filter { s in
            let others = s.messageCount - s.myMessageCount
            return others > 10 && s.myMessageCount < others / 4
        }.map { (name: $0.chatName, theirCount: $0.messageCount - $0.myMessageCount, myCount: $0.myMessageCount) }
        let neglectedVIPs = vipUsernames.compactMap { vip -> (name: String, lastMsgAge: Int)? in
            guard let s = allStats[vip], s.messageCount == 0 else { return nil }
            return (name: s.chatName, lastMsgAge: 999999)
        }
        var tierCounts: [String: Int] = [:]
        var roleCounts: [String: Int] = [:]
        for c in contacts { tierCounts[c.attentionLevel.label, default: 0] += 1; roleCounts[c.role.label, default: 0] += 1 }
        let symmetricStats = statsArr.filter {
            $0.messageCount >= 5 && !$0.isGroup && !selfUsernames.contains($0.chatUsername)
            && $0.myMessageCount > 0 && $0.myMessageCount < $0.messageCount
        }
        let mostSym = symmetricStats.max(by: { $0.symmetryRatio < $1.symmetryRatio }).map { (name: $0.chatName, ratio: $0.symmetryRatio) }
        let leastSym = symmetricStats.filter { $0.symmetryRatio < 0.9 }.min(by: { $0.symmetryRatio < $1.symmetryRatio }).map { (name: $0.chatName, ratio: $0.symmetryRatio) }

        // D5: Work/Life Balance
        let workCount = statsArr.filter { $0.category == .work }.reduce(0) { $0 + $1.messageCount }
        let lifeCount = statsArr.filter { $0.category == .life }.reduce(0) { $0 + $1.messageCount }
        let otherCount = statsArr.filter { $0.category == .other }.reduce(0) { $0 + $1.messageCount }
        // Work messages outside 9-18
        let workAfterHours = statsArr.filter { $0.category == .work }.reduce(0) { total, s in
            let offHours = (0..<9).reduce(0) { $0 + s.messagesByHour[$1] } + (18..<24).reduce(0) { $0 + s.messagesByHour[$1] }
            return total + offHours
        }
        // Boundary score: 100 = perfect separation, 0 = always working
        let boundaryScore: Int
        if workCount == 0 { boundaryScore = 100 }
        else { boundaryScore = max(0, 100 - Int(Double(workAfterHours) / Double(max(workCount, 1)) * 100)) }

        // D6: Influence
        let contactMap = Dictionary(uniqueKeysWithValues: contacts.map { ($0.username, $0) })
        let profileMap = Dictionary(uniqueKeysWithValues: contacts.compactMap { c -> (String, RelationshipProfile.Hierarchy)? in
            // Use role to infer hierarchy
            switch c.role {
            case .boss, .keyClient: return (c.username, .superior)
            case .colleague, .friend: return (c.username, .peer)
            case .family, .partner: return (c.username, .personal)
            case .client, .supplier: return (c.username, .external)
            case .acquaintance, .groupOnly, .service: return (c.username, .peer)
            }
        })
        var superiorMsgs = 0, subordinateMsgs = 0, peerMsgs = 0, externalMsgs = 0, personalMsgs = 0
        for s in statsArr where !s.isGroup {
            switch profileMap[s.chatUsername] {
            case .superior: superiorMsgs += s.messageCount
            case .subordinate: subordinateMsgs += s.messageCount
            case .peer: peerMsgs += s.messageCount
            case .external: externalMsgs += s.messageCount
            case .personal: personalMsgs += s.messageCount
            case .none: peerMsgs += s.messageCount
            }
        }
        let activeGroups = statsArr.filter { $0.isGroup && $0.myMessageCount > 0 }.count
        let atMentionChats = replyDebtItems.filter { $0.isAtMention }.count

        // D7: Commitment Reliability
        let pending = commitments.filter { $0.status == .pending }.count
        let overdue = commitments.filter { $0.status == .overdue }.count
        let fulfilled = commitments.filter { $0.status == .fulfilled }.count
        let completionRate = (fulfilled + overdue) > 0 ? Double(fulfilled) / Double(fulfilled + overdue) : 1.0

        // D8: Attention Distribution
        let vipMsgs = vipUsernames.reduce(0) { $0 + (allStats[$1]?.messageCount ?? 0) }
        let vipRatio = totalMessages > 0 ? Double(vipMsgs) / Double(totalMessages) : 0
        let timeBlackHoles = statsArr.sorted { $0.messageCount > $1.messageCount }.prefix(5)
            .map { (name: $0.chatName, count: $0.messageCount) }
        let neglectedHigh = contacts.filter { c in
            (c.attentionLevel == .vip || c.role == .boss || c.role == .keyClient)
            && (allStats[c.username]?.messageCount ?? 0) == 0
        }.map { (name: $0.displayName, role: $0.role.label) }

        // D9: Communication Style
        let avgPerChat = activeChats > 0 ? Double(totalMessages) / Double(activeChats) : 0

        // D10: Pressure Signals
        let nowTs = Int(now.timeIntervalSince1970)
        let sevenDaysAgo = nowTs - 7 * 86400
        let recent7dMsgs = statsArr.reduce(0) { total, s in
            if s.latestTs >= sevenDaysAgo { return total + s.messageCount }
            return total
        }
        let dailyAvgOverall = windowDays > 0 ? Double(totalMessages) / Double(windowDays) : 0
        let dailyAvgRecent = Double(recent7dMsgs) / 7.0
        let densityRatio = dailyAvgOverall > 0 ? dailyAvgRecent / dailyAvgOverall : 1.0

        return GlobalOverview(
            totalMessages: totalMessages, myMessages: myMessages,
            activeChats: activeChats, totalChats: totalChats,
            participants: allParticipants.count, messagesByHour: hourly,
            myRatio: totalMessages > 0 ? Double(myMessages) / Double(totalMessages) : 0,
            initiationRate: initiationRate,
            groupMessages: groupMsgs, privateMessages: privateMsgs,
            groupChats: groupChatCount, privateChats: privateChatCount,
            typeDistribution: typeDist,
            messagesByWeekday: wkday,
            workHourMessages: workHourMsgs, eveningMessages: eveningMsgs,
            nightMessages: nightMsgs, morningMessages: morningMsgs,
            afterHoursRatio: afterHours, busiestHour: busiestHour,
            busiestWeekday: busiestWeekday,
            weekdayTotal: weekdayTotal, weekendTotal: weekendTotal,
            avgResponseSeconds: avgResponse, responseRate: responseRate, overdueChats: overdueChats,
            topContacts: Array(topContacts), oneWayChats: oneWay,
            neglectedVIPs: neglectedVIPs,
            tierDistribution: tierCounts.sorted { $0.value > $1.value }.map { (tier: $0.key, count: $0.value) },
            roleDistribution: roleCounts.sorted { $0.value > $1.value }.map { (role: $0.key, count: $0.value) },
            mostSymmetric: mostSym, leastSymmetric: leastSym,
            workMessages: workCount, lifeMessages: lifeCount, otherMessages: otherCount,
            workAfterHoursCount: workAfterHours, boundaryScore: boundaryScore,
            atMentionChats: atMentionChats,
            superiorMessages: superiorMsgs, subordinateMessages: subordinateMsgs,
            peerMessages: peerMsgs, externalMessages: externalMsgs, personalMessages: personalMsgs,
            activeGroupCount: activeGroups,
            pendingCommitments: pending, overdueCommitments: overdue,
            fulfilledCommitments: fulfilled, commitmentCompletionRate: completionRate,
            vipMessageRatio: vipRatio, topTimeBlackHoles: Array(timeBlackHoles),
            neglectedHighValue: neglectedHigh,
            avgMessagesPerChat: avgPerChat,
            pendingAsks: pendingAskCount, urgentAsks: urgentAskCount,
            recalledMessages: recalledMessageCount, recentDensityRatio: densityRatio
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
