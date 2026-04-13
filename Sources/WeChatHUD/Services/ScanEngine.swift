import Foundation
import SQLite3

/// Pure-function scan engine extracted from ChatMonitor.
/// All methods are nonisolated static — safe to call from any context.
enum ScanEngine {

    /// Result struct returned from the background scan worker.
    /// Collects everything the `@Published` fields need so the main
    /// thread can apply the whole update atomically.
    struct ScanOutcome {
        let stats: HUDStats
        let unreadItems: [UnreadItem]
        let suppressedItems: [UnreadItem]
        let replyDebtItems: [ReplyDebtItem]
        let recentNotifications: [HUDNotification]
        let latestPreview: HUDNotification?
        /// New inbound messages detected this scan cycle (for autopilot).
        let newInboundMessages: [AutopilotService.InboundMessage]
        /// New inbound messages from whitelisted chats for AI classification.
        let newInboundForClassifier: [(msg: MessageInfo, chatUsername: String, isVIP: Bool)]
        /// VIP messages to insert as traces.
        let vipTraceMessages: [(vipUsername: String, vipName: String, chatUsername: String, chatName: String, msgUID: String, rawText: String, msgTime: Int)]
        /// User's own outgoing messages detected this scan (for commitment tracking).
        let selfOutgoingMessages: [(msg: MessageInfo, chatUsername: String, chatName: String, recipientName: String)]
    }

    /// Run a full scan of WeChat's databases and produce an atomic update
    /// for ChatMonitor's `@Published` properties.
    static func performScan(
        reader: WeChatReader,
        store: HUDStore,
        aiService: AIService?,
        changedRelPaths: Set<String>?,
        thresholds: UnreadThresholds,
        replyDebtConfig: ReplyDebtConfig,
        replyDebtAIConfig: ReplyDebtAIConfig,
        currentRecent: [HUDNotification],
        recentLimit: Int
    ) async -> ScanOutcome? {
        do {
            try reader.loadKeys()
            try reader.refreshContactsIfChanged()

            let chatActions = store.loadChatActions()
            let ignoredSenderMap = store.loadIgnoredSenderMap()
            let nowEpoch = Int(Date().timeIntervalSince1970)

            let sessions: [SessionInfo]
            do {
                sessions = try reader.getSessions()
            } catch {
                print("[WCHUD] getSessions failed (DB locked?): \(error) — using empty session list")
                sessions = []
            }
            let myUname = reader.myUsername()
            let myDisplayName = reader.displayName(for: myUname)
            let whitelist = store.getWhitelist()
            let whitelistSet = Set(whitelist.map { $0.id })
            let vipSet = Set(whitelist.filter { $0.attentionLevel == .vip }.map { $0.id })
            let allContacts = store.loadContacts()
            let contactMap = Dictionary(uniqueKeysWithValues: allContacts.map { ($0.username, $0) })
            var replyDebtItems = buildReplyDebtItems(
                sessions: sessions,
                reader: reader,
                chatActions: chatActions,
                ignoredSenderMap: ignoredSenderMap,
                myUsername: myUname,
                myDisplayName: myDisplayName,
                whitelistSet: whitelistSet,
                vipSet: vipSet,
                contactMap: contactMap,
                config: replyDebtConfig
            )
            if replyDebtAIConfig.enabled,
               !replyDebtItems.isEmpty,
               let aiService,
               await aiService.isConfigured() {
                let aiConfig = await aiService.currentConfig()
                let judge = ReplyDebtJudge(now: Date())
                replyDebtItems = await judge.apply(
                    to: replyDebtItems,
                    config: replyDebtAIConfig,
                    client: aiService,
                    model: aiConfig.model,
                    store: store
                )
            }

            var privateUnreadChats = 0
            var groupAtCount = 0
            var unreadCollected: [UnreadItem] = []
            var suppressedCollected: [UnreadItem] = []

            for session in sessions where session.unreadCount > 0 {
                let isSnoozed = (chatActions[session.username]?.snoozedUntil ?? 0) > nowEpoch
                let fetchLimit = session.isGroup ? min(session.unreadCount, 30) : 5
                let recentMsgs = (try? reader.getMessages(
                    chatUsername: session.username,
                    limit: fetchLimit
                )) ?? []

                let latestSelfTime: Int = recentMsgs
                    .filter { MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName) }
                    .map { $0.createTime }
                    .max() ?? 0

                let isWhitelisted = whitelistSet.contains(session.username)
                let isVIP = vipSet.contains(session.username)
                let silencedAt = chatActions[session.username]?.silencedAt ?? 0

                func makeItem(_ msg: MessageInfo, kind: HUDNotificationKind) -> UnreadItem {
                    let ts = Date(timeIntervalSince1970: Double(msg.createTime))
                    let replied = latestSelfTime > msg.createTime
                    let isIgnored = MessageHelpers.isIgnoredSender(msg, ignoredSenderMap: ignoredSenderMap)
                    return UnreadItem(
                        chatUsername: session.username,
                        chatName: msg.chatName,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName,
                        preview: String(msg.text.prefix(80)),
                        timestamp: ts,
                        kind: kind,
                        isWhitelisted: isWhitelisted,
                        isVIP: isVIP,
                        replied: replied,
                        status: MessageHelpers.unreadStatus(
                            replied: replied,
                            timestamp: ts,
                            isVIP: isVIP,
                            thresholds: thresholds
                        ),
                        isIgnored: isIgnored
                    )
                }

                if !session.isGroup {
                    guard let msg = recentMsgs.first(where: {
                        !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName)
                    }) else { continue }
                    let item = makeItem(msg, kind: .privateChat)
                    if item.isIgnored || isSnoozed || msg.createTime <= silencedAt {
                        suppressedCollected.append(item)
                    } else {
                        privateUnreadChats += 1
                        unreadCollected.append(item)
                    }
                } else {
                    for msg in recentMsgs where MessageHelpers.isAtMe(msg.text, myUsername: myUname) {
                        let item = makeItem(msg, kind: .groupAt)
                        if item.isIgnored || isSnoozed || msg.createTime <= silencedAt {
                            suppressedCollected.append(item)
                        } else {
                            groupAtCount += 1
                            unreadCollected.append(item)
                        }
                    }
                }
            }

            func rank(_ s: UnreadStatus) -> Int {
                switch s {
                case .overdue: return 0
                case .pending: return 1
                case .answered: return 2
                }
            }
            let sortedUnread = unreadCollected.sorted { a, b in
                let ra = rank(a.status), rb = rank(b.status)
                if ra != rb { return ra < rb }
                return a.timestamp > b.timestamp
            }
            let sortedSuppressed = suppressedCollected.sorted { $0.timestamp > $1.timestamp }
            let totalUnread = privateUnreadChats + groupAtCount

            // DEBUG MODE: empty whitelist → cheap sqlite_sequence sweep
            // just for a total unread count. No VIP list, no preview.
            if whitelist.isEmpty {
                let (extra, _) = (try? debugScanAllTables(
                    reader: reader,
                    store: store,
                    changedRelPaths: changedRelPaths
                )) ?? (0, 0)
                return ScanOutcome(
                    stats: HUDStats(
                        unreadCount: totalUnread + extra,
                        atMentionCount: groupAtCount,
                        vipCount: 0,
                        replyDebtCount: replyDebtItems.count,
                        syncStatus: .ok,
                        lastSyncAt: Date()
                    ),
                    unreadItems: sortedUnread,
                    suppressedItems: sortedSuppressed,
                    replyDebtItems: replyDebtItems,
                    recentNotifications: [],
                    latestPreview: nil,
                    newInboundMessages: [],
                    newInboundForClassifier: [],
                    vipTraceMessages: [],
                    selfOutgoingMessages: []
                )
            }

            // ---- Whitelist scan (for the follow feed & VIP alerts) ----
            var latestPreview: HUDNotification?
            var perChatLatest: [String: HUDNotification] = [:]
            var autopilotInbound: [AutopilotService.InboundMessage] = []
            var vipTraceMessages: [(vipUsername: String, vipName: String, chatUsername: String, chatName: String, msgUID: String, rawText: String, msgTime: Int)] = []
            var newInboundForClassifier: [(msg: MessageInfo, chatUsername: String, isVIP: Bool)] = []
            var selfOutgoingMessages: [(msg: MessageInfo, chatUsername: String, chatName: String, recipientName: String)] = []

            let msgDBs = reader.findMessageDBs()
            for relPath in msgDBs {
                _ = try? reader.refreshIfChanged(relPath: relPath)
            }

            // Build session lookup for timestamp correction
            let sessionMap = Dictionary(uniqueKeysWithValues: sessions.map { ($0.username, $0) })

            for entry in whitelist {
                let messages: [MessageInfo]
                do {
                    messages = try reader.getMessages(
                        chatUsername: entry.id,
                        limit: 100,
                        sinceLocalId: nil
                    )
                } catch { continue }

                let currentMaxTime = messages.first?.createTime ?? 0

                guard let baseline = store.getWhitelistBaseline(username: entry.id) else {
                    let seed = currentMaxTime > 0
                        ? currentMaxTime
                        : Int(Date().timeIntervalSince1970)
                    try? store.setWhitelistBaseline(username: entry.id, lastCreateTime: seed)
                    continue
                }

                let newMessages = messages.filter { $0.createTime > baseline }

                for msg in newMessages {
                    // Collect self messages for commitment tracking BEFORE skipping
                    if MessageHelpers.isFromSelf(msg, chatUsername: entry.id, myUsername: myUname, myDisplayName: myDisplayName) {
                        let recipientName = reader.displayName(for: entry.id)
                        selfOutgoingMessages.append((
                            msg: msg, chatUsername: entry.id,
                            chatName: msg.chatName, recipientName: recipientName
                        ))
                        continue  // still skip for notification purposes
                    }
                    if MessageHelpers.isIgnoredSender(msg, ignoredSenderMap: ignoredSenderMap) {
                        continue
                    }
                    let isAt = MessageHelpers.isAtMe(msg.text, myUsername: myUname)
                    let kind: HUDNotificationKind
                    if !msg.chatUsername.contains("@chatroom") {
                        kind = .privateChat
                    } else if isAt {
                        kind = .groupAt
                    } else {
                        kind = .groupMessage
                    }

                    // Use the more recent of message createTime and session lastTimestamp.
                    // WeChat's create_time can be stale for bots/forwarded messages.
                    let sessionTs = sessionMap[entry.id]?.lastTimestamp ?? msg.createTime
                    let bestTime = max(msg.createTime, sessionTs)
                    let msgTime = Date(timeIntervalSince1970: Double(bestTime))
                    let notif = HUDNotification(
                        chatUsername: msg.chatUsername,
                        chatName: msg.chatName,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName,
                        attentionLevel: entry.attentionLevel,
                        messageID: msg.id,
                        rawText: msg.text,
                        snippet: String(msg.text.prefix(80)),
                        isAtMention: isAt,
                        timestamp: msgTime,
                        kind: kind
                    )

                    if notif.isVIP,
                       (latestPreview == nil || msgTime > latestPreview!.timestamp) {
                        latestPreview = notif
                    }

                    if let existing = perChatLatest[msg.chatUsername],
                       existing.timestamp >= msgTime {
                        // keep existing
                    } else {
                        perChatLatest[msg.chatUsername] = notif
                    }

                    // Collect for autopilot: private chats + group @mentions.
                    if kind == .privateChat || kind == .groupAt {
                        let contact = store.getContact(username: msg.senderUsername)
                        let level: AttentionLevel
                        if entry.attentionLevel == .vip {
                            level = .vip
                        } else {
                            level = contact?.attentionLevel ?? .whitelist
                        }
                        autopilotInbound.append(AutopilotService.InboundMessage(
                            msgUID: msg.id,
                            chatUsername: msg.chatUsername,
                            chatName: msg.chatName,
                            senderUsername: msg.senderUsername,
                            senderName: msg.senderName,
                            text: msg.text,
                            isGroup: msg.chatUsername.contains("@chatroom"),
                            isAtMention: isAt,
                            attentionLevel: level,
                            contactRole: contact?.role ?? .acquaintance,
                            timestamp: msg.createTime,
                            messageType: msg.baseType,
                            appType: msg.appType
                        ))
                    }

                    // Collect VIP traces for VIPAggregator
                    if entry.attentionLevel == .vip {
                        vipTraceMessages.append((
                            vipUsername: msg.senderUsername,
                            vipName: msg.senderName,
                            chatUsername: msg.chatUsername,
                            chatName: msg.chatName,
                            msgUID: msg.id,
                            rawText: msg.text,
                            msgTime: msg.createTime
                        ))
                    }

                    // Collect for AI classifier (non-self inbound messages)
                    newInboundForClassifier.append((
                        msg: msg,
                        chatUsername: entry.id,
                        isVIP: entry.attentionLevel == .vip
                    ))
                }

                if currentMaxTime > baseline {
                    try? store.setWhitelistBaseline(
                        username: entry.id,
                        lastCreateTime: currentMaxTime
                    )
                }
            }

            // Merge recentNotifications with this scan's per-chat latest.
            var mergedRecent = currentRecent
            if !perChatLatest.isEmpty {
                for (username, notif) in perChatLatest {
                    mergedRecent.removeAll { $0.chatUsername == username }
                    mergedRecent.append(notif)
                }
                mergedRecent.sort { $0.timestamp > $1.timestamp }
                if mergedRecent.count > recentLimit {
                    mergedRecent = Array(mergedRecent.prefix(recentLimit))
                }
            }
            let vipCount = mergedRecent.filter(\.isVIP).count

            // ---- Autopilot: scan non-whitelist private chats ----
            // Design spec: autopilot handles ALL private chats (VIP/whitelist/greylist),
            // not just whitelisted ones. Different tiers get different processing depth.
            let whitelistUsernames = Set(whitelist.map(\.id))
            if let allSessions = try? reader.getSessions() {
                for session in allSessions {
                    // Skip group chats, already-scanned whitelist chats, and chatrooms
                    guard !session.username.contains("@chatroom"),
                          !whitelistUsernames.contains(session.username),
                          session.unreadCount > 0 else { continue }

                    // Only scan recent private chats with unread messages
                    let messages: [MessageInfo]
                    do {
                        messages = try reader.getMessages(chatUsername: session.username, limit: 20, sinceLocalId: nil)
                    } catch { continue }

                    guard let baseline = store.getWhitelistBaseline(username: session.username) else {
                        let seed = messages.first?.createTime ?? Int(Date().timeIntervalSince1970)
                        try? store.setWhitelistBaseline(username: session.username, lastCreateTime: seed)
                        continue
                    }

                    let newMessages = messages.filter { $0.createTime > baseline }
                    for msg in newMessages {
                        if MessageHelpers.isFromSelf(msg, chatUsername: session.username, myUsername: myUname) { continue }
                        let contact = store.getContact(username: msg.senderUsername)
                        let level: AttentionLevel = contact?.attentionLevel ?? .greylist
                        // Strangers (no contact record, no greylist) are skipped
                        autopilotInbound.append(AutopilotService.InboundMessage(
                            msgUID: msg.id,
                            chatUsername: msg.chatUsername,
                            chatName: msg.chatName,
                            senderUsername: msg.senderUsername,
                            senderName: msg.senderName,
                            text: msg.text,
                            isGroup: false,
                            isAtMention: false,
                            attentionLevel: level,
                            contactRole: contact?.role ?? .acquaintance,
                            timestamp: msg.createTime,
                            messageType: msg.baseType,
                            appType: msg.appType
                        ))
                    }

                    // Update baseline
                    if let maxTime = newMessages.first?.createTime, maxTime > baseline {
                        try? store.setWhitelistBaseline(username: session.username, lastCreateTime: maxTime)
                    }
                }
            }

            return ScanOutcome(
                stats: HUDStats(
                    unreadCount: totalUnread,
                    atMentionCount: groupAtCount,
                    vipCount: vipCount,
                    replyDebtCount: replyDebtItems.count,
                    syncStatus: .ok,
                    lastSyncAt: Date()
                ),
                unreadItems: sortedUnread,
                suppressedItems: sortedSuppressed,
                replyDebtItems: replyDebtItems,
                recentNotifications: mergedRecent,
                latestPreview: latestPreview,
                newInboundMessages: autopilotInbound,
                newInboundForClassifier: newInboundForClassifier,
                vipTraceMessages: vipTraceMessages,
                selfOutgoingMessages: selfOutgoingMessages
            )
        } catch {
            print("[WCHUD] performScan error: \(error)")
            return nil
        }
    }

    static func buildReplyDebtItems(
        sessions: [SessionInfo],
        reader: WeChatReader,
        chatActions: [String: HUDStore.ChatActionState],
        ignoredSenderMap: [String: Set<String>],
        myUsername: String,
        myDisplayName: String = "",
        whitelistSet: Set<String>,
        vipSet: Set<String>,
        contactMap: [String: ContactEntry],  // NEW
        config: ReplyDebtConfig
    ) -> [ReplyDebtItem] {
        let sortedSessions = sessions.sorted { lhs, rhs in
            if lhs.lastTimestamp != rhs.lastTimestamp { return lhs.lastTimestamp > rhs.lastTimestamp }
            return lhs.username < rhs.username
        }
        let targetSessions = Array(sortedSessions.prefix(max(1, config.maxSessions)))
        let now = Date()

        let seeds: [ReplyDebtScorer.Seed] = targetSessions.compactMap { session in
            let recentMsgs = (try? reader.getMessages(chatUsername: session.username, limit: 12)) ?? []
            guard !recentMsgs.isEmpty else { return nil }

            let latestInbound = recentMsgs.first {
                !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName)
                    && !MessageHelpers.isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
            }
            guard let inbound = latestInbound else { return nil }

            let latestOutbound = recentMsgs.first {
                MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName)
            }
            let inboundCountSinceLastOutbound: Int
            if let outbound = latestOutbound {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName)
                        && !MessageHelpers.isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
                        && $0.createTime > outbound.createTime
                }.count
            } else {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName)
                        && !MessageHelpers.isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
                }.count
            }

            return ReplyDebtScorer.Seed(
                session: session,
                chatName: inbound.chatName,
                isWhitelisted: whitelistSet.contains(session.username),
                isVIP: vipSet.contains(session.username),
                latestInbound: inbound,
                latestOutbound: latestOutbound,
                inboundCountSinceLastOutbound: inboundCountSinceLastOutbound,
                isAtMention: MessageHelpers.isAtMe(inbound.text, myUsername: myUsername),
                chatAction: chatActions[session.username],
                now: now,
                contactReplyWindowMinutes: contactMap[session.username]?.replyWindowMinutes
            )
        }

        return ReplyDebtScorer.build(seeds: seeds, config: config)
    }

    /// Iterate Msg_* tables in the target message DBs, count new rows since
    /// last known local_id. First sighting of a table establishes a baseline.
    static func debugScanAllTables(
        reader: WeChatReader,
        store: HUDStore,
        changedRelPaths: Set<String>? = nil
    ) throws -> (unread: Int, scanned: Int) {
        let allMsgDBs = reader.findMessageDBs()
        let targetDBs: [String]
        if let changed = changedRelPaths {
            targetDBs = allMsgDBs.filter { changed.contains($0) }
        } else {
            targetDBs = allMsgDBs
        }
        for relPath in targetDBs {
            _ = try? reader.refreshIfChanged(relPath: relPath)
        }
        guard !targetDBs.isEmpty else { return (0, 0) }

        var totalNew = 0
        var totalScanned = 0

        for relPath in targetDBs {
            let decPath: String
            do {
                decPath = try reader.getDecryptedDB(relativePath: relPath)
            } catch {
                continue
            }
            var db: OpaquePointer?
            guard WeChatReader.openReadonly(path: decPath, db: &db) else { continue }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "SELECT name, seq FROM sqlite_sequence WHERE name LIKE 'Msg_%'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
                let tableName = String(cString: namePtr)
                let maxId = Int(sqlite3_column_int64(stmt, 1))
                totalScanned += 1

                let sourceKey = "debug/\(relPath)/\(tableName)"
                let lastState = store.getSyncState(sourceKey)
                let sinceId = lastState?.lastLocalId ?? 0

                if sinceId == 0 {
                    if maxId > 0 {
                        try? store.updateSyncState(sourceKey, lastLocalId: maxId)
                    }
                } else if maxId > sinceId {
                    totalNew += (maxId - sinceId)
                    try? store.updateSyncState(sourceKey, lastLocalId: maxId)
                }
            }
            sqlite3_finalize(stmt)
        }
        return (totalNew, totalScanned)
    }
}
