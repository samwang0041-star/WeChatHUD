import Foundation

/// Loads and computes insight statistics and global overview.
/// Extracted from `InsightStore` to separate data loading from state management.
final class InsightDataLoader {

    struct LoadResult {
        let stats: [String: ChatStatsData]
        let overview: ChatStatsEngine.GlobalOverview?
        let otherActiveSessions: [InsightSessionEntry]
    }

    /// Load stats and overview for the given time window and scope.
    func load(
        store: HUDStore,
        reader: WeChatReader,
        replyDebtItems: [ReplyDebtItem],
        window: InsightTimeWindow,
        scope: InsightScope
    ) -> LoadResult? {
        let whitelist = store.getWhitelist()
        let whitelistIds = Set(whitelist.map(\.id))
        let whitelistMap = Dictionary(uniqueKeysWithValues: whitelist.map { ($0.id, $0) })
        let selfNames = reader.mySelfNames
        let cutoff = cutoffTimestamp(for: window)

        guard let sessions = try? reader.getSessions() else {
            return nil
        }

        let filteredSessions = sessions.filter { session in
            guard !session.username.hasPrefix("gh_"),
                  !session.username.contains("@app"),
                  session.username != "filehelper",
                  session.username != "floatbottle",
                  !session.username.hasPrefix("fake_"),
                  !selfNames.contains(session.username) else { return false }
            if scope == .whitelist && !whitelistIds.contains(session.username) { return false }
            if cutoff > 0 && session.lastTimestamp < cutoff { return false }
            return true
        }

        let bulkStats = reader.bulkMessageStats(
            chatUsernames: filteredSessions.map(\.username),
            selfNames: selfNames,
            sinceTsEpoch: cutoff
        )

        var stats: [String: ChatStatsData] = [:]
        var others: [InsightSessionEntry] = []
        let sessionMap = Dictionary(uniqueKeysWithValues: filteredSessions.map { ($0.username, $0) })

        for (chatUsername, bulk) in bulkStats {
            let session = sessionMap[chatUsername]
            let isGroup = session?.isGroup ?? chatUsername.contains("@chatroom")
            let isWhitelisted = whitelistIds.contains(chatUsername)
            let entry = whitelistMap[chatUsername]
            let name = entry?.displayName ?? reader.displayName(for: chatUsername)
            let category = entry?.category ?? .other
            let topSenders = bulk.senderCounts
                .sorted { $0.value > $1.value }
                .map { (name: reader.displayName(for: $0.key), count: $0.value) }

            let myCount = bulk.selfCount
            let othersCount = bulk.totalCount - myCount
            let symmetryRatio: Double
            if bulk.totalCount == 0 {
                symmetryRatio = 1.0
            } else {
                let minCount = Double(min(myCount, othersCount))
                let maxCount = Double(max(myCount, othersCount))
                symmetryRatio = maxCount > 0 ? minCount / maxCount : 1.0
            }

            let chatStats = ChatStatsData(
                chatUsername: chatUsername,
                chatName: name,
                isGroup: isGroup,
                category: category,
                messageCount: bulk.totalCount,
                myMessageCount: myCount,
                participantCount: bulk.senderCounts.count,
                messagesByHour: bulk.hourlyBuckets,
                messagesByWeekday: bulk.weekdayBuckets,
                typeCounts: bulk.typeCounts,
                avgResponseTimeSeconds: 0,
                symmetryRatio: symmetryRatio,
                trend7d: 0,
                topSenders: topSenders,
                silentMembers: [],
                ignoredMessages: [],
                selfInitiated: bulk.selfInitiated,
                earliestTs: bulk.earliestTs,
                latestTs: bulk.latestTs
            )
            stats[chatUsername] = chatStats

            if !isWhitelisted {
                others.append(InsightSessionEntry(
                    id: chatUsername,
                    displayName: name,
                    isGroup: isGroup,
                    lastTimestamp: session?.lastTimestamp ?? 0,
                    messageCount: bulk.totalCount
                ))
            }
        }

        let pendingAsks = store.loadPendingAsks(bucket: nil, status: .pending)
        let recalledMessages = store.loadRecalledMessages(since: cutoff, limit: 1000)
        let days = window.seconds.map { max($0 / 86400, 1) } ?? 365

        let overview = ChatStatsEngine.computeGlobalOverview(
            allStats: stats,
            contacts: store.loadContacts(),
            commitments: store.loadCommitments(status: nil),
            replyDebtItems: replyDebtItems,
            vipUsernames: Set(store.loadVIPUsernames()),
            selfUsernames: selfNames,
            pendingAskCount: pendingAsks.count,
            urgentAskCount: pendingAsks.filter { $0.urgency == .urgent }.count,
            recalledMessageCount: recalledMessages.count,
            windowDays: days
        )

        return LoadResult(
            stats: stats,
            overview: overview,
            otherActiveSessions: others.sorted { $0.messageCount > $1.messageCount }
        )
    }

    /// Compute detailed stats for a single non-whitelisted session.
    func statsForSession(
        _ session: InsightSessionEntry,
        reader: WeChatReader
    ) -> ChatStatsData? {
        guard let messages = try? reader.getMessages(chatUsername: session.id, limit: 200) else { return nil }
        let myUsername = reader.myUsername()
        return ChatStatsEngine.computeStats(
            messages: messages,
            selfUsername: myUsername,
            selfDisplayName: reader.displayName(for: myUsername),
            selfNames: reader.mySelfNames,
            chatUsername: session.id,
            chatName: session.displayName,
            isGroup: session.isGroup,
            category: .other
        )
    }

    // MARK: - Helpers

    private func cutoffTimestamp(for window: InsightTimeWindow) -> Int {
        if window == .today {
            return Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        }
        let now = Int(Date().timeIntervalSince1970)
        return window.seconds.map { now - $0 } ?? 0
    }
}
