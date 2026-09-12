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
        /// Chats where the user sent something within
        /// `activeConversationWindow` — a live exchange the user is
        /// watching. Consumers (banner, proactive alerts) should not
        /// re-interrupt for these chats.
        let activeConversations: Set<String>
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
            // One snapshot of every admission input, so the per-message decision
            // stays a pure function with no query on the hot path.
            let admissionRules = AdmissionRules.load(store: store)
            let allContacts = store.loadContacts()
            // Duplicate usernames must not trap the process; see contactLookup.
            let contactMap = Self.contactLookup(allContacts)

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
                admissionRules: admissionRules,
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
            var groupMemberCount = 0
            var unreadCollected: [UnreadItem] = []
            var suppressedCollected: [UnreadItem] = []
            var activeConversations: Set<String> = []

            for session in sessions where session.unreadCount > 0 {
                let isSnoozed = (chatActions[session.username]?.snoozedUntil ?? 0) > nowEpoch
                // Private chats fetch 20, not 5: `latestSelfTime` feeds the
                // live-exchange suppression — with 5, a rapid-fire reply
                // burst (peer sends 6 within the window) pushed your last
                // outbound out of view and alerts fired while you were
                // literally typing in that chat.
                let fetchLimit = session.isGroup ? min(session.unreadCount, 30) : 20
                let recentMsgs = (try? reader.getMessages(
                    chatUsername: session.username,
                    limit: fetchLimit
                )) ?? []

                let latestSelfTime: Int = recentMsgs
                    .filter { MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) }
                    .map { $0.createTime }
                    .max() ?? 0
                if latestSelfTime > 0, nowEpoch - latestSelfTime <= Self.activeConversationWindow {
                    activeConversations.insert(session.username)
                }

                let isWhitelisted = whitelistSet.contains(session.username)
                let isVIP = vipSet.contains(session.username)
                let silencedAt = chatActions[session.username]?.silencedAt ?? 0

                func makeItem(_ msg: MessageInfo, kind: HUDNotificationKind) -> UnreadItem {
                    let ts = Date(timeIntervalSince1970: Double(msg.createTime))
                    let replied = latestSelfTime > msg.createTime
                    // Report the full mute state (this chat and everywhere) so
                    // the row can explain itself.
                    let isIgnored = admissionRules.isMuted(
                        chatUsername: session.username,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName
                    )
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
                    let decision = admissionRules.decide(
                        chatUsername: session.username,
                        isGroup: false,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName,
                        isAtMention: false
                    )
                    if !decision.isAdmitted || isSnoozed || msg.createTime <= silencedAt {
                        suppressedCollected.append(item)
                    } else {
                        privateUnreadChats += 1
                        unreadCollected.append(item)
                    }
                } else {
                    // A room is followed because of the handful of people in
                    // it. Surface @s and the members the user singled out;
                    // let the rest of the traffic stay in WeChat.
                    for msg in recentMsgs {
                        if MessageHelpers.isFromSelf(msg, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) {
                            continue
                        }
                        let isAt = MessageHelpers.isAtMe(msg.text, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames)
                        let decision = admissionRules.decide(
                            chatUsername: session.username,
                            isGroup: true,
                            senderUsername: msg.senderUsername,
                            senderName: msg.senderName,
                            isAtMention: isAt
                        )
                        guard decision.isAdmitted else { continue }
                        let item = makeItem(msg, kind: isAt ? .groupAt : .groupMessage)
                        if isSnoozed || msg.createTime <= silencedAt {
                            suppressedCollected.append(item)
                            continue
                        }
                        if isAt { groupAtCount += 1 } else { groupMemberCount += 1 }
                        unreadCollected.append(item)
                    }
                }
            }

            // Deterministic total order; see unreadOrder. Previously an inline
            // (rank asc, timestamp desc) comparator, which left equal keys in
            // input order.
            let sortedUnread = unreadCollected.sorted(by: Self.unreadOrder)
            let sortedSuppressed = suppressedCollected.sorted { $0.timestamp > $1.timestamp }
            let totalUnread = privateUnreadChats + groupAtCount + groupMemberCount
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
            // Shared budget for backward paging over over-cap unread backlogs,
            // so the whitelist loop stays inside the scan interval.
            var backlogPageBudget = Self.backlogPageBudgetPerScan
            let notificationConfig = store.getSettingJSON("notification", as: NotificationConfig.self) ?? NotificationConfig()

            // Usernames of contacts explicitly marked VIP — used to detect
            // their presence in any whitelisted group chat, not just their
            // own private thread. See `deriveVIPPersonUsernames`.
            let vipPersonUsernames = Self.deriveVIPPersonUsernames(whitelist: whitelist)

            // Build session lookup for timestamp correction. Duplicate
            // usernames must not trap the process; see sessionLookup.
            let sessionMap = Self.sessionLookup(sessions)

            for entry in whitelist {
                let isFirstWhitelistScan = store.getWhitelistCursor(username: entry.id) == nil
                let messages: [MessageInfo]
                var backlogComplete = true
                do {
                    let unreadHint = sessionMap[entry.id]?.unreadCount ?? 0
                    let fetchLimit = Self.whitelistFetchLimit(
                        hasCursor: !isFirstWhitelistScan,
                        unreadCount: unreadHint
                    )
                    // The per-chat page is capped, so a backlog larger than the
                    // cap still needs older pages: the persisted watermark moves
                    // to the newest fetched message, and anything between the old
                    // watermark and this page would never be classified again.
                    // Walk backwards (bounded by a scan-wide page budget) until
                    // the recorded unread backlog is covered.
                    var page = try reader.getMessages(
                        chatUsername: entry.id,
                        limit: fetchLimit,
                        sinceLocalId: nil
                    )
                    // backlogComplete (declared above) tracks whether this scan
                    // saw every unread message, so advancing the watermark below
                    // is lossless. False means the scan-wide page budget ran out
                    // first: the chat keeps its watermark and retries next scan
                    // (a delay, never a silent drop).
                    backlogComplete = true
                    if unreadHint > page.count, !page.isEmpty {
                        if backlogPageBudget <= 0 {
                            backlogComplete = false
                        } else {
                            var seen = Set(page.map(\.id))
                            // Inclusive anchor: the SQL bound keeps the anchor
                            // row and the seen-filter drops the echo. Subtracting
                            // 1 (the old code) assumes localIds are globally
                            // ordered, but they restart per shard file — a tied
                            // row in another shard with the same (createTime,
                            // localId) would fall below the anchor and never be
                            // fetched again.
                            var anchor = page.last.map { ($0.createTime, $0.localId) }
                            var lastFetchWasFull = true
                            while page.count < unreadHint, backlogPageBudget > 0, let cursor = anchor {
                                backlogPageBudget -= 1
                                let older = try reader.getMessages(
                                    chatUsername: entry.id,
                                    limit: fetchLimit,
                                    sinceLocalId: nil,
                                    afterCursor: nil,
                                    beforeCursor: cursor
                                )
                                lastFetchWasFull = older.count >= fetchLimit
                                let fresh = older.filter { seen.insert($0.id).inserted }
                                if fresh.isEmpty {
                                    // Older shards/pages are exhausted; stop
                                    // instead of re-reading the same page forever.
                                    break
                                }
                                page.append(contentsOf: fresh)
                                anchor = fresh.last.map { ($0.createTime, $0.localId) }
                            }
                            // A short last fetch proves the shards are exhausted
                            // (a merged page is short only when every matching
                            // row fit). A full last fetch with the budget spent
                            // may still hide older rows.
                            backlogComplete = page.count >= unreadHint || !lastFetchWasFull
                        }
                    }
                    messages = page
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

                // Smart interruption suppression. `latestSelfTime` is the
                // newest self-authored message in this chat (from the full
                // fetch, not just `newMessages`, so a reply sent between
                // scans is seen even when it shares the same second as the
                // inbound). Two cases mean the user is already inside this
                // conversation and a banner would be noise:
                //   1. already answered — the inbound is older than your
                //      latest self message (you replied after it arrived)
                //   2. live exchange — you sent something here within the
                //      last `activeConversationWindow`s, so inbound replies
                //      are the far side answering you, not a new ask
                // The message still lands in the inbox feed
                // (`perChatLatest`); only the popup is suppressed.
                let latestSelfTime = messages
                    .filter { MessageHelpers.isFromSelf($0, chatUsername: entry.id, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) }
                    .map(\.createTime)
                    .max() ?? 0
                let isLiveExchange = latestSelfTime > 0
                    && nowEpoch - latestSelfTime <= Self.activeConversationWindow
                if isLiveExchange { activeConversations.insert(entry.id) }

                // Queue persistence and the source cursor are one durable
                // unit. A failed queue write must leave the cursor unchanged
                // so the next scan can retry the same source messages.
                var classificationMessages: [MessageInfo] = []
                classificationMessages.reserveCapacity(newMessages.count)
                var autopilotMessagesToQueue: [AutopilotService.InboundMessage] = []
                autopilotMessagesToQueue.reserveCapacity(newMessages.count)
                var discussionMessages: [MessageInfo] = []
                discussionMessages.reserveCapacity(newMessages.count)

                for msg in newMessages {
                    // Collect self messages for commitment tracking BEFORE skipping
                    if MessageHelpers.isFromSelf(msg, chatUsername: entry.id, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) {
                        let recipientName = reader.displayName(for: entry.id)
                        selfOutgoingMessages.append((
                            msg: msg, chatUsername: entry.id,
                            chatName: msg.chatName, recipientName: recipientName
                        ))
                        // Self lines must reach bidirectional extraction in
                        // every followed chat: "我派给对方" items are only
                        // attributed to 等对方 if the model can see them.
                        discussionMessages.append(msg)
                        continue
                    }
                    // Admission owns muting now, so a person muted in every
                    // conversation is honoured here too — not only rules that
                    // were created inside this particular chat.
                    if admissionRules.isMuted(
                        chatUsername: entry.id,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName
                    ) {
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
                        snippet: Self.deduplicateSenderInSnippet(
                            msg.text,
                            senderName: msg.senderName,
                            myUsername: myUname,
                            myDisplayName: myDisplayName,
                            mySelfNames: selfNames
                        ),
                        isAtMention: isAt,
                        timestamp: msgTime,
                        kind: kind
                    )

                    // Someone the user singled out inside this group, or a VIP
                    // speaking here, is worth interrupting for even without an
                    // @. A group muted for @s still reaches the inbox; it just
                    // does not pop up.
                    let isWatchedMember = admissionRules.watchedMembers[entry.id]?
                        .contains(msg.senderUsername) == true
                    let worthInterrupting = isAt || isCrossGroupVIP || isWatchedMember
                    let shouldPresent = notificationConfig.shouldPresent(notif.presentationSemanticState)
                        || (worthInterrupting && notificationConfig.important)
                    let decision = admissionRules.decide(
                        chatUsername: msg.chatUsername,
                        isGroup: kind != .privateChat,
                        senderUsername: msg.senderUsername,
                        senderName: msg.senderName,
                        isAtMention: isAt
                    )
                    let bannerAllowed = AdmissionPolicy.shouldRaiseBanner(
                        decision: decision,
                        chatUsername: msg.chatUsername,
                        isAtMention: isAt,
                        atMutedGroups: admissionRules.config.atMutedGroups
                    )
                    let alreadyAnswered = latestSelfTime > msg.createTime
                    let suppressPopup = alreadyAnswered || isLiveExchange
                    if decision.isAdmitted,
                       shouldPresent,
                       bannerAllowed,
                       !suppressPopup,
                       (latestPreview == nil || msgTime > latestPreview!.timestamp) {
                        latestPreview = notif
                    }

                    if decision.isAdmitted {
                        if let existing = perChatLatest[msg.chatUsername],
                           existing.timestamp >= msgTime {
                            // keep existing
                        } else {
                            perChatLatest[msg.chatUsername] = notif
                        }
                    }

                    // Collect for autopilot: private chats + group @mentions.
                    if decision.isAdmitted, kind == .privateChat || kind == .groupAt {
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
                    if decision.isAdmitted, entry.attentionLevel == .vip {
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
                    ), decision.isAdmitted {
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
                    if decision.isAdmitted {
                        newInboundForClassifier.append((
                            msg: msg,
                            chatUsername: entry.id,
                            isVIP: entry.attentionLevel == .vip
                        ))
                        classificationMessages.append(msg)
                        discussionMessages.append(msg)
                    }
                }

                if currentCursor.0 > baseline.lastCreateTime
                    || (currentCursor.0 == baseline.lastCreateTime && currentCursor.1 > baseline.lastLocalId) {
                    // The backfill above ran out of scan-wide page budget with
                    // the backlog uncovered. Advancing the watermark to the
                    // newest fetched message would orphan everything between
                    // the old watermark and this page — the exact loss the
                    // backfill exists to prevent. Leave the watermark so the
                    // next scan retries this chat once earlier chats drain.
                    if !backlogComplete {
                        continue
                    }
                    do {
                        try store.withTransaction {
                            // Discussion extraction includes both sides of the
                            // conversation, while classification receives only
                            // non-self, non-ignored inbound messages above.
                            if !discussionMessages.isEmpty {
                                try store.enqueueDiscussionMessages(discussionMessages)
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
                mergedRecent.sort(by: Self.recentNotificationOrder)
                if mergedRecent.count > recentLimit {
                    mergedRecent = Array(mergedRecent.prefix(recentLimit))
                }
            }
            let vipCount = mergedRecent.filter(\.isVIP).count

            // ---- Autopilot: scan non-whitelist private chats ----
            // Private chats that are VIP/关注 but missing from whitelist still
            // reach autopilot. 仅保留资料 and strangers do not.
            //
            // This pass reuses the `sessions` snapshot read at the top of the
            // scan instead of calling `reader.getSessions()` again, which read
            // session.db a second time on every scan. A first read that failed
            // has already been logged and degraded the scan; retrying the
            // identical read microseconds later cannot plausibly succeed.
            //
            // Contacts come from the scan-start `contactMap` snapshot rather
            // than `store.getContact` per message, turning an O(messages) set of
            // SQL round trips into dictionary hits. The snapshot is taken before
            // this loop and nothing in the scan writes contacts, so it observes
            // the same rows the per-message query would have.
            for session in sessions {
                // Skip group chats, already-scanned whitelist chats, and chatrooms
                guard !session.username.contains("@chatroom"),
                      !whitelistSet.contains(session.username),
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
                    // Indexed against the scan-start contact snapshot; the
                    // previous per-message `store.getContact` was a SQL
                    // round trip for every candidate message.
                    guard let contact = contactMap[msg.senderUsername] else {
                        continue
                    }
                    // 仅保留资料 / 未关注 stay off autopilot. Copy is
                    // "只记住是谁，不日常提醒。"
                    guard contact.attentionLevel == .vip || contact.attentionLevel == .whitelist else {
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
                selfOutgoingMessages: selfOutgoingMessages,
                activeConversations: activeConversations
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

    /// Extra backward pages one scan may fetch to cover over-cap unread
    /// backlogs. Shared by every chat in the scan so a single noisy chat
    /// cannot stretch the scan past its interval.
    static let backlogPageBudgetPerScan = 6

    /// Page size for a whitelist chat.
    ///
    /// Both the first scan and every later scan must cover the recorded unread
    /// backlog: the cursor always advances to the newest fetched message, so a
    /// fixed 100-row page on the `hasCursor` path silently dropped the middle
    /// of any larger backlog (the session.db unread counter is exactly that
    /// size). The caller additionally pages backwards when the backlog exceeds
    /// this cap.
    static func whitelistFetchLimit(hasCursor: Bool, unreadCount: Int, defaultLimit: Int = 100, hardCap: Int = 500) -> Int {
        _ = hasCursor
        return firstScanFetchLimit(unreadCount: unreadCount, defaultLimit: defaultLimit, hardCap: hardCap)
    }

    /// First whitelist scan classifies unread for the inbox. Those messages
    /// must not enter Autopilot — they can be days old.
    /// How long after your last outbound message a chat still counts as a
    /// live exchange. Inside the window, inbound replies don't re-pop the
    /// banner — you're literally in that conversation.
    static let activeConversationWindow: Int = 120

    static func shouldEnqueueAutopilotInbound(isFirstWhitelistScan: Bool) -> Bool {
        !isFirstWhitelistScan
    }

    /// A failed session.db read must not persist a newest-message cursor.
    static func shouldPersistFirstScanBaseline(sessionsAvailable: Bool) -> Bool {
        sessionsAvailable
    }

    // MARK: - Username lookup builders (pure, testable)

    /// Username -> contact lookup for the whole scan.
    ///
    /// Why duplicates happen: the contacts table has no UNIQUE constraint on
    /// username, so multi-account rows or leftovers from a re-import can repeat
    /// the same username. Dictionary(uniqueKeysWithValues:) traps on a
    /// duplicate, and that trap is uncatchable — it takes the whole app down
    /// mid-scan. Collapsing duplicates here keeps the scan alive.
    ///
    /// Why first-wins: every later contactMap[...] lookup is by username only,
    /// so it cannot tell the duplicate rows apart anyway. Keeping the first row
    /// preserves the row this scan would previously have observed, and it
    /// cannot trap.
    static func contactLookup(_ contacts: [ContactEntry]) -> [String: ContactEntry] {
        Dictionary(contacts.map { ($0.username, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Username -> session lookup, same duplicate policy as contactLookup:
    /// session.db has no UNIQUE constraint on username either (multi-account /
    /// leftover rows repeat it), and this map is only ever indexed by username,
    /// so the first row wins instead of trapping the process.
    static func sessionLookup(_ sessions: [SessionInfo]) -> [String: SessionInfo] {
        Dictionary(sessions.map { ($0.username, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Deterministic ordering (pure, testable)

    /// Triage severity used as the primary unread sort key. Lower = more urgent.
    static func unreadStatusRank(_ status: UnreadStatus) -> Int {
        switch status {
        case .overdue: return 0
        case .pending: return 1
        case .answered: return 2
        }
    }

    /// Total order for the unread list: urgency asc (overdue -> pending ->
    /// answered), then timestamp desc, then stable identity keys. The old
    /// comparator stopped at the timestamp, so equal (status, timestamp) pairs
    /// came out in input-array order; that order changes as rows are re-read,
    /// which rebuilds whole SwiftUI rows while nothing visible changed. The
    /// primary semantics are unchanged: rank still dominates, and a newer
    /// timestamp still wins inside a rank.
    static func unreadOrder(_ a: UnreadItem, _ b: UnreadItem) -> Bool {
        let ra = unreadStatusRank(a.status), rb = unreadStatusRank(b.status)
        if ra != rb { return ra < rb }
        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
        if a.chatUsername != b.chatUsername { return a.chatUsername < b.chatUsername }
        if a.senderUsername != b.senderUsername { return a.senderUsername < b.senderUsername }
        if a.preview != b.preview { return a.preview < b.preview }
        return kindOrder(a.kind) < kindOrder(b.kind)
    }

    /// Total order for the recent-notification feed: newest first, then chat
    /// username, then message id. The old comparator was timestamp-only, so
    /// equal timestamps kept input order and the feed could reshuffle with no
    /// visible cause. Timestamp still dominates exactly as before.
    static func recentNotificationOrder(_ a: HUDNotification, _ b: HUDNotification) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
        if a.chatUsername != b.chatUsername { return a.chatUsername < b.chatUsername }
        if a.messageID != b.messageID { return a.messageID < b.messageID }
        return kindOrder(a.kind) < kindOrder(b.kind)
    }

    /// Final tiebreak for both orders: a fixed kind order so two items that
    /// agree on every other key still compare deterministically.
    private static func kindOrder(_ kind: HUDNotificationKind) -> Int {
        switch kind {
        case .groupAt: return 0
        case .privateChat: return 1
        case .groupMessage: return 2
        }
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
    private static func deduplicateSenderInSnippet(
        _ text: String,
        senderName: String,
        myUsername: String = "",
        myDisplayName: String = "",
        mySelfNames: Set<String> = []
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var snippet = String(trimmed.prefix(80))
        // Leading "@我"/"@所有人" tokens are redundant on the banner: the
        // identity line already carries a mention chip, and the body should
        // start at the content. Only strip mentions aimed at the user (or
        // @所有人/@All); a leading "@张三" directed at somebody else carries
        // meaning and stays. The chip distinguishes the two cases — "@全员" for
        // a broadcast, "@你" for a personal mention — precisely because the
        // token itself is gone by the time the banner renders.
        while snippet.hasPrefix("@") {
            guard let space = snippet.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "　" }) else { break }
            let token = String(snippet[snippet.index(after: snippet.startIndex)..<space])
            let isMe = token == "所有人" || token.lowercased() == "all"
                || token == myUsername || (!myDisplayName.isEmpty && token == myDisplayName)
                || mySelfNames.contains(token)
            guard isMe else { break }
            snippet = String(snippet[snippet.index(after: space)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        admissionRules: AdmissionRules,
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

            // 预先把身份判定结果算好，评分器只消费结论：它不该知道
            // myUsername/mySelfNames 这套身份体系。窗口保留整个 30 条，评分时
            // 才能翻回「对方先说正事、我 ack 一句、对方再补个『好』」之前的那条
            // 正事 —— 只看最新一条时它会消失。
            func isFromSelf(_ msg: MessageInfo) -> Bool {
                MessageHelpers.isFromSelf(
                    msg,
                    chatUsername: session.username,
                    myUsername: myUsername,
                    myDisplayName: myDisplayName,
                    mySelfNames: mySelfNames
                )
            }
            func isAtMe(_ msg: MessageInfo) -> Bool {
                MessageHelpers.isAtMe(
                    msg.text,
                    myUsername: myUsername,
                    myDisplayName: myDisplayName,
                    mySelfNames: mySelfNames
                )
            }
            let timeline = recentMsgs.map { msg in
                ReplyDebtScorer.TimelineEntry(
                    message: msg,
                    isFromSelf: isFromSelf(msg),
                    isAtMe: isAtMe(msg)
                )
            }

            let latestInbound = recentMsgs.first {
                !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                    && !admissionRules.isMuted(
                        chatUsername: session.username,
                        senderUsername: $0.senderUsername,
                        senderName: $0.senderName
                    )
            }
            guard let inbound = latestInbound else { return nil }

            let latestOutbound = recentMsgs.first {
                MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
            }
            let inboundCountSinceLastOutbound: Int
            if let outbound = latestOutbound {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                        && !admissionRules.isMuted(
                            chatUsername: session.username,
                            senderUsername: $0.senderUsername,
                            senderName: $0.senderName
                        )
                        && MessageHelpers.isAfter($0, outbound)
                }.count
            } else {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                        && !admissionRules.isMuted(
                            chatUsername: session.username,
                            senderUsername: $0.senderUsername,
                            senderName: $0.senderName
                        )
                }.count
            }

            let admission = admissionRules.decision(
                chatUsername: session.username,
                isGroup: session.isGroup,
                messages: recentMsgs,
                isFromSelf: {
                    MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                },
                isAtMe: {
                    MessageHelpers.isAtMe($0.text, myUsername: myUsername, myDisplayName: myDisplayName, mySelfNames: mySelfNames)
                }
            )

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
                contactReplyWindowMinutes: contactMap[session.username]?.replyWindowMinutes,
                admission: admission,
                timeline: timeline
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
