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
        /// `contact.db` moved during this scan's prep, so persisted display
        /// names may be stale. Carried out here because deciding that requires
        /// the reader's DB lock, which the main actor must not take.
        let contactsChanged: Bool
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
            // Actor facade: scan prep, identity, batch unread/autopilot, and
            // whitelist paging go through WeChatReaderActor. ReplyDebt and a
            // few helpers still take the lock-backed `reader` directly.
            let readerActor = WeChatReaderActor(reader)
            let contactsChanged = try await readerActor.prepareForScan()

            let chatActions = store.loadChatActions()
            let nowEpoch = Int(Date().timeIntervalSince1970)

            let sessions: [SessionInfo]
            do {
                sessions = try await readerActor.sessions()
            } catch {
                print("[WCHUD] getSessions failed (DB locked?): \(error) — using empty session list")
                sessions = []
            }
            let myUname = await readerActor.myUsername()
            let myDisplayName = await readerActor.displayName(for: myUname)
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
            let msgDBs = await readerActor.findMessageDBs()
            if let changed = changedRelPaths {
                let changedSet = Set(changed)
                for relPath in msgDBs where changedSet.contains(relPath) {
                    _ = try? await readerActor.refreshIfChanged(relPath: relPath)
                }
            } else {
                for relPath in msgDBs {
                    _ = try? await readerActor.refreshIfChanged(relPath: relPath)
                }
            }

            let selfNames = await readerActor.mySelfNames()
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

            var privateUnreadMessages = 0
            var groupAtCount = 0
            var groupMemberCount = 0
            var unreadCollected: [UnreadItem] = []
            var suppressedCollected: [UnreadItem] = []
            var activeConversations: Set<String> = []

            let unreadSessions = sessions.filter { $0.unreadCount > 0 }
            let unreadBatch = (try? await readerActor.messagesBatch(
                unreadSessions.map { session in
                    // Private chats fetch a window, not 5: `latestSelfTime` feeds
                    // the live-exchange suppression — with 5, a rapid-fire reply
                    // burst (peer sends 6 within the window) pushed your last
                    // outbound out of view and alerts fired while you were
                    // literally typing in that chat. The window also has to cover
                    // the whole unanswered tail, because the folded row reports
                    // 「有 N 条还没回」 — a fixed 20 made 26 DMs read as 20.
                    let fetchLimit = Self.unreadFetchLimit(session)
                    return WeChatReader.MessageBatchRequest(
                        chatUsername: session.username,
                        limit: fetchLimit
                    )
                }
            )) ?? [:]

            for session in unreadSessions {
                let isSnoozed = (chatActions[session.username]?.snoozedUntil ?? 0) > nowEpoch
                let recentMsgs = unreadBatch[session.username] ?? []

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

                func makeItem(
                    _ msg: MessageInfo,
                    kind: HUDNotificationKind,
                    unansweredInboundCount: Int = 1
                ) -> UnreadItem {
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
                        isIgnored: isIgnored,
                        unansweredInboundCount: unansweredInboundCount
                    )
                }

                if !session.isGroup {
                    // Fetched newest-first, so `first` is their latest message and
                    // the whole older tail gets folded into this one row.
                    let inboundMsgs = recentMsgs.filter {
                        !MessageHelpers.isFromSelf($0, chatUsername: session.username, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames)
                    }
                    guard let msg = inboundMsgs.first else { continue }
                    var item = makeItem(
                        msg,
                        kind: .privateChat,
                        // Without this the row looks like "1 message", and the
                        // 「多条未回」 rule — which counts what the rows stand for,
                        // not how many rows exist — can never see a private burst.
                        unansweredInboundCount: inboundMsgs.filter {
                            $0.createTime > latestSelfTime
                        }.count
                    )
                    // Honest floor: WeChat's own unread count says more arrived
                    // than the page could hold, and every row in the page was
                    // inbound (so nothing was dropped to self-message padding).
                    // Below that the count is exact — 26 fetched out of 26 is 26.
                    item.unansweredCountIsFloor = inboundMsgs.count == recentMsgs.count
                        && session.unreadCount > recentMsgs.count
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
                        privateUnreadMessages += item.inboundMessageCount
                        unreadCollected.append(item)
                    }
                } else {
                    // A room is followed because of the handful of people in
                    // it. Surface @s and the members the user singled out;
                    // let the rest of the traffic stay in WeChat.
                    //
                    // WeChat's own unread count is the ceiling: the page is
                    // fetched wider than the unread set (self messages and
                    // bystander traffic are in it), and @-mentions the user
                    // already read on the phone are still in it. Without the
                    // cap a room reporting 1 unread contributed 31 to
                    // 「未读 N 条」 and to the @ badge.
                    var roomBudget = max(session.unreadCount, 0)
                    for msg in recentMsgs {
                        if roomBudget == 0 { break }
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
                        roomBudget -= 1
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
            // Every term counts *messages*. Private chats used to contribute one
            // per chat while group chats contributed one per message, and the
            // only consumer publishes this as 日报's 「未读 N 条」.
            let totalUnread = privateUnreadMessages + groupAtCount + groupMemberCount
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
            /// Newest self-authored row per whitelisted chat this scan — the
            /// "already answered" evidence used to evict stale feed rows when
            /// mergedRecent is assembled below.
            var latestSelfByChat: [String: MessageInfo] = [:]
            /// This scan's fetched page for chats that produced a self row —
            /// lets the eviction compare localId ordering for same-second
            /// messages instead of trusting second-resolution timestamps.
            /// Array assignment shares the page's buffer, so this is free.
            var fetchedPageByChat: [String: [MessageInfo]] = [:]
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
                // 读不到水位时这一条本轮什么都不做：当「从没扫过」会把水位推到最新，
                // 中间那段消息此后再也不会被扫到；沿用旧值又是另一种猜法。
                let cursorRead = store.whitelistCursorRead(username: entry.id)
                if case .unreadable = cursorRead {
                    print("[WCHUD] scan: 水位读不到，跳过该对话本轮: \(entry.id)")
                    continue
                }
                let storedCursor: (lastCreateTime: Int, lastLocalId: Int, lastShard: String)?
                switch cursorRead {
                case .value(let lastCreateTime, let lastLocalId, let lastShard):
                    storedCursor = (lastCreateTime, lastLocalId, lastShard)
                case .neverScanned, .unreadable:
                    storedCursor = nil
                }
                let isFirstWhitelistScan = storedCursor == nil
                let messages: [MessageInfo]
                var currentCursor = (0, 0)
                var baseline = (lastCreateTime: 0, lastLocalId: 0)
                var backlogComplete = true
                var frontierToPersist: (lastCreateTime: Int, lastLocalId: Int)? = nil
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
                    var page = try await readerActor.getMessages(
                        chatUsername: entry.id,
                        limit: fetchLimit,
                        sinceLocalId: nil
                    )
                    // backlogComplete (declared above) tracks whether this scan
                    // saw every unread message AND closed the gap to the
                    // persisted baseline, so advancing the watermark below is
                    // lossless. False means the walk is still in flight: the
                    // chat keeps its watermark and the walk resumes from a
                    // persisted frontier next scan (a delay, never a silent
                    // drop — and fetched rows are still enqueued below).
                    //
                    // `unreadHint` counts *inbound* unread rows from session.db,
                    // while `page` mixes inbound and self-sent rows — comparing
                    // the hint against `page.count` lets self messages pad the
                    // page and can stop the walk with unread inbound rows still
                    // beyond the cursor. Count inbound rows instead.
                    func isInbound(_ msg: MessageInfo) -> Bool {
                        !MessageHelpers.isFromSelf(
                            msg, chatUsername: entry.id,
                            myUsername: myUname, myDisplayName: myDisplayName,
                            mySelfNames: selfNames
                        )
                    }
                    var inboundInPage = page.reduce(0) { $0 + (isInbound($1) ? 1 : 0) }
                    // Same message reappearing under a different id after a
                    // cross-shard WCDB move is dropped by the content key.
                    var seen = Set(page.map(\.id))
                    var seenContent = Set(page.map(\.contentKey))
                    var pagesThisChat = 1
                    var lastFetchWasFull = true

                    // For an established cursor the walk's target is the
                    // persisted baseline — the gap between the page bottom and
                    // the baseline is unread-by-WeChat-but-unscanned history
                    // (read on the phone between scans) that used to be
                    // skipped forever. A persisted frontier resumes an
                    // earlier scan's interrupted walk instead of restarting
                    // at the page bottom every scan. First scans have no
                    // baseline; their walk exists only to cover the unread
                    // backlog before seeding.
                    let basePos = storedCursor.map { ($0.lastCreateTime, $0.lastLocalId) }
                    var anchor = (storedCursor != nil
                        ? store.getBackfillCursor(username: entry.id)
                        : nil) ?? page.last.map { ($0.createTime, $0.localId) }

                    func exceedsBaseline(_ c: (Int, Int)) -> Bool {
                        guard let b = basePos else { return false }
                        return c.0 > b.0 || (c.0 == b.0 && c.1 > b.1)
                    }

                    while (inboundInPage < unreadHint
                           || (anchor.map { exceedsBaseline($0) } ?? false)),
                          backlogPageBudget > 0,
                          pagesThisChat < Self.maxBackfillPagesPerChat,
                          let cursor = anchor {
                        backlogPageBudget -= 1
                        pagesThisChat += 1
                        let older = try await readerActor.getMessages(
                            chatUsername: entry.id,
                            limit: fetchLimit,
                            sinceLocalId: nil,
                            afterCursor: nil,
                            beforeCursor: cursor
                        )
                        lastFetchWasFull = older.count >= fetchLimit
                        let fresh = older.filter {
                            seen.insert($0.id).inserted
                                && seenContent.insert($0.contentKey).inserted
                        }
                        if fresh.isEmpty {
                            // Older shards/pages are exhausted; stop
                            // instead of re-reading the same page forever.
                            break
                        }
                        inboundInPage += fresh.reduce(0) { $0 + (isInbound($1) ? 1 : 0) }
                        page.append(contentsOf: fresh)
                        anchor = fresh.last.map { ($0.createTime, $0.localId) }
                        if !(anchor.map { exceedsBaseline($0) } ?? false) {
                            // Reached (or passed) the persisted baseline.
                            break
                        }
                    }
                    // Gap closed when there is no baseline to reach, the walk
                    // reached it, or the shards are exhausted (a short final
                    // page proves no deeper rows exist). A full last fetch
                    // with budget spent may still hide older rows.
                    let gapClosed = basePos == nil
                        || !(anchor.map { exceedsBaseline($0) } ?? false)
                        || !lastFetchWasFull
                    backlogComplete = (inboundInPage >= unreadHint || !lastFetchWasFull)
                        && gapClosed
                    if !backlogComplete, let a = anchor { frontierToPersist = a }
                    messages = page
                    currentCursor = page.first.map { ($0.createTime, $0.localId) } ?? (0, 0)

                    // Resolve the baseline for "what's new since last scan".
                    // If no baseline is stored (first scan for this chat —
                    // typically right after the user adds it to the
                    // whitelist), seed it to cover the existing unread
                    // backlog. Otherwise adding a new whitelist entry while
                    // there are unread messages would silently swallow
                    // them: we'd seed to the newest message time and none
                    // of the backlog would pass the `> baseline` filter.
                    // For a first scan this runs AFTER the walk so the seed
                    // sees the full unread coverage, not just page one.
                    if let existing = storedCursor {
                        baseline = (existing.lastCreateTime, existing.lastLocalId)
                    } else if sessions.isEmpty {
                        // Unread counts come from session.db. An empty list is a
                        // locked/failed read, not "no unread". Do not persist a
                        // newest-message cursor that would swallow the backlog.
                        baseline = currentCursor
                    } else {
                        let unreadCount = sessionMap[entry.id]?.unreadCount ?? 0
                        let seed: (lastCreateTime: Int, lastLocalId: Int)
                        if unreadCount > 0 && !messages.isEmpty {
                            // Messages are newest-first. Unread rows are inbound
                            // (you cannot have an unread message you sent), so the
                            // N-th unread is the N-th *inbound* row — indexing the
                            // mixed-direction list by `unreadCount - 1` lands early
                            // whenever self-sent rows sit among the newest N, and
                            // the seed then drops the oldest unread messages.
                            let inbound = messages.filter {
                                !MessageHelpers.isFromSelf(
                                    $0, chatUsername: entry.id,
                                    myUsername: myUname, myDisplayName: myDisplayName,
                                    mySelfNames: selfNames
                                )
                            }
                            let lastUnreadIdx = min(unreadCount, inbound.count) - 1
                            if lastUnreadIdx >= 0 {
                                let oldestUnread = inbound[lastUnreadIdx]
                                seed = (oldestUnread.createTime, max(0, oldestUnread.localId - 1))
                            } else {
                                // Unread reported but no inbound row fetched: keep
                                // everything new rather than swallowing the backlog.
                                seed = (0, 0)
                            }
                        } else if currentCursor.0 > 0 {
                            seed = currentCursor
                        } else {
                            seed = (Int(Date().timeIntervalSince1970), 0)
                        }
                        baseline = seed
                    }
                } catch { continue }

                // localId orders rows only within one shard. A row written at
                // the same second into a DIFFERENT message_N.db (a mid-write
                // WCDB checkpoint move, or shard rotation between scans) is
                // not "seen" just because its localId is small — admit it and
                // let the durable content_key dedup absorb the replay.
                // Empty shard = pre-migration cursor → the shard is unknown;
                // admitting on a mismatch would replay every same-second row.
                let baselineShard = storedCursor?.lastShard ?? ""
                let newMessages = messages.filter {
                    if $0.createTime > baseline.lastCreateTime { return true }
                    guard $0.createTime == baseline.lastCreateTime else { return false }
                    if $0.localId > baseline.lastLocalId { return true }
                    return !baselineShard.isEmpty && $0.shardRelPath != baselineShard
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
                // Answered-feed eviction needs the newest self REPLY, which is
                // stricter than live-exchange evidence: sysKind rows (e.g. the
                // revokemsg "你撤回了一条消息") can carry my sender id — a recall
                // is activity in the chat but it is not a reply.
                let latestSelfMsg = messages
                    .filter { $0.sysKind == nil && MessageHelpers.isFromSelf($0, chatUsername: entry.id, myUsername: myUname, myDisplayName: myDisplayName, mySelfNames: selfNames) }
                    .max { MessageHelpers.isAfter($1, $0) }
                if let selfMsg = latestSelfMsg {
                    latestSelfByChat[entry.id] = selfMsg
                    fetchedPageByChat[entry.id] = messages
                }
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
                    // sysmsg rows are rendered events, not conversation
                    // content — they must not feed classification,
                    // autopilot, discussion extraction, or the commitment
                    // tracker. revokemsg rows additionally drive the recall
                    // pipeline (insert is OR IGNORE → re-scan idempotent).
                    if msg.sysKind == "revokemsg" {
                        Self.recordRecall(
                            msg, chatUsername: entry.id,
                            candidates: messages, contactMap: contactMap,
                            store: store,
                            myUsername: myUname, myDisplayName: myDisplayName,
                            mySelfNames: selfNames
                        )
                        continue
                    }
                    if msg.sysKind != nil { continue }
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
                    if !MessageHelpers.isMultiPartyChat(msg.chatUsername) {
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
                    //
                    // `isAt` deliberately stays out of this: an @ has its own
                    // switch on the 提醒方式 page, and OR-ing it in here meant
                    // turning that switch off did nothing as long as 重点关注
                    // was on — two controls, one behavior, no way to opt out.
                    let isWatchedMember = admissionRules.watchedMembers[entry.id]?
                        .contains(msg.senderUsername) == true
                    let worthInterrupting = isCrossGroupVIP || isWatchedMember
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
                    // A permanently-silenced chat (silencedAt = now+10yr)
                    // must not pop banners on every new message — the inbox
                    // row hides it, but the banner path used to ignore the
                    // mute entirely. Snoozed chats keep bannering: snooze is
                    // a "hide the row" affordance, not a mute.
                    let isSilenced = chatActions[msg.chatUsername]?
                        .isPermanentlySilenced(nowEpoch: nowEpoch) ?? false
                    let suppressPopup = alreadyAnswered || isLiveExchange || isSilenced
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
                            isGroup: MessageHelpers.isMultiPartyChat(msg.chatUsername),
                            isAtMention: isAt,
                            attentionLevel: level,
                            contactRole: contact?.role ?? .acquaintance,
                            timestamp: msg.createTime,
                            messageType: msg.baseType,
                            appType: msg.appType
                        )
                        if autopilotActive && !isSilenced
                            && Self.shouldEnqueueAutopilotInbound(isFirstWhitelistScan: isFirstWhitelistScan) {
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
                    // An incomplete backlog walk used to `continue` here —
                    // leaving the watermark meant the SAME chat could consume
                    // the shared page budget on every scan while the newest
                    // rows it already fetched were never enqueued. Now the
                    // fetched rows are always enqueued (durable dedup makes
                    // the re-scan idempotent); only the watermark is held,
                    // and the walk resumes from a persisted frontier so a
                    // multi-page gap converges over scans instead of
                    // restarting at the page bottom forever.
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
                            if backlogComplete {
                                try store.setWhitelistCursor(
                                    username: entry.id,
                                    lastCreateTime: currentCursor.0,
                                    lastLocalId: currentCursor.1,
                                    lastShard: messages.first?.shardRelPath ?? ""
                                )
                                try store.clearBackfillCursor(username: entry.id)
                            } else if let frontier = frontierToPersist {
                                try store.setBackfillCursor(
                                    username: entry.id,
                                    lastCreateTime: frontier.lastCreateTime,
                                    lastLocalId: frontier.lastLocalId
                                )
                            }
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
            }
            // Answered-feed eviction: once your own newest message in a chat
            // is at/after the stored notification's source message, the row's
            // job is done — before this, a chat you had already replied to in
            // WeChat kept its "私聊更新 / @了你" row until the recent-limit
            // pushed it out or you dismissed it by hand. Replies produce no
            // inbound rows, so without this pass nothing ever cleared them.
            // Runs before the limit truncation so answered rows can't hold
            // slots that newer unanswered chats should take.
            if !latestSelfByChat.isEmpty {
                mergedRecent.removeAll { notif in
                    guard let mine = latestSelfByChat[notif.chatUsername] else { return false }
                    if let source = fetchedPageByChat[notif.chatUsername]?
                        .first(where: { $0.id == notif.messageID }) {
                        return MessageHelpers.isSameOrAfter(mine, source)
                    }
                    // The source row left the fetched window, or moved
                    // message_N.db shards (which rewrites its id): fall back
                    // to the notification's timestamp — max(create_time,
                    // session ts) capped at now. Your own reply bumps the
                    // session timestamp too, so >= is the right edge.
                    return mine.createTime >= Int(notif.timestamp.timeIntervalSince1970)
                }
            }
            mergedRecent.sort(by: Self.recentNotificationOrder)
            if mergedRecent.count > recentLimit {
                mergedRecent = Array(mergedRecent.prefix(recentLimit))
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
            let autopilotSessions = sessions.filter { session in
                !MessageHelpers.isMultiPartyChat(session.username)
                    && !whitelistSet.contains(session.username)
                    && session.unreadCount > 0
            }
            let autopilotBatch = (try? await readerActor.messagesBatch(
                autopilotSessions.map {
                    WeChatReader.MessageBatchRequest(chatUsername: $0.username, limit: 20)
                }
            )) ?? [:]

            for session in autopilotSessions {
                // Only scan recent private chats with unread messages
                guard let messages = autopilotBatch[session.username] else { continue }

                // Same three answers as the whitelist path: a watermark this
                // process could not read must not be mistaken for 「从没扫过」,
                // because the else branch below baselines to the newest row and
                // everything between the old watermark and now is then lost to
                // autopilot for good.
                if case .unreadable = store.autopilotCursorRead(username: session.username) {
                    print("[WCHUD] autopilot: 水位读不到，跳过该会话本轮: \(session.username)")
                    continue
                }
                guard let baseline = store.getAutopilotCursor(username: session.username) else {
                    let seed = messages.first.map { ($0.createTime, $0.localId, $0.shardRelPath) }
                        ?? (Int(Date().timeIntervalSince1970), 0, "")
                    do {
                        try store.setAutopilotCursor(
                            username: session.username,
                            lastCreateTime: seed.0,
                            lastLocalId: seed.1,
                            lastShard: seed.2
                        )
                    } catch {
                        print("[WCHUD] autopilot queue persistence failed; scan watermark unchanged for retry")
                    }
                    continue
                }

                // Same shard rule as the whitelist pass: a same-second row
                // in a different message_N.db isn't covered by the localId
                // comparison — admit it; the inbound queue's content_key
                // dedup absorbs the replay. An empty baseline shard means
                // "unknown" (pre-migration cursor) — admitting on a shard
                // mismatch would re-queue every same-second row forever.
                let baselineShard = baseline.lastShard
                let newMessages = messages.filter {
                    if $0.createTime > baseline.lastCreateTime { return true }
                    guard $0.createTime == baseline.lastCreateTime else { return false }
                    if $0.localId > baseline.lastLocalId { return true }
                    return !baselineShard.isEmpty && $0.shardRelPath != baselineShard
                }
                var autopilotMessagesToQueue: [AutopilotService.InboundMessage] = []
                autopilotMessagesToQueue.reserveCapacity(newMessages.count)
                for msg in newMessages {
                    if msg.sysKind != nil { continue }
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
                    // The second feed of the same decision, and it had no mute
                    // check at all: 静音此对话 hid the inbox row and the banner
                    // (:679) while this path kept handing the conversation to
                    // the unattended reply pipeline — the one surface that used
                    // to show the incoming message was hidden, and a reply still
                    // went out to that peer.
                    guard chatActions[msg.chatUsername]?
                            .isPermanentlySilenced(nowEpoch: nowEpoch) != true else {
                        continue
                    }
                    if autopilotActive {
                        // Persist this queue row together with the
                        // autopilot cursor below. A failed insert must
                        // leave the cursor behind so the next scan retries.
                        autopilotMessagesToQueue.append(inbound)
                    }
                    autopilotInbound.append(inbound)
                }

                // Update baseline. A window whose only new rows are
                // same-second cross-shard rows still must enqueue them — the
                // transaction can't be gated on the cursor advancing — but
                // the cursor itself only moves on a strict (time, localId)
                // win so a lower-localId row never drags the watermark back.
                if let newest = newMessages.first {
                    let cursorAdvances =
                        newest.createTime > baseline.lastCreateTime
                        || (newest.createTime == baseline.lastCreateTime && newest.localId > baseline.lastLocalId)
                    do {
                        try store.withTransaction {
                            if autopilotActive {
                                for inbound in autopilotMessagesToQueue {
                                    try store.enqueueAutopilotInbound(inbound)
                                }
                            }
                            if cursorAdvances {
                                try store.setAutopilotCursor(
                                    username: session.username,
                                    lastCreateTime: newest.createTime,
                                    lastLocalId: newest.localId,
                                    lastShard: newest.shardRelPath
                                )
                            }
                        }
                    } catch {
                        print("[WCHUD] autopilot queue persistence failed; scan watermark unchanged for retry")
                    }
                }
            }

            // Ephemeral-cache hygiene belongs to this side of the scan: it
            // takes the reader's DB lock and removes files, and the main-actor
            // apply used to pay for it once per scan — while a background
            // decrypt could be holding that same lock.
            reader.purgeEphemeralCache()

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
                activeConversations: activeConversations,
                contactsChanged: contactsChanged
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

    /// Hard ceiling on the per-chat unread page. A private chat's single folded
    /// row reports how many messages it stands for, so this is also the largest
    /// 「有 N 条还没回」 the app can state as exact — beyond it the row marks the
    /// number as a floor (see `UnreadItem.unansweredCountIsFloor`).
    static let unreadWindowCap = 60

    /// The page size one session's unread feed fetches. Group rooms need
    /// headroom because `unreadCount` counts inbound rows while the page mixes
    /// in self rows; private chats need at least the whole unanswered tail.
    static func unreadFetchLimit(_ session: SessionInfo) -> Int {
        // `unread_count` is WeChat's column, not ours. Clamp before the group
        // doubling: a corrupt or future-schema value would otherwise trap on
        // `* 2` and kill the resident process over a page size.
        let unread = min(max(session.unreadCount, 0), unreadWindowCap)
        let wanted = session.isGroup ? unread * 2 : unread
        return min(max(wanted, 20), unreadWindowCap)
    }

    /// Extra backward pages one scan may fetch to cover over-cap unread
    /// backlogs. Shared by every chat in the scan so a single noisy chat
    /// cannot stretch the scan past its interval.
    static let backlogPageBudgetPerScan = 6

    /// Pages one chat may consume per scan (the initial fetch counts as one).
    /// Without a per-chat cap, a single deep backlog eats the whole
    /// `backlogPageBudgetPerScan` on every scan and later whitelist entries
    /// starve forever.
    static let maxBackfillPagesPerChat = 3

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

    /// Record a recalled-message event. `recall` is the type-10000 revokemsg
    /// row (its rendered text is the replacemsg payload "「X」撤回了一条消息");
    /// the original message is looked up in the freshly-fetched window by
    /// sender name within a 10-minute horizon.
    static func recordRecall(
        _ recall: MessageInfo,
        chatUsername: String,
        candidates: [MessageInfo],
        contactMap: [String: ContactEntry],
        store: HUDStore,
        myUsername: String,
        myDisplayName: String,
        mySelfNames: Set<String>
    ) {
        let (recaller, recalledOwner) = recallerName(from: recall.text)
        guard !recaller.isEmpty else { return }
        // "你撤回了一条消息" — my own recall.
        let recallerIsSelf = recaller == "你"
            || (!myUsername.isEmpty && recaller == myUsername)
            || (!myDisplayName.isEmpty && recaller == myDisplayName)
            || mySelfNames.contains(recaller)
        // "X 撤回了 Y 的一条消息" — an admin recalled member Y's message:
        // the original row belongs to Y, not to the actor X. Attribution
        // follows the owner so the record doesn't pin Y's content on X.
        let owner = recalledOwner ?? recaller
        let ownerIsSelf = recalledOwner.map {
            $0 == "你" || (!myUsername.isEmpty && $0 == myUsername)
                || (!myDisplayName.isEmpty && $0 == myDisplayName)
                || mySelfNames.contains($0)
        } ?? recallerIsSelf
        // The original row is the message owner's newest message at-or-
        // before the recall time (within a 10-minute horizon).
        let window = candidates.filter {
            $0.id != recall.id
                && $0.sysKind == nil
                && $0.createTime <= recall.createTime
                && $0.createTime >= recall.createTime - 600
        }
        // WeChat names the owner with a display name, and two members of one
        // group can carry the same one. Claiming the newest same-named row
        // would then tombstone the OTHER member's message — a live commitment
        // cancelled and a pending ask deleted, which the scan watermark never
        // redoes. Ambiguous name: record the recall, cascade nothing.
        // Claimants are counted over the whole fetched page, not just the
        // 10-minute match band: the other 张伟 being quiet for an hour is not
        // evidence that the one in the window is his.
        let ownerClaimants = Set(candidates.compactMap { row in
            row.sysKind == nil && row.senderName == owner && !row.senderUsername.isEmpty
                ? row.senderUsername : nil
        })
        let ownerNameIsAmbiguous = !ownerIsSelf && ownerClaimants.count >= 2
        if ownerNameIsAmbiguous {
            print("[WCHUD] recall cascade skipped: name claimed by \(ownerClaimants.count) senders")
        }
        let original = ownerNameIsAmbiguous ? nil : window.first(where: {
            ownerIsSelf
                ? MessageHelpers.isFromSelf($0, chatUsername: chatUsername,
                                            myUsername: myUsername,
                                            myDisplayName: myDisplayName,
                                            mySelfNames: mySelfNames)
                : ($0.senderName == owner || $0.senderUsername == owner)
        })
        let senderUsername = original?.senderUsername ?? owner
        let contact = contactMap[senderUsername]
        // The original's derived artifacts die with it — a withdrawn
        // commitment must not keep nagging, a recalled ask must not anchor.
        if let originalID = original?.id {
            do {
                try store.tombstoneForRecall(originalMsgUID: originalID)
            } catch {
                // The recall row is still worth recording — the user must see
                // that something was withdrawn — but a half-applied cascade
                // has to leave a trace instead of passing as success.
                print("[WCHUD] recall tombstone failed for \(originalID): \(error)")
            }
        }
        do {
            try store.insertRecalledMessage(
                msgUID: recall.id,
                senderUsername: senderUsername,
                senderName: original?.senderName ?? owner,
                senderLevel: contact?.attentionLevel ?? .stranger,
                senderRole: contact?.role ?? .acquaintance,
                chatUsername: chatUsername,
                chatName: recall.chatName,
                chatType: MessageHelpers.isMultiPartyChat(chatUsername) ? .group : .privateChat,
                originalText: original?.text ?? "",
                sentAt: original?.createTime ?? recall.createTime,
                recalledAt: recall.createTime
            )
        } catch {
            // A failed recall insert must not stall the scan — the row is
            // re-admitted on the next scan until the watermark passes it.
            print("[WCHUD] recall record failed; will retry on next scan")
        }
    }

    /// Extract the actor name from a recall replacemsg payload. WeChat
    /// formats: `"X" 撤回了一条消息`, `「X」撤回了一条消息`,
    /// `X 撤回了 Y 的一条消息` (an admin recalled member Y's message — the
    /// owner is Y, which is what attribution must follow).
    /// Returns (actor, recalledMessageOwner?).
    static func recallerName(from text: String) -> (actor: String, owner: String?) {
        guard let r = text.range(of: "撤回") else { return ("", nil) }
        var name = String(text[..<r.lowerBound])
        name = name.trimmingCharacters(
            in: CharacterSet(charactersIn: " \t\"“”‘’「」『』")
        )
        // Owner: text between "撤回了" and "的一条消息" — present only in the
        // admin-recall form `X 撤回了"Y"的一条消息` (sometimes 成员"Y"). The
        // self-recall form `撤回了一条消息` has no 的 and no owner — a bare-"的"
        // fallback here misread `一条消息` itself as a name.
        var owner: String? = nil
        if let ofRange = text.range(of: "撤回了"),
           let ownerEnd = text.range(of: "的一条消息", range: ofRange.upperBound..<text.endIndex) {
            var mid = String(text[ofRange.upperBound..<ownerEnd.lowerBound])
            mid = mid.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t\"“”‘’「」『』")
            )
            if mid.hasPrefix("成员") {
                mid = String(mid.dropFirst(2)).trimmingCharacters(
                    in: CharacterSet(charactersIn: " \t\"“”‘’「」『』")
                )
            }
            if !mid.isEmpty { owner = mid }
        }
        return (name, owner)
    }

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
        guard MessageHelpers.isMultiPartyChat(entryID) else { return false }
        guard entryLevel != .vip else { return false }
        return vipPersonUsernames.contains(senderUsername)
    }

    /// Strip leading sender name from snippet to avoid "亮🌸: 亮🌸让你..." duplication.
    /// Internal (not private) so the mention-boundary rules are testable.
    static func deduplicateSenderInSnippet(
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
            // U+2005 (FOUR-PER-EM SPACE) is the terminator WeChat actually
            // emits after a group mention — the old separator set missed it,
            // so "@我 hello" kept its token on the banner.
            guard let space = snippet.firstIndex(where: {
                $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "　" || $0 == "\u{2005}"
            }) else { break }
            let token = String(snippet[snippet.index(after: snippet.startIndex)..<space])
            let isMe = token == "所有人" || token.lowercased() == "all"
                || token == myUsername || (!myDisplayName.isEmpty && token == myDisplayName)
                || mySelfNames.contains(token)
            guard isMe else { break }
            snippet = String(snippet[snippet.index(after: space)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !senderName.isEmpty else { return snippet }
        // Check if text starts with "senderName" followed by a separator.
        // An empty separator would strip "张三…" from a body that merely
        // starts with the sender's name, not their prefix.
        for sep in ["：", ":", " "] {
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
        let replyDebtBatch = (try? reader.getMessagesBatch(
            targetSessions.map {
                WeChatReader.MessageBatchRequest(chatUsername: $0.username, limit: 30)
            }
        )) ?? [:]

        let seeds: [ReplyDebtScorer.Seed] = targetSessions.compactMap { session in
            let recentMsgs = replyDebtBatch[session.username] ?? []
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
