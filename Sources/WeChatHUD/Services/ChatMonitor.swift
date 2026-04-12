import Foundation
import AppKit
import SQLite3

/// Millisecond-precision timestamp for log tracing.
private let _tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
private func ts() -> String {
    _tsFormatter.string(from: Date())
}

/// Event-driven WeChat message monitor.
///
/// Primary trigger: FSEventsWatcher feeds paths into `onFSEvent` whenever
/// a `.db` or `.db-wal` file under WeChat's `db_storage` changes.
/// Secondary trigger: a 60s safety timer that runs `refreshIfChanged` on
/// every tracked DB. If nothing has moved, the safety scan is a handful of
/// `stat` calls and returns in microseconds.
///
/// Gating: the whole monitor is paused while WeChat isn't running. Launch
/// and terminate events from NSWorkspace flip the gate instantly, so the
/// status dot turns red the moment WeChat quits.
@MainActor
final class ChatMonitor: ObservableObject {
    @Published var stats = HUDStats()
    @Published var latestNotification: HUDNotification?
    /// Rolling window of the most recent tracked-source messages — one
    /// entry per distinct chat, newest first, capped at 10. Drives the
    /// follow feed shown on hover.
    @Published var recentNotifications: [HUDNotification] = []
    /// All currently-unread items across the address book, derived from
    /// `session.db`. Cleared automatically when WeChat marks a chat read.
    @Published var unreadItems: [UnreadItem] = []
    /// Items that the user has silenced or snoozed via the HUD. Kept in
    /// a separate list so the "已处理" sub-tab can show them and offer
    /// a 恢复 action. Filled both by scan (re-applying persisted state)
    /// and by the mutation methods below.
    @Published var suppressedItems: [UnreadItem] = []
    /// Cross-chat reply debt ledger derived from recent sessions plus
    /// message windows. Independent from WeChat unread state.
    @Published var replyDebtItems: [ReplyDebtItem] = []
    /// On-demand AI context briefings for group @ mentions. Shared
    /// between the notification banner and the follow-feed rows.
    @Published var groupContextStates: [String: GroupContextBriefingLoadState] = [:]
    /// Commitments extracted from user's outgoing messages.
    @Published var commitments: [Commitment] = []
    /// Recalled messages with AI analysis.
    @Published var recalledMessages: [RecalledMessage] = []
    /// VIP aggregate insights keyed by vip username.
    @Published var vipInsights: [String: VIPAggregator.AggregateResult] = [:]
    /// AI-suggested whitelist additions keyed by chat username.
    @Published var whitelistSuggestions: [String: AIWhitelistCategorizer.Suggestion] = [:]
    /// Cached daily retrospective, regenerated every 30 minutes.
    @Published var dailyReport: AIDailyRetrospector.Retrospective? = nil
    @Published var dailyReportGeneratedAt: Date? = nil
    private let recentLimit = 10

    private let reader: WeChatReader
    private let store: HUDStore
    private let aiService: AIService?
    private let groupContextBriefingService: GroupContextBriefingService
    private let aiGroupCatchup: AIGroupCatchup
    private let contextAnalyzer: ContextAnalyzer
    private lazy var replySuggester: AIReplySuggester = {
        AIReplySuggester(store: store, config: store.loadClassifierConfig())
    }()
    private lazy var dailyRetrospector: AIDailyRetrospector = {
        AIDailyRetrospector(store: store, config: store.loadClassifierConfig())
    }()
    private var safetyTimer: Timer?
    private var scanInProgress = false

    /// Coalesced FSEvent debouncer.
    ///
    /// FSEvents fires per-file, so a single WeChat write burst can
    /// produce ~10 events in 50 ms. Running the whole scan synchronously
    /// for each one is what caused the "pill feels stuck + dot turns
    /// yellow repeatedly" UX problem. Instead, we accumulate every
    /// delivered `changedRelPaths` set into this buffer and schedule a
    /// single scan `debounceInterval` later. Any event arriving before
    /// the timer fires extends the window (cancels + reschedules).
    private var pendingChangedPaths: Set<String> = []
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.25

    nonisolated private static let wechatBundleIDs: Set<String> = [
        "com.tencent.xinWeChat",
        "com.tencent.WeChat"
    ]

    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    nonisolated static let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]

    /// Timeout thresholds. Hardcoded for now — will lift into settings
    /// once the UI is wired.
    private let thresholds = UnreadThresholds()

    /// True if the message text mentions the user via @-syntax. Matches
    /// `@<myUsername>`, `@所有人`, `@All` (case-insensitive on "All").
    /// Static so `performScan` can call it from the background queue.
    nonisolated private static func isAtMe(_ text: String, myUsername: String) -> Bool {
        if !myUsername.isEmpty, text.contains("@\(myUsername)") { return true }
        if text.contains("@所有人") { return true }
        if text.range(of: "@all", options: .caseInsensitive) != nil { return true }
        return false
    }

    /// Classify whether a message is from the user themselves.
    nonisolated private static func isFromSelf(
        _ msg: MessageInfo,
        chatUsername: String,
        myUsername: String
    ) -> Bool {
        // Primary check: match against the known wxid from db_storage path.
        if !myUsername.isEmpty && msg.senderUsername == myUsername { return true }
        // 1-on-1 fallback: for private chats, if the sender field is
        // populated and doesn't match the peer, it must be self. Only
        // apply when senderUsername is non-empty — empty sender means
        // WeChat didn't populate the field (common for older messages),
        // and we can't assume it's self.
        if !chatUsername.contains("@chatroom") && !msg.senderUsername.isEmpty {
            if msg.senderUsername != chatUsername && msg.senderUsername != msg.chatUsername {
                return true
            }
        }
        return false
    }

    /// Derive the unread status from raw signals.
    nonisolated private static func unreadStatus(
        replied: Bool,
        timestamp: Date,
        isVIP: Bool,
        thresholds: UnreadThresholds
    ) -> UnreadStatus {
        if replied { return .answered }
        let minutes = isVIP ? thresholds.vipMinutes : thresholds.normalMinutes
        let age = Date().timeIntervalSince(timestamp) / 60
        return age >= Double(minutes) ? .overdue : .pending
    }

    /// Result struct returned from the background scan worker.
    /// Collects everything the `@Published` fields need so the main
    /// thread can apply the whole update atomically.
    private struct ScanOutcome {
        let stats: HUDStats
        let unreadItems: [UnreadItem]
        let suppressedItems: [UnreadItem]
        let replyDebtItems: [ReplyDebtItem]
        let recentNotifications: [HUDNotification]
        let latestPreview: HUDNotification?
    }

    init(reader: WeChatReader, store: HUDStore, aiService: AIService? = nil) {
        self.reader = reader
        self.store = store
        self.aiService = aiService
        self.groupContextBriefingService = GroupContextBriefingService(
            reader: reader,
            store: store,
            client: aiService
        )
        let classifierConfig = store.loadClassifierConfig()
        self.aiGroupCatchup = AIGroupCatchup(store: store, config: classifierConfig)
        self.contextAnalyzer = ContextAnalyzer(store: store)
    }

    deinit {
        if let obs = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
    }

    // MARK: - Lifecycle

    func start() {
        print("[WCHUD] monitor.start()")
        stop()
        registerWeChatObservers()
        print("[WCHUD] wechat running at startup? \(isWeChatRunning())")

        // Initial scan — either red (no WeChat) or green (scanned clean).
        Task { @MainActor in
            print("[WCHUD] initial scan Task starting")
            await self.scan()
        }

        // Safety fallback: cheap mtime-only check every 60s.
        // If FSEvents delivers in time, this is a no-op.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.scan() }
        }
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingChangedPaths.removeAll()
    }

    func refreshNow() {
        Task { @MainActor in
            await self.scan()
        }
    }

    func groupContextState(for notification: HUDNotification) -> GroupContextBriefingLoadState {
        groupContextStates[notification.briefingKey] ?? .idle
    }

    func loadGroupContextBriefing(
        for notification: HUDNotification,
        forceRefresh: Bool = false
    ) {
        guard notification.canExplainContext else { return }
        let key = notification.briefingKey
        if !forceRefresh,
           let existing = groupContextStates[key],
           existing.isLoading || existing.briefing != nil {
            return
        }

        let existing = groupContextStates[key]
        groupContextStates[key] = GroupContextBriefingLoadState(
            briefing: existing?.briefing,
            isLoading: true,
            errorMessage: nil,
            updatedAt: existing?.updatedAt
        )

        let service = groupContextBriefingService
        let catchup = aiGroupCatchup
        let analyzer = contextAnalyzer
        let readerRef = reader
        let myUname = reader.myUsername()
        Task { [weak self] in
            let result = await service.explain(
                notification: notification,
                forceRefresh: forceRefresh
            )
            await MainActor.run {
                guard let self else { return }
                self.groupContextStates[key] = GroupContextBriefingLoadState(
                    briefing: result.briefing,
                    isLoading: false,
                    errorMessage: result.errorMessage,
                    updatedAt: Date()
                )
                self.trimGroupContextStateIfNeeded()
            }

            // --- Phase 2: AIGroupCatchup + ContextAnalyzer (fire-and-forget, non-blocking) ---
            // Load recent messages for the chat once; reuse for both downstream services.
            let contextMessages = (try? readerRef.getMessages(
                chatUsername: notification.chatUsername,
                limit: 30,
                sinceLocalId: nil
            )) ?? []

            // AIGroupCatchup: enrich briefing with headline / highlights.
            let catchupInput = AIGroupCatchup.Input(
                chatName: notification.chatName,
                selfName: myUname,
                messages: contextMessages.map { ($0.senderName, $0.text) }
            )
            if let summary = await catchup.summarize(catchupInput) {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard var state = self.groupContextStates[key],
                          var briefing = state.briefing else { return }
                    // Only fill deep fields if not already present.
                    if briefing.deepBackground == nil {
                        briefing.deepBackground = summary.headline
                    }
                    if briefing.deepWhatTheyWant == nil, !summary.highlights.isEmpty {
                        briefing.deepWhatTheyWant = summary.highlights.joined(separator: " · ")
                    }
                    state.briefing = briefing
                    self.groupContextStates[key] = state
                }
            }

            // ContextAnalyzer: fill deep* fields using a synthetic PendingAsk.
            let syntheticAsk = PendingAsk(
                id: 0,
                msgUID: "\(notification.chatUsername):\(notification.messageID)",
                chatUsername: notification.chatUsername,
                chatName: notification.chatName,
                senderName: notification.senderName,
                rawText: notification.rawText,
                summary: notification.snippet,
                askType: .none,
                deadlineAt: nil,
                confidence: result.briefing.confidence,
                bucket: .main,
                status: .pending,
                promptVersion: "context_analyzer_v1",
                createdAt: notification.timestamp,
                updatedAt: notification.timestamp,
                senderLevel: nil,
                senderRole: nil,
                urgency: nil
            )
            let annotated = contextMessages.map { msg in
                AnnotatedMessage(
                    id: msg.id,
                    senderUsername: msg.senderUsername,
                    senderName: msg.senderName,
                    senderLevel: nil,
                    senderRole: nil,
                    text: msg.text,
                    createTime: msg.createTime,
                    isTarget: msg.id == notification.messageID
                )
            }
            let chatType: ChatType = notification.chatUsername.contains("@chatroom") ? .group : .privateChat
            let contextWindow = ContextWindow(
                messages: annotated,
                chatType: chatType,
                role: .contextAnalyzer
            )
            // Look up actual sender role from contacts; fall back to .colleague if unknown.
            let senderRole: ContactRole = store.getContact(username: notification.senderUsername)?.role ?? .colleague
            if let deepResult = await analyzer.analyze(
                ask: syntheticAsk,
                senderRole: senderRole,
                conversationContext: contextWindow,
                senderProfile: "",
                userCommitments: ""
            ) {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard var state = self.groupContextStates[key],
                          var briefing = state.briefing else { return }
                    briefing.deepBackground = briefing.deepBackground ?? deepResult.background
                    briefing.deepWhatTheyWant = briefing.deepWhatTheyWant ?? deepResult.whatTheyWant
                    briefing.deepHiddenContext = deepResult.hiddenContext
                    briefing.deepStakeholders = deepResult.stakeholderMap.map { "\($0.name): \($0.stance)" }
                    briefing.deepYourPosition = deepResult.yourPosition
                    briefing.deepSuggestedAction = deepResult.suggestedAction
                    briefing.deepSuggestedTiming = deepResult.suggestedTiming
                    briefing.deepRiskIfIgnore = deepResult.riskIfIgnore
                    state.briefing = briefing
                    self.groupContextStates[key] = state
                }
            }
        }
    }

    // `myUsername` is derived on demand from `reader.myUsername()` now,
    // which parses it out of the db_storage path. The store-backed
    // setting was never actually populated so this became a no-op anyway.

    // MARK: - User actions on unread items

    /// Mark a chat as "I've seen it, stop bugging me". Moves matching
    /// items from `unreadItems` into `suppressedItems` so the user can
    /// still find them via the 已处理 tab. Strictly newer messages in
    /// the same chat will re-appear on the next scan.
    func silenceChat(_ chatUsername: String) {
        // Silence watermark = max timestamp of currently-visible items
        // for this chat. Strictly newer messages slip past.
        let currentMax = unreadItems
            .filter { $0.chatUsername == chatUsername }
            .map { Int($0.timestamp.timeIntervalSince1970) }
            .max() ?? Int(Date().timeIntervalSince1970)
        try? store.silenceChat(chatUsername: chatUsername, silencedAt: currentMax)
        moveToSuppressed(chatUsername: chatUsername)
    }

    /// Snooze an entire chat until an absolute unix timestamp. Items
    /// move to `suppressedItems`; when the snooze expires the next scan
    /// will repopulate them into `unreadItems`.
    func snoozeChat(_ chatUsername: String, until: Int) {
        try? store.snoozeChat(chatUsername: chatUsername, until: until)
        moveToSuppressed(chatUsername: chatUsername)
    }

    /// Convenience: snooze for N minutes from now.
    func snoozeChat(_ chatUsername: String, minutes: Int) {
        let until = Int(Date().timeIntervalSince1970) + minutes * 60
        snoozeChat(chatUsername, until: until)
    }

    func ignoreSender(
        chatUsername: String,
        chatName: String,
        senderUsername: String,
        senderName: String
    ) {
        try? store.ignoreSender(
            chatUsername: chatUsername,
            chatName: chatName,
            senderUsername: senderUsername,
            senderName: senderName
        )

        let identifier = HUDStore.senderIdentifier(
            senderUsername: senderUsername,
            senderName: senderName
        )
        let moved = unreadItems.filter {
            $0.chatUsername == chatUsername
                && Self.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
        }
        unreadItems.removeAll {
            $0.chatUsername == chatUsername
                && Self.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
        }
        if !moved.isEmpty {
            suppressedItems.insert(
                contentsOf: moved.map {
                    UnreadItem(
                        chatUsername: $0.chatUsername,
                        chatName: $0.chatName,
                        senderUsername: $0.senderUsername,
                        senderName: $0.senderName,
                        preview: $0.preview,
                        timestamp: $0.timestamp,
                        kind: $0.kind,
                        isWhitelisted: $0.isWhitelisted,
                        isVIP: $0.isVIP,
                        replied: $0.replied,
                        status: $0.status,
                        isIgnored: true
                    )
                },
                at: 0
            )
        }
        suppressedItems.removeAll {
            $0.chatUsername == chatUsername
                && Self.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
                && !$0.isIgnored
        }
        recentNotifications.removeAll {
            $0.chatUsername == chatUsername
                && Self.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
        }
        if let latestNotification,
           latestNotification.chatUsername == chatUsername,
           Self.senderIdentifier(
                senderUsername: latestNotification.senderUsername,
                senderName: latestNotification.senderName
           ) == identifier {
            self.latestNotification = nil
        }
        recomputeStatsFromItems()
        Task { @MainActor in
            await self.scan()
        }
    }

    func unignoreSender(
        chatUsername: String,
        senderUsername: String,
        senderName: String
    ) {
        try? store.unignoreSender(
            chatUsername: chatUsername,
            senderUsername: senderUsername,
            senderName: senderName
        )
        suppressedItems.removeAll {
            $0.isIgnored
                && $0.chatUsername == chatUsername
                && Self.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName)
                    == Self.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
        }
        Task { @MainActor in
            await self.scan()
        }
    }

    func isSenderIgnored(
        chatUsername: String,
        senderUsername: String,
        senderName: String
    ) -> Bool {
        store.isSenderIgnored(
            chatUsername: chatUsername,
            senderUsername: senderUsername,
            senderName: senderName
        )
    }

    /// Restore a suppressed chat's items back into `unreadItems`. Used
    /// by the 恢复显示 context action on rows inside the 已处理 tab.
    func clearChatAction(_ chatUsername: String) {
        try? store.clearChatAction(chatUsername: chatUsername)
        let restored = suppressedItems.filter {
            $0.chatUsername == chatUsername && !$0.isIgnored
        }
        guard !restored.isEmpty else { return }
        suppressedItems.removeAll {
            $0.chatUsername == chatUsername && !$0.isIgnored
        }
        unreadItems.append(contentsOf: restored)
        unreadItems.sort { a, b in
            func rank(_ s: UnreadStatus) -> Int {
                switch s {
                case .overdue:  return 0
                case .pending:  return 1
                case .answered: return 2
                }
            }
            let ra = rank(a.status), rb = rank(b.status)
            if ra != rb { return ra < rb }
            return a.timestamp > b.timestamp
        }
        recomputeStatsFromItems()
        Task { @MainActor in
            await self.scan()
        }
    }

    /// Shared helper: move every unreadItem for a chat into suppressed.
    private func moveToSuppressed(chatUsername: String) {
        let moved = unreadItems.filter { $0.chatUsername == chatUsername }
        unreadItems.removeAll { $0.chatUsername == chatUsername }
        if !moved.isEmpty {
            suppressedItems.insert(contentsOf: moved, at: 0)
        }
        replyDebtItems.removeAll { $0.chatUsername == chatUsername }
        recomputeStatsFromItems()
    }

    func acceptWhitelistSuggestion(chatUsername: String, suggestion: AIWhitelistCategorizer.Suggestion) {
        let category: WhitelistCategory = suggestion.category == "work" ? .work : suggestion.category == "life" ? .life : .other
        let attentionLevel: WhitelistAttentionLevel = suggestion.isGroup ? .watch : .watch
        let displayName = reader.displayName(for: chatUsername)
        try? store.addToWhitelist(
            username: chatUsername,
            displayName: displayName.isEmpty ? chatUsername : displayName,
            isGroup: suggestion.isGroup,
            category: category,
            attentionLevel: attentionLevel
        )
        whitelistSuggestions.removeValue(forKey: chatUsername)
    }

    func dismissWhitelistSuggestion(chatUsername: String) {
        whitelistSuggestions.removeValue(forKey: chatUsername)
    }

    /// Add an unread item's chat into the tracked source list. Private
    /// chats default to VIP; groups default to plain whitelist/watch.
    func addUnreadToWhitelist(_ item: UnreadItem) {
        let isGroup = item.chatUsername.contains("@chatroom")
        try? store.addToWhitelist(
            username: item.chatUsername,
            displayName: item.chatName,
            isGroup: isGroup,
            category: isGroup ? .work : .life,
            attentionLevel: isGroup ? .watch : .vip
        )
    }

    func updateWhitelistAttention(
        username: String,
        displayName: String,
        isGroup: Bool,
        fallbackCategory: WhitelistCategory,
        attentionLevel: WhitelistAttentionLevel
    ) {
        let existing = store.getWhitelistEntry(username: username)
        try? store.addToWhitelist(
            username: username,
            displayName: existing?.displayName ?? displayName,
            isGroup: existing?.isGroup ?? isGroup,
            category: existing?.category ?? fallbackCategory,
            attentionLevel: attentionLevel
        )
        Task { @MainActor in
            await self.scan()
        }
    }

    private func trimGroupContextStateIfNeeded(maxEntries: Int = 32) {
        guard groupContextStates.count > maxEntries else { return }
        let retainedKeys = Set(
            groupContextStates
                .sorted { lhs, rhs in
                    let lts = lhs.value.updatedAt ?? .distantPast
                    let rts = rhs.value.updatedAt ?? .distantPast
                    return lts > rts
                }
                .prefix(maxEntries)
                .map(\.key)
        )
        groupContextStates = groupContextStates.filter { retainedKeys.contains($0.key) }
    }

    /// Re-derive `stats.unreadCount` / `atMentionCount` from the
    /// currently-visible `unreadItems` — used after local mutations
    /// (silence, snooze) so the compact pill reflects the new count
    /// without waiting for the next full scan.
    private func recomputeStatsFromItems() {
        let pr = unreadItems.filter { $0.kind == .privateChat }.count
        let at = unreadItems.filter { $0.kind == .groupAt }.count
        stats.unreadCount = pr + at
        stats.atMentionCount = at
        stats.vipCount = recentNotifications.filter(\.isVIP).count
        stats.replyDebtCount = replyDebtItems.count
    }

    nonisolated private static func senderIdentifier(
        senderUsername: String,
        senderName: String
    ) -> String {
        HUDStore.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
    }

    nonisolated private static func isIgnoredSender(
        _ msg: MessageInfo,
        ignoredSenderMap: [String: Set<String>]
    ) -> Bool {
        let identifier = senderIdentifier(
            senderUsername: msg.senderUsername,
            senderName: msg.senderName
        )
        return ignoredSenderMap[msg.chatUsername]?.contains(identifier) == true
    }

    // MARK: - Event entry points

    /// Called by FSEventsWatcher when files in db_storage change.
    /// Accumulates the changed rel paths and schedules a single
    /// coalesced scan `debounceInterval` later; successive events
    /// arriving during the window extend it.
    func onFSEvent(paths: [String]) {
        var delta: Set<String> = []
        for path in paths {
            guard let rel = extractRelPath(from: path) else { continue }
            guard rel.contains("/message_")
                || rel.contains("/contact.db")
                || rel.contains("/session") else { continue }
            delta.insert(rel)
        }
        guard !delta.isEmpty else { return }

        pendingChangedPaths.formUnion(delta)
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let batch = self.pendingChangedPaths
            self.pendingChangedPaths.removeAll(keepingCapacity: false)
            self.debounceWorkItem = nil
            let eventTime = Date()
            print("[\(ts())] FSEvent batch (\(batch.count) files): \(batch.sorted().joined(separator: ", "))")
            Task { @MainActor in
                await self.scan(changedRelPaths: batch)
                let latencyMs = Int(Date().timeIntervalSince(eventTime) * 1000)
                print("[\(ts())] FSEvent → scan complete (+\(latencyMs)ms)")
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Map an absolute path (e.g. `/.../db_storage/message/message_1.db-wal`)
    /// to the repo-relative form used as the key in `keys` and `sync_state`
    /// (e.g. `message/message_1.db`). Returns nil for paths outside db_storage.
    private func extractRelPath(from absPath: String) -> String? {
        let dbDir = reader.dbDir
        guard !dbDir.isEmpty, absPath.hasPrefix(dbDir) else { return nil }
        var rel = String(absPath.dropFirst(dbDir.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        // Strip WAL / SHM / journal suffixes to get the main DB path.
        if rel.hasSuffix("-wal") { rel = String(rel.dropLast(4)) }
        else if rel.hasSuffix("-shm") { rel = String(rel.dropLast(4)) }
        else if rel.hasSuffix("-journal") { rel = String(rel.dropLast(8)) }
        return rel.isEmpty ? nil : rel
    }

    // MARK: - WeChat process detection

    private func isWeChatRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return Self.wechatBundleIDs.contains(bid)
        }
    }

    private func registerWeChatObservers() {
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in await self?.scan() }
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.stats = HUDStats(
                    unreadCount: 0,
                    atMentionCount: 0,
                    vipCount: 0,
                    syncStatus: .waitingForWeChat,
                    lastSyncAt: self.stats.lastSyncAt
                )
            }
        }
    }

    // MARK: - Scan

    /// Main-thread wrapper: preflight → dispatch heavy work to a
    /// background task → apply the returned `ScanOutcome` on main.
    /// All the sqlite / decryption / message-parsing work runs off
    /// the main actor so the pill stays smooth even while scanning.
    ///
    /// - Parameter changedRelPaths: If non-nil, only DBs matching these
    ///   relative paths are refreshed and scanned. The 60s safety timer
    ///   passes nil to do a full sweep.
    private func scan(changedRelPaths: Set<String>? = nil) async {
        guard !scanInProgress else {
            print("[WCHUD] scan skipped — already in progress")
            return
        }
        scanInProgress = true
        defer { scanInProgress = false }

        // Gate: WeChat must be running.
        guard isWeChatRunning() else {
            print("[WCHUD] scan gated — WeChat not running")
            stats = HUDStats(
                unreadCount: 0,
                atMentionCount: 0,
                vipCount: 0,
                syncStatus: .waitingForWeChat,
                lastSyncAt: stats.lastSyncAt
            )
            return
        }

        let scanStart = Date()
        stats.syncStatus = .syncing

        // Capture everything the background worker needs by value (or
        // by reference for the heavyweight objects reader/store). The
        // classes are ObservableObjects but not MainActor-isolated —
        // their methods can run on any thread. We rely on `scanInProgress`
        // + sqlite's FULLMUTEX to serialise access.
        let readerRef = reader
        nonisolated(unsafe) let storeRef = store
        let cp = changedRelPaths
        let th = thresholds
        let currentRecent = recentNotifications
        let rLimit = recentLimit
        let replyDebtConfig = store.getSettingJSON("replyDebt", as: ReplyDebtConfig.self) ?? ReplyDebtConfig()
        let replyDebtAIConfig = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self) ?? ReplyDebtAIConfig()
        let aiRef = aiService

        let outcome = await Task.detached(priority: .userInitiated) {
            return await ChatMonitor.performScan(
                reader: readerRef,
                store: storeRef,
                aiService: aiRef,
                changedRelPaths: cp,
                thresholds: th,
                replyDebtConfig: replyDebtConfig,
                replyDebtAIConfig: replyDebtAIConfig,
                currentRecent: currentRecent,
                recentLimit: rLimit
            )
        }.value

        let ms = Int(Date().timeIntervalSince(scanStart) * 1000)

        guard let o = outcome else {
            print("[WCHUD] scan failed after \(ms)ms")
            stats.syncStatus = .error("scan failed")
            return
        }

        print("[WCHUD] scan: unread=\(o.stats.unreadCount) (@=\(o.stats.atMentionCount)), \(ms)ms")

        // One batched apply — all @Published mutations land together so
        // SwiftUI only does a single render pass.
        stats = o.stats
        unreadItems = o.unreadItems
        suppressedItems = o.suppressedItems
        replyDebtItems = o.replyDebtItems
        recentNotifications = o.recentNotifications
        if let latest = o.latestPreview {
            latestNotification = latest
        }
        reader.purgeEphemeralCache()
        reloadAIData()
    }

    /// Reload commitments and recalled messages from store.
    func reloadAIData() {
        commitments = store.loadCommitments()
        recalledMessages = store.loadRecalledMessages(limit: 50)
    }

    /// Load or refresh daily report. Only calls AI if stale (>30 min).
    func loadDailyReport(force: Bool = false) async {
        if !force, let gen = dailyReportGeneratedAt,
           Date().timeIntervalSince(gen) < 1800,
           dailyReport != nil {
            return
        }
        let pending = store.loadPendingAsks(status: .pending)
        let handled = store.loadPendingAsks(status: .done)
        let input = AIDailyRetrospector.Input(
            date: {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: Date())
            }(),
            handled: handled,
            pending: pending,
            messageCount: stats.unreadCount,
            focusDurationMinutes: 0
        )
        dailyReport = await dailyRetrospector.retrospect(input)
        dailyReportGeneratedAt = Date()
    }

    /// Load recent messages for a chat as (sender, body) tuples — used by
    /// WhitelistScanView to give the AI categorizer real content.
    func recentMessages(chatUsername: String, limit: Int = 20) -> [(sender: String, body: String)] {
        (try? reader.getMessages(chatUsername: chatUsername, limit: limit, sinceLocalId: nil))?
            .map { (sender: $0.senderName, body: $0.text) } ?? []
    }

    /// Generate reply suggestions for a reply debt item.
    func loadReplySuggestions(for item: ReplyDebtItem) async -> [AIReplySuggester.Suggestion] {
        let input = AIReplySuggester.Input(
            messageBody: item.preview,
            senderName: item.senderName,
            chatName: item.chatName,
            isGroup: item.isGroup,
            askType: .none,
            relationship: "work"
        )
        return await replySuggester.suggest(input) ?? []
    }

    /// Background-safe scan body. Pure function over `reader`, `store`,
    /// and a snapshot of the current @Published state — no access to
    /// `self` allowed.
    nonisolated private static func performScan(
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

            let sessions = (try? reader.getSessions()) ?? []
            let myUname = reader.myUsername()
            let whitelist = store.getWhitelist()
            let whitelistSet = Set(whitelist.map { $0.id })
            let vipSet = Set(whitelist.filter { $0.attentionLevel == .vip }.map { $0.id })
            var replyDebtItems = buildReplyDebtItems(
                sessions: sessions,
                reader: reader,
                chatActions: chatActions,
                ignoredSenderMap: ignoredSenderMap,
                myUsername: myUname,
                whitelistSet: whitelistSet,
                vipSet: vipSet,
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
                    .filter { isFromSelf($0, chatUsername: session.username, myUsername: myUname) }
                    .map { $0.createTime }
                    .max() ?? 0

                let isWhitelisted = whitelistSet.contains(session.username)
                let isVIP = vipSet.contains(session.username)
                let silencedAt = chatActions[session.username]?.silencedAt ?? 0

                func makeItem(_ msg: MessageInfo, kind: HUDNotificationKind) -> UnreadItem {
                    let ts = Date(timeIntervalSince1970: Double(msg.createTime))
                    let replied = latestSelfTime > msg.createTime
                    let isIgnored = isIgnoredSender(msg, ignoredSenderMap: ignoredSenderMap)
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
                        status: unreadStatus(
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
                        !isFromSelf($0, chatUsername: session.username, myUsername: myUname)
                    }) else { continue }
                    let item = makeItem(msg, kind: .privateChat)
                    if item.isIgnored || isSnoozed || msg.createTime <= silencedAt {
                        suppressedCollected.append(item)
                    } else {
                        privateUnreadChats += 1
                        unreadCollected.append(item)
                    }
                } else {
                    for msg in recentMsgs where isAtMe(msg.text, myUsername: myUname) {
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
                    latestPreview: nil
                )
            }

            // ---- Whitelist scan (for the follow feed & VIP alerts) ----
            var latestPreview: HUDNotification?
            var perChatLatest: [String: HUDNotification] = [:]

            let msgDBs = reader.findMessageDBs()
            for relPath in msgDBs {
                _ = try? reader.refreshIfChanged(relPath: relPath)
            }

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
                    // Skip own messages — don't surface them as VIP/whitelist notifications.
                    if isFromSelf(msg, chatUsername: entry.id, myUsername: myUname) {
                        continue
                    }
                    if isIgnoredSender(msg, ignoredSenderMap: ignoredSenderMap) {
                        continue
                    }
                    let isAt = isAtMe(msg.text, myUsername: myUname)
                    let kind: HUDNotificationKind
                    if !msg.chatUsername.contains("@chatroom") {
                        kind = .privateChat
                    } else if isAt {
                        kind = .groupAt
                    } else {
                        kind = .groupMessage
                    }

                    let msgTime = Date(timeIntervalSince1970: Double(msg.createTime))
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
                latestPreview: latestPreview
            )
        } catch {
            print("[WCHUD] performScan error: \(error)")
            return nil
        }
    }

    nonisolated private static func buildReplyDebtItems(
        sessions: [SessionInfo],
        reader: WeChatReader,
        chatActions: [String: HUDStore.ChatActionState],
        ignoredSenderMap: [String: Set<String>],
        myUsername: String,
        whitelistSet: Set<String>,
        vipSet: Set<String>,
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
                !isFromSelf($0, chatUsername: session.username, myUsername: myUsername)
                    && !isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
            }
            guard let inbound = latestInbound else { return nil }

            let latestOutbound = recentMsgs.first {
                isFromSelf($0, chatUsername: session.username, myUsername: myUsername)
            }
            let inboundCountSinceLastOutbound: Int
            if let outbound = latestOutbound {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !isFromSelf($0, chatUsername: session.username, myUsername: myUsername)
                        && !isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
                        && $0.createTime > outbound.createTime
                }.count
            } else {
                inboundCountSinceLastOutbound = recentMsgs.filter {
                    !isFromSelf($0, chatUsername: session.username, myUsername: myUsername)
                        && !isIgnoredSender($0, ignoredSenderMap: ignoredSenderMap)
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
                isAtMention: isAtMe(inbound.text, myUsername: myUsername),
                chatAction: chatActions[session.username],
                now: now
            )
        }

        return ReplyDebtScorer.build(seeds: seeds, config: config)
    }

    // MARK: - Debug whole-DB scan

    /// Iterate Msg_* tables in the target message DBs, count new rows since
    /// last known local_id. First sighting of a table establishes a baseline
    /// (doesn't count the historical backlog as "new").
    ///
    /// Hot-path optimization: WeChat's Msg_* tables all use
    /// `local_id INTEGER PRIMARY KEY AUTOINCREMENT`, so SQLite maintains a
    /// current sequence value per table in `sqlite_sequence`. A single
    /// `SELECT name, seq FROM sqlite_sequence` per DB gives us every
    /// table's max_id — no need for ~100 per-table COUNT/MAX queries. With
    /// AUTOINCREMENT the "new messages since last scan" count is exactly
    /// `new_max - last_seen_max` (there are no deletions on the hot path).
    nonisolated private static func debugScanAllTables(
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
