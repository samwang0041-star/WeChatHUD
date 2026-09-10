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
        aiService: AIService,
        changedRelPaths: Set<String>?,
        thresholds: UnreadThresholds,
        replyDebtConfig: ReplyDebtConfig,
        currentRecent: [HUDNotification],
        recentLimit: Int,
        autopilotActive: Bool
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

            // Refresh message DBs before reading — picks up outbound messages
            // the user just sent in WeChat, so reply debt correctly detects replies.
            // When FSEvents told us exactly which files changed, only refresh those.
            // On timer-based fallback scans (changedRelPaths == nil), check all DBs
            // but refreshIfChanged is cheap (mtime compare) for unchanged files.
            let msgDBs = reader.findMessageDBs()
            if let changed = changedRelPaths {
                let changedSet = Set(changed)
                for relPath in msgDBs where changedSet.contains(relPath) {
                    _ = try? reader.refreshIfChanged(relPath: relPath)
                }
            } else {
                for relPath in msgDBs {
                    _ = try? reader.refreshIfChanged(relPath: relPath)
                }
            }

            let selfNames = reader.mySelfNames
            let replyDebtItems = buildReplyDebtItems(
                sessions: sessions,
                reader: reader,
                chatActions: chatActions,
                ignoredSenderMap: ignoredSenderMap,
                myUsername: myUname,
                myDisplayName: myDisplayName,
                mySelfNames: selfNames,
                whitelistSet: whitelistSet,
                vipSet: vipSet,
                contactMap: contactMap,
                config: replyDebtConfig
            )
            // ReplyDebt uses rule scoring only, no AI ranker

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
                    .filter { MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) }
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
                        !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames)
                    }) else { continue }
                    let item = makeItem(msg, kind: .privateChat)
                    if item.isIgnored || isSnoozed || msg.createTime <= silencedAt {
                        suppressedCollected.append(item)
                    } else {
                        privateUnreadChats += 1
                        unreadCollected.append(item)
                    }
                } else {
                    for msg in recentMsgs where MessageHelpers.isAtMe(msg.text, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) {
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
            let debugUnreadExtra: Int
            if whitelist.isEmpty {
                debugUnreadExtra = (try? debugScanAllTables(
                    reader: reader,
                    store: store,
                    changedRelPaths: changedRelPaths
                ))?.unread ?? 0
            } else {
                debugUnreadExtra = 0
            }

            // ---- Whitelist scan (for the follow feed & VIP alerts) ----
            var latestPreview: HUDNotification?
            var perChatLatest: [String: HUDNotification] = [:]
            var autopilotInbound: [AutopilotService.InboundMessage] = []
            var vipTraceMessages: [(vipUsername: String, vipName: String, chatUsername: String, chatName: String, msgUID: String, rawText: String, msgTime: Int)] = []
            var newInboundForClassifier: [(msg: MessageInfo, chatUsername: String, isVIP: Bool)] = []
            var selfOutgoingMessages: [(msg: MessageInfo, chatUsername: String, chatName: String, recipientName: String)] = []
            let notificationConfig = store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()

            // Usernames of contacts explicitly marked VIP — used to detect
            // their presence in any whitelisted group chat, not just their
            // own private thread. See `deriveVIPPersonUsernames`.
            let vipPersonUsernames = Self.deriveVIPPersonUsernames(whitelist: whitelist)

            // Build session lookup for timestamp correction
            let sessionMap = Dictionary(uniqueKeysWithValues: sessions.map { ($0.username, $0) })

            for entry in whitelist {
                let isFirstWhitelistScan = store.getWhitelistCursor(username: entry.id) == nil
                let messages: [MessageInfo]
                do {
                    let unreadHint = sessionMap[entry.id]?.unreadCount ?? 0
                    let fetchLimit = Self.whitelistFetchLimit(
                        hasCursor: !isFirstWhitelistScan,
                        unreadCount: unreadHint
                    )
                    messages = try reader.getMessages(
                        chatUsername: entry.id,
                        limit: fetchLimit,
                        sinceLocalId: nil
                    )
                } catch { continue }

                let currentCursor = messages.first.map { ($0.createTime, $0.localId) } ?? (0, 0)

                // Resolve the baseline for "what's new since last scan".
                // If no baseline is stored (first scan for this chat —
                // typically right after the user adds it to the
                // whitelist), seed it to cover the existing unread
                // backlog. Otherwise adding a new whitelist entry while
                // there are unread messages would silently swallow
                // them: we'd seed to the newest message time and none
                // of the backlog would pass the `> baseline` filter.
                let baseline: (lastCreateTime: Int, lastLocalId: Int)
                if let existing = store.getWhitelistCursor(username: entry.id) {
                    baseline = existing
                } else if sessions.isEmpty {
                    // Unread counts come from session.db. An empty list is a
                    // locked/failed read, not "no unread". Do not persist a
                    // newest-message cursor that would swallow the backlog.
                    baseline = currentCursor
                } else {
                    let unreadCount = sessionMap[entry.id]?.unreadCount ?? 0
                    let seed: (lastCreateTime: Int, lastLocalId: Int)
                    if unreadCount > 0 && !messages.isEmpty {
                        // Messages are newest-first. The N unread ones
                        // sit at indices 0..<unreadCount (capped to
                        // what we actually fetched). Seed just before
                        // the OLDEST unread — messages[N-1] — so the
                        // `> baseline` filter picks up exactly those N,
                        // not N+1 (including the first *read* message).
                        let lastUnreadIdx = min(unreadCount, messages.count) - 1
                        let oldestUnread = messages[lastUnreadIdx]
                        seed = (oldestUnread.createTime, max(0, oldestUnread.localId - 1))
                    } else if currentCursor.0 > 0 {
                        seed = currentCursor
                    } else {
                        seed = (Int(Date().timeIntervalSince1970), 0)
                    }
                    baseline = seed
                }

                let newMessages = messages.filter {
                    $0.createTime > baseline.lastCreateTime
                        || ($0.createTime == baseline.lastCreateTime && $0.localId > baseline.lastLocalId)
                }

                // Queue persistence and the source cursor are one durable
                // unit. A failed queue write must leave the cursor unchanged
                // so the next scan can retry the same source messages.
                var classificationMessages: [MessageInfo] = []
                classificationMessages.reserveCapacity(newMessages.count)
                var autopilotMessagesToQueue: [AutopilotService.InboundMessage] = []
                autopilotMessagesToQueue.reserveCapacity(newMessages.count)

                for msg in newMessages {
                    // Collect self messages for commitment tracking BEFORE skipping
                    if MessageHelpers.isFromSelf(msg, chatUsername: entry.id, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) {
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
                    let isAt = MessageHelpers.isAtMe(msg.text, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames)
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
                    // Cap at "now" so a session row that claims a future
                    // timestamp (seen occasionally for bot-generated
                    // messages) can't push our notification timestamp
                    // past the current moment and scramble the sort.
                    let nowEpoch = Int(Date().timeIntervalSince1970)
                    let sessionTs = sessionMap[entry.id]?.lastTimestamp ?? msg.createTime
                    let bestTime = min(nowEpoch, max(msg.createTime, sessionTs))
                    let msgTime = Date(timeIntervalSince1970: Double(bestTime))

                    // Promote the notification's attention level to .vip when
                    // the sender is a flagged VIP contact speaking in a
                    // non-VIP whitelisted group. This routes the event through
                    // the same HUD/banner path as a VIP-chat notification —
                    // `HUDNotification.isVIP` is derived from attentionLevel.
                    let isCrossGroupVIP = Self.shouldAppendCrossGroupVIPTrace(
                        entryID: entry.id,
                        entryLevel: entry.attentionLevel,
                        senderUsername: msg.senderUsername,
                        vipPersonUsernames: vipPersonUsernames
                    )
                    let effectiveLevel: WhitelistAttentionLevel =
                        isCrossGroupVIP ? .vip : entry.attentionLevel
                    let notif = HUDNotification(
                        chatUsername: msg.chatUsername,
                        chatName: msg.chatName,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName,
                        attentionLevel: effectiveLevel,
                        messageID: msg.id,
                        rawText: msg.text,
                        snippet: Self.deduplicateSenderInSnippet(msg.text, senderName: msg.senderName),
                        isAtMention: isAt,
                        timestamp: msgTime,
                        kind: kind
                    )

                    if notificationConfig.shouldPresent(notif.presentationSemanticState),
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
                        let inbound = AutopilotService.InboundMessage(
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
                        )
                        if autopilotActive && Self.shouldEnqueueAutopilotInbound(isFirstWhitelistScan: isFirstWhitelistScan) {
                            // Persist this queue row together with the
                            // whitelist cursor below. A failed insert must
                            // leave the cursor behind so the next scan retries.
                            autopilotMessagesToQueue.append(inbound)
                            autopilotInbound.append(inbound)
                        }
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

                    // Cross-group VIP: if the current chat is a group
                    // (whitelisted but not itself marked VIP), and the
                    // sender is one of the flagged VIP persons, fire the
                    // same trace so VIPAggregator and notifications pick
                    // it up. See `shouldAppendCrossGroupVIPTrace`.
                    if Self.shouldAppendCrossGroupVIPTrace(
                        entryID: entry.id,
                        entryLevel: entry.attentionLevel,
                        senderUsername: msg.senderUsername,
                        vipPersonUsernames: vipPersonUsernames
                    ) {
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
                    classificationMessages.append(msg)
                }

                if currentCursor.0 > baseline.lastCreateTime
                    || (currentCursor.0 == baseline.lastCreateTime && currentCursor.1 > baseline.lastLocalId) {
                    do {
                        try store.withTransaction {
                            // Discussion extraction includes both sides of the
                            // conversation, while classification receives only
                            // non-self, non-ignored inbound messages above.
                            if !newMessages.isEmpty {
                                try store.enqueueDiscussionMessages(newMessages)
                            }
                            if !classificationMessages.isEmpty {
                                try store.enqueueClassificationMessages(classificationMessages)
                            }
                            if autopilotActive {
                                for inbound in autopilotMessagesToQueue {
                                    try store.enqueueAutopilotInbound(inbound)
                                }
                            }
                            try store.setWhitelistCursor(
                                username: entry.id,
                                lastCreateTime: currentCursor.0,
                                lastLocalId: currentCursor.1
                            )
                        }
                    } catch {
                        // Do not advance the watermark after a queue or cursor
                        // failure. The next scan must retry this batch.
                        // Keep account identifiers and SQLite paths out of the
                        // user-visible log. The watermark remains unchanged
                        // and the next scan will retry this batch.
                        print("[WCHUD] queue persistence failed; scan watermark unchanged for retry")
                    }
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

                    guard let baseline = store.getAutopilotCursor(username: session.username) else {
                        let seed = messages.first.map { ($0.createTime, $0.localId) }
                            ?? (Int(Date().timeIntervalSince1970), 0)
                        do {
                            try store.setAutopilotCursor(
                                username: session.username,
                                lastCreateTime: seed.0,
                                lastLocalId: seed.1
                            )
                        } catch {
                            print("[WCHUD] autopilot queue persistence failed; scan watermark unchanged for retry")
                        }
                        continue
                    }

                    let newMessages = messages.filter {
                        $0.createTime > baseline.lastCreateTime
                            || ($0.createTime == baseline.lastCreateTime && $0.localId > baseline.lastLocalId)
                    }
                    var autopilotMessagesToQueue: [AutopilotService.InboundMessage] = []
                    autopilotMessagesToQueue.reserveCapacity(newMessages.count)
                    for msg in newMessages {
                        if MessageHelpers.isFromSelf(msg, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) { continue }
                        guard let contact = store.getContact(username: msg.senderUsername) else {
                            continue
                        }
                        let level: AttentionLevel = contact.attentionLevel
                        // Strangers (no contact record, no greylist) are skipped.
                        let inbound = AutopilotService.InboundMessage(
                            msgUID: msg.id,
                            chatUsername: msg.chatUsername,
                            chatName: msg.chatName,
                            senderUsername: msg.senderUsername,
                            senderName: msg.senderName,
                            text: msg.text,
                            isGroup: false,
                            isAtMention: false,
                            attentionLevel: level,
                            contactRole: contact.role,
                            timestamp: msg.createTime,
                            messageType: msg.baseType,
                            appType: msg.appType
                        )
                        if autopilotActive {
                            // Persist this queue row together with the
                            // autopilot cursor below. A failed insert must
                            // leave the cursor behind so the next scan retries.
                            autopilotMessagesToQueue.append(inbound)
                        }
                        autopilotInbound.append(inbound)
                    }

                    // Update baseline
                    if let newest = newMessages.first,
                       newest.createTime > baseline.lastCreateTime
                       || (newest.createTime == baseline.lastCreateTime && newest.localId > baseline.lastLocalId) {
                        do {
                            try store.withTransaction {
                                if autopilotActive {
                                    for inbound in autopilotMessagesToQueue {
                                        try store.enqueueAutopilotInbound(inbound)
                                    }
                                }
                                try store.setAutopilotCursor(
                                    username: session.username,
                                    lastCreateTime: newest.createTime,
                                    lastLocalId: newest.localId
                                )
                            }
                        } catch {
                            print("[WCHUD] autopilot queue persistence failed; scan watermark unchanged for retry")
                        }
                    }
                }
            }

            return ScanOutcome(
                stats: HUDStats(
                    unreadCount: totalUnread + debugUnreadExtra,
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

    /// First whitelist scan must cover the unread backlog. Messages are
    /// newest-first; a hard 100-row page would seed the cursor past older
    /// unread and never classify them.
    static func firstScanFetchLimit(unreadCount: Int, defaultLimit: Int = 100, hardCap: Int = 500) -> Int {
        max(defaultLimit, min(max(0, unreadCount), hardCap))
    }

    static func whitelistFetchLimit(hasCursor: Bool, unreadCount: Int, defaultLimit: Int = 100, hardCap: Int = 500) -> Int {
        hasCursor ? defaultLimit : firstScanFetchLimit(unreadCount: unreadCount, defaultLimit: defaultLimit, hardCap: hardCap)
    }

    /// First whitelist scan classifies unread for the inbox. Those messages
    /// must not enter Autopilot — they can be days old.
    static func shouldEnqueueAutopilotInbound(isFirstWhitelistScan: Bool) -> Bool {
        !isFirstWhitelistScan
    }

    /// A failed session.db read must not persist a newest-message cursor.
    static func shouldPersistFirstScanBaseline(sessionsAvailable: Bool) -> Bool {
        sessionsAvailable
    }

    // MARK: - Cross-group VIP helpers (pure, testable)

    /// Derive the set of usernames for contacts explicitly marked VIP
    /// in their private thread. Excludes VIP-tagged group chats — those
    /// are already handled by the per-entry VIP branch inside the scan
    /// loop, and treating a group id as a "VIP person" would cause the
    /// cross-group detector to match the room itself.
    static func deriveVIPPersonUsernames(whitelist: [WhitelistEntry]) -> Set<String> {
        Set(
            whitelist
                .filter { $0.attentionLevel == .vip && !$0.isGroup }
                .map(\.id)
        )
    }

    /// True when a message from `senderUsername` inside a whitelisted
    /// chat (represented by `entryId` + `entryLevel`) should fire an
    /// additional cross-group VIP trace. Guards against double-counting
    /// messages that the existing `entry.attentionLevel == .vip` branch
    /// already appends.
    static func shouldAppendCrossGroupVIPTrace(
        entryID: String,
        entryLevel: WhitelistAttentionLevel,
        senderUsername: String,
        vipPersonUsernames: Set<String>
    ) -> Bool {
        guard entryID.contains("@chatroom") else { return false }
        guard entryLevel != .vip else { return false }
        return vipPersonUsernames.contains(senderUsername)
    }

    /// Strip leading sender name from snippet to avoid "亮🌸: 亮🌸让你..." duplication.
    private static func deduplicateSenderInSnippet(_ text: String, senderName: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(trimmed.prefix(80))
        guard !senderName.isEmpty else { return snippet }
        // Check if text starts with "senderName" followed by common separators
        for sep in ["：", ":", " ", ""] {
            let prefix = senderName + sep
            if snippet.hasPrefix(prefix) {
                return String(snippet.dropFirst(prefix.count).prefix(80))
            }
        }
        return snippet
    }

    static func buildReplyDebtItems(
        sessions: [SessionInfo],
        reader: WeChatReader,
        chatActions: [String: HUDStore.ChatActionState],
        ignoredSenderMap: [String: Set<String>],
        myUsername: String,
        myDisplayName: String = "",
        mySelfNames: Set<String> = [],
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
            let recentMsgs = (try? reader.getMessages(chatUsername: session.username, limit: 30)) ?? []
            guard !recentMsgs.isEmpty else { return nil }

            let latestInbound = recentMsgs.first {
                !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                    && !MessageHelpers.isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
            }
            guard let inbound = latestInbound else { return nil }

            let latestOutbound = recentMsgs.first {
                MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
            }
            let inboundCountSinceLastOutbound: Int
            if let outbound = latestOutbound {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                        && !MessageHelpers.isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
                        && MessageHelpers.isAfter($0, outbound)
                }.count
            } else {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
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
                isAtMention: MessageHelpers.isAtMe(inbound.text, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames),
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
            try reader.withReadonlyDB(path: decPath) { db in
                var stmt: OpaquePointer?
                let sql = "SELECT name, seq FROM sqlite_sequence WHERE name LIKE 'Msg_%'"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }

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
            }
        }
        return (totalNew, totalScanned)
    }
}
