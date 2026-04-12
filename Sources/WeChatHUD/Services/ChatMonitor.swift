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
    /// Autopilot state — exposed for UI.
    @Published var autopilotActive = false
    @Published var autopilotPaused = false
    @Published var autopilotLog: [AutopilotLogEntry] = []
    @Published var autopilotSessionSent = 0
    @Published var autopilotSessionPending = 0
    /// The autopilot service instance. Initialized lazily on first toggle.
    private(set) var autopilotService: AutopilotService?
    private let recentLimit = 10

    private let reader: WeChatReader
    private let store: HUDStore
    private let aiService: AIService?
    private let groupContextBriefingService: GroupContextBriefingService
    private let aiGroupCatchup: AIGroupCatchup
    private let contextAnalyzer: ContextAnalyzer
    private lazy var aiClassifier: AIClassifier = {
        AIClassifier(store: store, config: store.loadClassifierConfig())
    }()
    private lazy var commitmentTracker: CommitmentTracker = {
        CommitmentTracker(store: store)
    }()
    private lazy var vipAggregator: VIPAggregator = {
        VIPAggregator(store: store)
    }()
    private lazy var recallAnalyzer: RecallAnalyzer = {
        RecallAnalyzer(store: store)
    }()
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
    private var activateObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?

    nonisolated static let urgentKeywords = ["紧急", "尽快", "ASAP", "马上", "立即", "截止", "deadline"]

    /// Timeout thresholds. Hardcoded for now — will lift into settings
    /// once the UI is wired.
    private let thresholds = UnreadThresholds()

    /// True if the message text mentions the user via @-syntax. Matches
    /// `@<myUsername>`, `@所有人`, `@All` (case-insensitive on "All").
    /// Static so `performScan` can call it from the background queue.
    // Static helpers (isAtMe, isFromSelf, unreadStatus, senderIdentifier,
    // isIgnoredSender, resolveDeadline) extracted to MessageHelpers.swift.

    // ScanOutcome, performScan, buildReplyDebtItems, debugScanAllTables
    // extracted to ScanEngine.swift.
    private typealias ScanOutcome = ScanEngine.ScanOutcome

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
        let center = NSWorkspace.shared.notificationCenter
        if let obs = launchObserver { center.removeObserver(obs) }
        if let obs = terminateObserver { center.removeObserver(obs) }
        if let obs = activateObserver { center.removeObserver(obs) }
        if let obs = deactivateObserver { center.removeObserver(obs) }
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
                && MessageHelpers.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
        }
        unreadItems.removeAll {
            $0.chatUsername == chatUsername
                && MessageHelpers.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
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
                && MessageHelpers.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
                && !$0.isIgnored
        }
        recentNotifications.removeAll {
            $0.chatUsername == chatUsername
                && MessageHelpers.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName) == identifier
        }
        if let latestNotification,
           latestNotification.chatUsername == chatUsername,
           MessageHelpers.senderIdentifier(
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
                && MessageHelpers.senderIdentifier(senderUsername: $0.senderUsername, senderName: $0.senderName)
                    == MessageHelpers.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
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

    // senderIdentifier and isIgnoredSender extracted to MessageHelpers.swift.

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

        // Autopilot auto-pause: detect when user switches to WeChat
        activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in
                guard let self = self, self.autopilotActive else { return }
                await self.autopilotService?.onUserBecameActive()
                self.autopilotPaused = true
                print("[WCHUD] Autopilot: user activated WeChat — pausing")
            }
        }
        deactivateObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in
                guard let self = self, self.autopilotActive else { return }
                await self.autopilotService?.onUserBecameInactive()
                self.autopilotPaused = false
                print("[WCHUD] Autopilot: user left WeChat — resuming")
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
            return await ScanEngine.performScan(
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
        runPostScanAI(o)

        // --- Autopilot: feed messages + flush expired batches ---
        // Always call handleNewMessages when active (even with empty array)
        // so that buffered batches whose time window expired get flushed.
        if autopilotActive, let service = autopilotService {
            let msgs = o.newInboundMessages
            let config = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
            let myUname = reader.myUsername()
            Task {
                let result = await service.handleNewMessages(msgs, config: config, myUsername: myUname)
                await MainActor.run {
                    self.autopilotSessionSent += result.totalSent
                    self.autopilotSessionPending += result.totalPending
                    if let session = self.store.currentAutopilotSession() {
                        self.autopilotLog = self.store.loadAutopilotLog(sessionId: session.id, limit: 50)
                    }
                }
                if result.totalProcessed > 0 {
                    print("[WCHUD] Autopilot: processed=\(result.totalProcessed), sent=\(result.totalSent), pending=\(result.totalPending)")
                }
                // C1 fix: if there are still buffered batches, schedule a
                // follow-up scan after the batch window so they get flushed.
                let hasPending = await service.hasPendingBatches
                if hasPending {
                    let delay = TimeInterval(config.batchWindowSeconds) + 1
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await MainActor.run { [weak self] in
                        Task { await self?.scan() }
                    }
                }
            }
        }
    }

    /// Reload commitments and recalled messages from store.
    func reloadAIData() {
        commitments = store.loadCommitments()
        recalledMessages = store.loadRecalledMessages(limit: 50)
    }

    /// Fire-and-forget AI processing for new scan data.
    /// Runs after scan applies, does not block UI.
    private func runPostScanAI(_ outcome: ScanOutcome) {
        let storeRef = store

        // 1. Insert VIP traces to DB
        for trace in outcome.vipTraceMessages {
            try? storeRef.insertVIPTrace(
                vipUsername: trace.vipUsername,
                vipName: trace.vipName,
                chatUsername: trace.chatUsername,
                chatName: trace.chatName,
                msgUID: trace.msgUID,
                rawText: trace.rawText,
                msgTime: trace.msgTime
            )
        }

        // 2. VIP aggregation (async)
        if !outcome.vipTraceMessages.isEmpty {
            let vipUsernames = Set(outcome.vipTraceMessages.map(\.vipUsername))
            let aggregator = vipAggregator
            Task {
                for vipUsername in vipUsernames {
                    let contact = storeRef.getContact(username: vipUsername)
                    let role = contact?.role ?? .acquaintance
                    let vipName = contact?.displayName ?? vipUsername
                    if let result = await aggregator.aggregate(
                        vipUsername: vipUsername,
                        vipName: vipName,
                        vipRole: role,
                        userNameVariants: [],
                        recentMoodHistory: "",
                        lastInteraction: "",
                        commitmentCount: 0
                    ) {
                        await MainActor.run {
                            self.vipInsights[vipUsername] = result
                        }
                    }
                }
            }
        }

        // 3. AI classify new inbound messages (async)
        if !outcome.newInboundForClassifier.isEmpty {
            let classifier = aiClassifier
            Task {
                for item in outcome.newInboundForClassifier {
                    let input = ClassifierInput(
                        msgUID: item.msg.id,
                        text: item.msg.text,
                        senderName: item.msg.senderName,
                        chatName: item.msg.chatName,
                        isGroup: item.chatUsername.contains("@chatroom")
                    )
                    guard let result = await classifier.classify(message: input) else { continue }
                    guard result.isAsk else { continue }

                    let contact = storeRef.getContact(username: item.msg.senderUsername)
                    let bucket: AskBucket = result.confidence >= 0.85 ? .main : .review
                    let deadline: Date? = result.deadlineRelative.flatMap { MessageHelpers.resolveDeadline($0) }

                    let ask = PendingAsk(
                        id: 0,
                        msgUID: item.msg.id,
                        chatUsername: item.chatUsername,
                        chatName: item.msg.chatName,
                        senderName: item.msg.senderName,
                        rawText: item.msg.text,
                        summary: result.summary,
                        askType: result.type,
                        deadlineAt: deadline,
                        confidence: result.confidence,
                        bucket: bucket,
                        status: .pending,
                        promptVersion: result.promptVersion,
                        createdAt: Date(),
                        updatedAt: Date(),
                        senderLevel: contact?.attentionLevel,
                        senderRole: contact?.role,
                        urgency: nil
                    )
                    try? storeRef.upsertPendingAsk(ask)
                }
            }
        }

        // 4. Commitment tracking for self outgoing messages (async)
        if !outcome.selfOutgoingMessages.isEmpty {
            let tracker = commitmentTracker
            let readerRef = reader
            Task {
                for item in outcome.selfOutgoingMessages {
                    let contact = storeRef.getContact(username: item.chatUsername)
                    let role = contact?.role ?? .acquaintance

                    // Build minimal context
                    let contextMsgs = (try? readerRef.getMessages(chatUsername: item.chatUsername, limit: 10)) ?? []
                    let contactLookup: ContextWindowBuilder.ContactLookup = { username in
                        guard let c = storeRef.getContact(username: username) else { return nil }
                        return (c.attentionLevel, c.role)
                    }
                    let window = ContextWindowBuilder.build(
                        target: item.msg,
                        role: .commitmentTracker,
                        allMessages: contextMsgs,
                        chatType: item.chatUsername.contains("@chatroom") ? .group : .privateChat,
                        contactLookup: contactLookup
                    )

                    guard let result = await tracker.analyze(
                        yourMessage: item.msg,
                        contextMessages: window.messages,
                        recipientName: item.recipientName,
                        recipientRole: role
                    ) else { continue }

                    guard result.isCommitment, result.confidence >= 0.7 else { continue }

                    let deadline = MessageHelpers.resolveDeadline(result.deadlineExtracted)
                    try? storeRef.upsertCommitment(
                        msgUID: item.msg.id,
                        chatUsername: item.chatUsername,
                        chatName: item.chatName,
                        content: result.content,
                        commitTo: result.commitTo,
                        deadlineAt: deadline,
                        confidence: result.confidence,
                        promptVersion: "commitment_v1"
                    )
                }
                // Refresh published commitments after processing
                await MainActor.run {
                    self.commitments = storeRef.loadCommitments()
                }
            }
        }

        // 5. Analyze unanalyzed recalled messages (async)
        let unanalyzed = recalledMessages.filter { $0.aiReason == nil }
        if !unanalyzed.isEmpty {
            let analyzer = recallAnalyzer
            let readerRef = reader
            Task {
                for recalled in unanalyzed {
                    let context = (try? readerRef.getMessages(chatUsername: recalled.chatUsername, limit: 10)) ?? []
                    guard let result = await analyzer.analyze(recalled: recalled, context: context) else { continue }
                    try? storeRef.updateRecallAnalysis(
                        msgUID: recalled.msgUID,
                        reason: result.reason,
                        value: result.intelligenceValue,
                        detail: result.detail ?? "",
                        shouldNotify: result.shouldNotify,
                        notifyLevel: result.notifyLevel ?? .none
                    )
                }
                // Refresh recalled messages after analysis
                await MainActor.run {
                    self.recalledMessages = storeRef.loadRecalledMessages(limit: 50)
                }
            }
        }
    }

    /// Resolve a relative deadline string like "+30m", "+2h", "+1d" to a Date.
    // resolveDeadline extracted to MessageHelpers.swift.

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

    // MARK: - Autopilot

    /// Toggle autopilot mode on/off.
    func toggleAutopilot() {
        if autopilotActive {
            stopAutopilot()
        } else {
            startAutopilot()
        }
    }

    func startAutopilot() {
        if autopilotService == nil {
            let config = store.loadClassifierConfig()
            autopilotService = AutopilotService(store: store, reader: reader, config: config)
        }
        let service = autopilotService
        Task {
            do {
                try await service?.start()
                await MainActor.run {
                    self.autopilotActive = true
                    self.autopilotSessionSent = 0
                    self.autopilotSessionPending = 0
                    self.autopilotLog = []
                }
                print("[WCHUD] Autopilot: ON")
            } catch {
                print("[WCHUD] Autopilot: failed to start: \(error)")
            }
        }
    }

    func stopAutopilot() {
        let service = autopilotService
        Task {
            do {
                try await service?.stop()
            } catch {
                print("[WCHUD] Autopilot: failed to stop cleanly: \(error)")
            }
        }
        autopilotActive = false
        print("[WCHUD] Autopilot: OFF")
    }

    /// Approve a pending autopilot item and send it.
    func approveAutopilotItem(logId: Int64, reply: String, chatName: String, chatUsername: String) async -> Bool {
        guard let service = autopilotService else { return false }
        let success = await service.approvePending(logId: logId, reply: reply, chatName: chatName, chatUsername: chatUsername)
        // I1 fix: refresh counters from DB session instead of manual adjustment
        refreshAutopilotSessionState()
        return success
    }

    /// Reject a pending autopilot item.
    func rejectAutopilotItem(logId: Int64) {
        Task {
            await autopilotService?.rejectPending(logId: logId)
        }
        refreshAutopilotSessionState()
    }

    /// Refresh autopilot UI state from the DB (source of truth for counters).
    private func refreshAutopilotSessionState() {
        if let session = store.currentAutopilotSession() {
            autopilotLog = store.loadAutopilotLog(sessionId: session.id, limit: 50)
            autopilotSessionSent = session.totalSent
            autopilotSessionPending = session.totalPending
        }
    }

    // performScan, buildReplyDebtItems, debugScanAllTables extracted to ScanEngine.swift.
}

