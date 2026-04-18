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
    @Published var autopilotManuallyPaused = false
    @Published var autopilotLog: [AutopilotLogEntry] = []
    @Published var autopilotSessionSent = 0
    @Published var autopilotSessionPending = 0
    @Published var autopilotPendingSendQueue: [PendingSend] = []
    @Published var autopilotSessionStats = AutopilotService.SessionStats()
    @Published var inboxItems: [InboxItem] = []
    /// Published handled items for the UI (dismissed/snoozed/silenced).
    @Published var handledItems: [InboxItem] = []
    /// All currently silenced inbox items (for management UI).
    var silencedItems: [InboxItem] {
        handledItems.filter { $0.status == .silenced }
    }
    /// Chat insight analysis results keyed by chatUsername.
    @Published var chatInsights: [String: ChatInsightResult] = [:]
    /// Global briefing across all whitelisted chats.
    @Published var globalBriefing: GlobalBriefing? = nil
    /// True while insight analysis is running.
    @Published var insightLoading: Bool = false
    /// Insight progress: "正在分析 3/12..."
    @Published var insightProgress: String = ""
    /// Insight progress fraction 0-1
    @Published var insightProgressFraction: Double = 0
    /// Tracks dismissed inbox items: chatUsername → timestamp at time of dismiss.
    private var dismissedInbox: [String: Int64] = [:]
    /// Tracks snoozed inbox items: chatUsername → snooze expiry date.
    private var snoozedInbox: [String: Date] = [:]
    /// Tracks silenced (permanently muted) chats.
    private var silencedInbox: Set<String> = []
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
        AIClassifier(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    private lazy var commitmentTracker: CommitmentTracker = {
        CommitmentTracker(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    private lazy var discussionTracker: DiscussionTracker = {
        DiscussionTracker(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    @Published var discussionItems: [DiscussionItem] = []
    private lazy var vipAggregator: VIPAggregator = {
        VIPAggregator(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    private lazy var recallAnalyzer: RecallAnalyzer = {
        RecallAnalyzer(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    private lazy var replySuggester: AIReplySuggester = {
        AIReplySuggester(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    private lazy var styleProfiler: StyleProfiler = {
        StyleProfiler(reader: reader, store: store)
    }()
    private lazy var alertEngine: ProactiveAlertEngine = {
        let engine = ProactiveAlertEngine(store: store)
        // Bridge engine state → published property so SwiftUI views
        // observing ChatMonitor re-render when a VIP escalates.
        engine.onTiersChanged = { [weak self] tiers in
            self?.vipAlertTiers = tiers
        }
        // A tier advance (e.g. T3: "已等 2 小时") also pops an in-panel
        // toast so the user sees it even if they dismissed the OS
        // notification.
        engine.onTierAdvanced = { [weak self] chatName, tier in
            guard tier >= .t3 else { return }
            self?.pendingEscalationBanner = (chatName, tier)
        }
        return engine
    }()

    /// Per-chat VIP alert tier. Published so AppDelegate can update
    /// the menu bar badge and CompactInboxBar can add a pulse effect
    /// without needing to traverse into the alert engine directly.
    @Published private(set) var vipAlertTiers: [String: VIPAlertTier] = [:]

    /// Set by the alert engine when a VIP advances to T3+; AppDelegate
    /// observes and turns it into a one-shot toast. Tuple form so we
    /// can include both the chat name and the aging label.
    @Published var pendingEscalationBanner: (chatName: String, tier: VIPAlertTier)?
    private lazy var dailyRetrospector: AIDailyRetrospector = {
        AIDailyRetrospector(store: store, config: store.loadAIConfig())
    }()
    private lazy var briefingGenerator: AIBriefingGenerator = {
        AIBriefingGenerator(store: store, config: store.loadAIConfig())
    }()
    private lazy var chatAnalyzer: ChatAnalyzer = {
        ChatAnalyzer(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
    }()
    private lazy var relationshipInferrer: RelationshipInferrer = {
        RelationshipInferrer(store: store, config: store.loadAIConfig())
    }()
    private lazy var inboxSummarizer: AIInboxSummarizer = {
        AIInboxSummarizer(store: store, config: store.loadAIConfig())
    }()
    private lazy var chatInsightService: AIChatInsight = {
        AIChatInsight(store: store, config: store.loadAIConfig())
    }()
    /// Cache: chatUsername + msgTimestamp → AI summary string
    private var summaryCache: [String: String] = [:]

    /// Pre-generated expand-panel data — analysis + reply suggestions
    /// fired in the background right after scan, so when the user
    /// clicks an inbox row the action panel reads from cache and
    /// renders instantly instead of spinning on "正在整理重点…".
    /// Keyed by chatUsername; `timestamp` binds each entry to a
    /// specific message so stale cache from a prior message gets
    /// rejected when a newer one arrives.
    struct PrefetchedAction {
        let timestamp: Int
        let groupAnalysis: ChatAnalyzer.GroupAnalysis?
        let privateAnalysis: ChatAnalyzer.PrivateAnalysis?
        let replies: [SuggestedReply]
        let hasProfile: Bool
        /// True once the analysis task has run to completion — lets
        /// the UI tell "still waiting for prefetch" from "prefetch
        /// finished with no result" (API error / timeout). Without
        /// this flag, a silent API failure leaves the panel spinning
        /// forever on "AI 正在整理重点…".
        let analysisAttempted: Bool
        /// True once the replies task has run to completion.
        let repliesAttempted: Bool
    }
    @Published private(set) var actionPrefetch: [String: PrefetchedAction] = [:]

    private var safetyTimer: Timer?
    private var safetyTickCount = 0
    private var scanInProgress = false

    /// Set when an FSEvent or timer tick requests a scan while one is
    /// already running. The in-flight scan checks this on exit and
    /// re-triggers itself with the accumulated request — so we never
    /// silently drop the FSEvent batch that was meant to trigger the
    /// new scan. Without this, messages written during a long-running
    /// scan wouldn't surface until the next FSEvent or the 10 s safety
    /// tick, producing a visible notification lag.
    private var rescanRequested = false
    /// If true, the pending rescan must be a full scan (changedRelPaths
    /// = nil). A queued full-scan overrides any incremental paths.
    private var rescanRequestedFull = false
    /// Incremental paths accumulated while a scan was in progress.
    /// Merged into the rescan trigger on scan exit. Ignored when
    /// `rescanRequestedFull` is true.
    private var rescanRequestedPaths: Set<String> = []

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
    private let debounceInterval: TimeInterval = 0.5

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
        let classifierConfig = store.loadAIConfig()
        self.aiGroupCatchup = AIGroupCatchup(store: store, config: classifierConfig)
        self.contextAnalyzer = ContextAnalyzer(store: store, aiService: aiService ?? AIService(config: classifierConfig))
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

        // Hydrate in-memory action state from persistent store. Without
        // this, a user who silenced/snoozed/dismissed yesterday would
        // see those chats re-appear in their inbox after a restart —
        // everything was ephemeral in an earlier design.
        hydrateInboxActionsFromStore()

        // Initial scan — either red (no WeChat) or green (scanned clean).
        Task { @MainActor in
            print("[WCHUD] initial scan Task starting")
            await self.scan()
        }

        // Safety fallback: cheap mtime-only check at configurable interval.
        // If FSEvents delivers in time, this is a no-op.
        let syncCfg = store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        let scanEveryNTicks = max(1, syncCfg.intervalSeconds / 10)
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                // Process pending send queue every 10s (fast enough for UI countdown accuracy)
                let config = self.store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
                await self.autopilotService?.processPendingQueue(config: config)
                // Sync queue and stats to UI
                if let svc = self.autopilotService {
                    let queue = await svc.pendingSendQueue
                    let stats = await svc.sessionStats
                    let manPaused = await svc.manuallyPaused
                    await MainActor.run {
                        self.autopilotPendingSendQueue = queue
                        self.autopilotSessionStats = stats
                        self.autopilotManuallyPaused = manPaused
                    }
                }

                // Full scan every Nth tick (interval from sync settings)
                self.safetyTickCount += 1
                if self.safetyTickCount % scanEveryNTicks == 0 {
                    await self.scan()
                }
                // Proactive outreach every 60th tick (~10 min)
                if self.safetyTickCount % 60 == 0 {
                    await self.autopilotService?.evaluateProactiveOutreach(config: config)
                }
            }
        }
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingChangedPaths.removeAll()
        rescanRequested = false
        rescanRequestedFull = false
        rescanRequestedPaths.removeAll()
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
        let storeRef = store
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
            let senderRole: ContactRole = storeRef.getContact(username: notification.senderUsername)?.role ?? .colleague
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

        // Autopilot no longer pauses when WeChat is frontmost —
        // as long as autopilot is on, it keeps replying.
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
        // If a scan is already running, don't drop this request — queue
        // it so we re-scan when the current run exits. Otherwise any
        // FSEvent batch that arrives during a long-running scan (AI
        // post-scan work, big catch-up, etc.) would vanish and messages
        // would surface only on the next 10s safety tick.
        guard !scanInProgress else {
            rescanRequested = true
            if changedRelPaths == nil {
                // nil means full scan — upgrade any pending incremental
                // request to a full scan, since full ⊇ incremental.
                rescanRequestedFull = true
                rescanRequestedPaths.removeAll()
            } else if !rescanRequestedFull, let paths = changedRelPaths {
                rescanRequestedPaths.formUnion(paths)
            }
            print("[WCHUD] scan queued (already in progress, paths=\(changedRelPaths?.count.description ?? "full"))")
            return
        }
        scanInProgress = true
        defer {
            scanInProgress = false
            // Drain any request that arrived during this scan. We
            // launch the follow-up in a detached Task so the current
            // scan's `defer` can finish cleanly; by the time it runs,
            // scanInProgress is already false.
            if rescanRequested {
                let wantsFull = rescanRequestedFull
                let queued: Set<String>? = wantsFull ? nil : rescanRequestedPaths
                rescanRequested = false
                rescanRequestedFull = false
                rescanRequestedPaths.removeAll()
                Task { @MainActor [weak self] in
                    await self?.scan(changedRelPaths: queued)
                }
            }
        }

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

        // Gate: user logged into a different WeChat account since we
        // started. Our `dbDir` is immutable, so every subsequent read
        // would hit stale DBs for the wrong account. Stop here and
        // surface the condition so the UI can prompt a restart.
        if reader.hasAccountSwitched() {
            print("[WCHUD] scan gated — WeChat account switched (was \(reader.myUsername()), now \(reader.detectCurrentAccountWxid() ?? "?"))")
            stats = HUDStats(
                unreadCount: 0,
                atMentionCount: 0,
                vipCount: 0,
                syncStatus: .accountSwitched,
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
        let aiRef = aiService

        let outcome = await Task.detached(priority: .userInitiated) {
            return await ScanEngine.performScan(
                reader: readerRef,
                store: storeRef,
                aiService: aiRef,
                changedRelPaths: cp,
                thresholds: th,
                replyDebtConfig: replyDebtConfig,
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

        let scanType = changedRelPaths == nil ? "full" : "incremental(\(changedRelPaths!.count) files)"
        print("[WCHUD] scan[\(scanType)]: unread=\(o.stats.unreadCount) @=\(o.stats.atMentionCount) debt=\(o.stats.replyDebtCount) vip=\(o.stats.vipCount), \(ms)ms")

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
        // Build unified inbox from scan results
        rebuildInbox()
        reader.purgeEphemeralCache()
        reloadAIData()
        runPostScanAI(o)

        // Generate AI summaries for new inbox items (async, progressive)
        generateSummaries()

        // Pre-generate expand-panel data (chat analysis + reply
        // suggestions) so clicking into an inbox row surfaces the
        // AI output instantly instead of making the user wait for
        // two round-trips. Fires in the background, updates
        // `actionPrefetch` progressively.
        prefetchActionPanelData()

        // Proactive alerts — evaluate rules after state update
        alertEngine.evaluate(
            unreadItems: unreadItems,
            replyDebtItems: replyDebtItems,
            commitments: commitments,
            recentNotifications: recentNotifications
        )

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
                    await self.scan()
                }
            }
        }
    }

    /// Reload commitments and recalled messages from store.
    func reloadAIData() {
        commitments = store.loadCommitments()
        recalledMessages = store.loadRecalledMessages(limit: 50)
        discussionItems = store.loadDiscussionItems(limit: 200)
    }

    /// Update a discussion item's status (done / dismissed / archived).
    /// UI calls this from the 工作台 tab — reloads the published list
    /// so the row vanishes from the active view immediately.
    func updateDiscussionItemStatus(id: Int64, status: DiscussionItemStatus) {
        try? store.updateDiscussionItemStatus(id: id, status: status)
        discussionItems = store.loadDiscussionItems(limit: 200)
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

        // 6. Conversation memory — incremental summary update for whitelist chats
        let memoryAI = aiService
        let memoryReader = reader
        Task {
            guard let ai = memoryAI, await ai.isConfigured() else { return }
            let whitelist = storeRef.getWhitelist()
                for entry in whitelist.prefix(5) {  // limit to top 5 to control AI cost
                    // Rate limit: skip if updated < 30 min ago
                    if let existing = storeRef.loadConversationMemory(chatUsername: entry.id),
                       Date().timeIntervalSince(existing.lastUpdated) < 1800 {
                        continue
                    }

                    let messages = (try? memoryReader.getMessages(chatUsername: entry.id, limit: 30)) ?? []
                    guard !messages.isEmpty else { continue }

                    let oldMemory = storeRef.loadConversationMemory(chatUsername: entry.id)
                    let oldSummary = oldMemory?.summary ?? ""

                    let msgText = messages.prefix(20).map {
                        "\($0.senderName): \($0.text)"
                    }.joined(separator: "\n")

                    let oldShared = oldMemory?.sharedContext ?? []
                    let oldComm = oldMemory?.communicationNotes ?? []

                    let prompt = """
                    你是对话摘要助手。根据最近消息增量更新对话记忆。保留旧记忆中仍然相关的内容，合并新内容。

                    对话: \(entry.displayName)
                    旧摘要: \(oldSummary.isEmpty ? "（首次生成）" : oldSummary)
                    旧共同背景: \(oldShared.isEmpty ? "（无）" : oldShared.joined(separator: "、"))
                    旧沟通习惯: \(oldComm.isEmpty ? "（无）" : oldComm.joined(separator: "、"))

                    最近消息:
                    \(msgText)

                    请用 JSON 格式输出（每个数组最多5项）:
                    {"summary":"一句话摘要(50字内)","key_topics":["最近话题1","话题2"],"pending_items":["待办1"],"shared_context":["共同经历/关系背景"],"communication_notes":["沟通习惯"],"mood_trend":"情绪描述","conversation_phase":"闲聊/讨论/决策/争论/告别/无","stance":"用户当前立场(如有)"}
                    """

                    guard let response = try? await ai.complete(system: "你是对话摘要助手。只输出JSON。", user: prompt) else { continue }
                    guard let data = response.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    let memory = ConversationMemory(
                        chatUsername: entry.id,
                        summary: json["summary"] as? String ?? oldSummary,
                        keyTopics: Array((json["key_topics"] as? [String] ?? oldMemory?.keyTopics ?? []).prefix(10)),
                        pendingItems: Array((json["pending_items"] as? [String] ?? oldMemory?.pendingItems ?? []).prefix(5)),
                        sharedContext: Array((json["shared_context"] as? [String] ?? oldShared).prefix(5)),
                        communicationNotes: Array((json["communication_notes"] as? [String] ?? oldComm).prefix(5)),
                        moodTrend: json["mood_trend"] as? String ?? oldMemory?.moodTrend ?? "",
                        conversationPhase: json["conversation_phase"] as? String ?? oldMemory?.conversationPhase ?? "",
                        stance: json["stance"] as? String ?? oldMemory?.stance ?? "",
                        messageCount7d: messages.count,
                        lastUpdated: Date()
                    )
                    try? storeRef.upsertConversationMemory(memory)
                }
        }

        // 7. ReplyDebt AI re-ranking removed — rule scoring + time sort is sufficient

        // 8. Auto-brief new group @mentions. The briefing service already
        // caches + dedupes (loadGroupContextBriefing no-ops if it's
        // loading or cached), so we can just fire it for every current
        // @mention in `recentNotifications` and trust the service to
        // skip repeats. Cap to the 5 most recent so a big catch-up
        // doesn't trigger a burst of AI calls all at once.
        let briefables = outcome.recentNotifications
            .filter { $0.canExplainContext }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(5)
        for notif in briefables {
            loadGroupContextBriefing(for: notif)
        }

        // 9. DiscussionTracker — bidirectional item extraction.
        //
        // Unlike CommitmentTracker (which only looks at OUR outgoing
        // promises), this reads both sides of the conversation and
        // pulls out todos/decisions/info/time-place/questions — a
        // memory layer the user asked for: "我跟别人聊了可能忘了
        // 的事情，抽出来做备忘". The weekly report slices these by
        // hierarchy (上级派给我 / 我派给下级).
        //
        // Cost control: only chats with *new* inbound or outbound
        // messages this scan get analyzed; the tracker itself also
        // watermarks per chat so re-scans skip unchanged windows.
        let activeChats = Set(
            outcome.newInboundForClassifier.map(\.chatUsername)
        ).union(outcome.selfOutgoingMessages.map(\.chatUsername))
        if !activeChats.isEmpty, let ai = aiService {
            let tracker = discussionTracker
            let readerRef = reader
            let myUname = reader.myUsername()
            let myDisplay = reader.displayName(for: myUname)
            let selfNames = reader.mySelfNames
            Task { @MainActor [weak self] in
                guard await ai.isConfigured() else { return }
                for chatUsername in activeChats.prefix(5) {
                    let messages = (try? readerRef.getMessages(
                        chatUsername: chatUsername, limit: 40, sinceLocalId: nil
                    )) ?? []
                    guard !messages.isEmpty else { continue }
                    let chatName = readerRef.displayName(for: chatUsername)
                    let inserted = await tracker.extract(
                        chatUsername: chatUsername,
                        chatName: chatName,
                        messages: messages,
                        myUsername: myUname,
                        myDisplayName: myDisplay,
                        mySelfNames: selfNames
                    )
                    if inserted > 0 {
                        print("[WCHUD] DiscussionTracker: \(chatName) +\(inserted) items")
                    }
                }
                // Refresh published list after batch.
                guard let self = self else { return }
                self.discussionItems = self.store.loadDiscussionItems(limit: 200)
            }
        }

        // 10. Commitment fulfillment closure.
        //
        // For each pending commitment, look at what the user sent
        // subsequently in the same chat. If there's a "已发 / 搞定 /
        // 完成" keyword or a file/image/link in a commitment that
        // talks about deliverables → auto-mark fulfilled. If the
        // deadline has passed with no evidence → auto-mark overdue.
        //
        // `autoAdvanceCommitmentStatus` only flips .pending rows —
        // user-cancelled / user-completed rows are untouched.
        let pendingCommitments = commitments.filter { $0.status == .pending }
        if !pendingCommitments.isEmpty {
            let readerForFulfillment = reader
            let storeForFulfillment = store
            Task { @MainActor [weak self] in
                var changed = false
                for c in pendingCommitments {
                    // Fetch recent messages in that chat, filter to
                    // the user's own outbound messages AFTER the
                    // commitment was created.
                    guard let allMsgs = try? readerForFulfillment.getMessages(
                        chatUsername: c.chatUsername, limit: 50, sinceLocalId: nil
                    ) else { continue }
                    let commitEpoch = Int(c.createdAt.timeIntervalSince1970)
                    let subsequent = allMsgs.filter { msg in
                        msg.createTime > commitEpoch &&
                        MessageHelpers.isFromSelf(
                            msg, chatUsername: c.chatUsername,
                            myUsername: readerForFulfillment.myUsername(),
                            myDisplayName: readerForFulfillment.displayName(for: readerForFulfillment.myUsername()),
                            mySelfNames: readerForFulfillment.mySelfNames
                        )
                    }
                    let signal = CommitmentTracker.evaluateFulfillment(
                        commitment: c,
                        subsequentSelfMessages: subsequent
                    )
                    switch signal {
                    case .fulfilled(let reason):
                        try? storeForFulfillment.autoAdvanceCommitmentStatus(
                            msgUID: c.msgUID, to: .fulfilled
                        )
                        print("[WCHUD] Commitment fulfilled: \(c.content) — \(reason)")
                        changed = true
                    case .overdue:
                        try? storeForFulfillment.autoAdvanceCommitmentStatus(
                            msgUID: c.msgUID, to: .overdue
                        )
                        changed = true
                    case .stillPending:
                        break
                    }
                }
                if changed, let self = self {
                    self.commitments = storeForFulfillment.loadCommitments()
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

    /// Load chat insight analysis for all whitelisted chats.
    /// Analyze a single chat on-demand (triggered by user clicking into a chat).
    func analyzeOneChat(chatUsername: String) async {
        guard chatInsights[chatUsername] == nil else { return }  // already analyzed
        insightLoading = true
        insightProgress = "正在分析..."

        guard let entry = store.getWhitelist().first(where: { $0.id == chatUsername }) else {
            insightLoading = false
            return
        }

        let selfUsername = reader.myUsername()
        let selfDisplayName = reader.displayName(for: selfUsername)

        guard let result = await analyzeEntry(entry, selfUsername: selfUsername, selfDisplayName: selfDisplayName) else {
            insightLoading = false
            insightProgress = ""
            return
        }

        chatInsights[chatUsername] = result
        insightLoading = false
        insightProgress = ""
    }

    /// Full insight load with progress reporting.
    func loadInsight(force: Bool = false) async {
        guard !insightLoading else { return }
        if !force, let briefing = globalBriefing {
            let age = Date().timeIntervalSince(
                ISO8601DateFormatter().date(from: briefing.date) ?? .distantPast
            )
            if age < 1800 { return }
        }

        insightLoading = true
        insightProgress = "正在准备..."
        insightProgressFraction = 0

        let whitelist = store.getWhitelist()
        let selfUsername = reader.myUsername()
        let selfDisplayName = reader.displayName(for: selfUsername)
        let dateStr = ISO8601DateFormatter().string(from: Date())

        // Filter to chats with today's messages
        let todayStart = Calendar.current.startOfDay(for: Date())
        var activeEntries: [WhitelistEntry] = []
        for entry in whitelist {
            guard let messages = try? reader.getMessages(chatUsername: entry.id, limit: 50) else { continue }
            let hasToday = messages.contains { Date(timeIntervalSince1970: Double($0.createTime)) >= todayStart }
            if hasToday { activeEntries.append(entry) }
        }

        let total = activeEntries.count
        var results: [String: ChatInsightResult] = [:]
        var statsResults: [ChatStatsData] = []

        for (i, entry) in activeEntries.enumerated() {
            insightProgress = "正在分析 \(i + 1)/\(total) \(entry.displayName)..."
            insightProgressFraction = Double(i) / Double(max(total, 1))

            if let result = await analyzeEntry(entry, selfUsername: selfUsername, selfDisplayName: selfDisplayName) {
                results[entry.id] = result
            }

            // Also compute stats
            if let messages = try? reader.getMessages(chatUsername: entry.id, limit: 200) {
                let todayMessages = messages.filter { Date(timeIntervalSince1970: Double($0.createTime)) >= todayStart }
                if !todayMessages.isEmpty {
                    let stats = ChatInsightEngine.computeStats(
                        messages: todayMessages, selfUsername: selfUsername,
                        selfDisplayName: selfDisplayName, selfNames: reader.mySelfNames,
                        chatUsername: entry.id, chatName: entry.displayName,
                        isGroup: entry.isGroup, category: entry.category
                    )
                    statsResults.append(stats)
                }
            }
        }

        insightProgress = "正在生成全局简报..."
        insightProgressFraction = 0.95

        // Global briefing
        let totalMessages = statsResults.reduce(0) { $0 + $1.messageCount }
        let myMessages = statsResults.reduce(0) { $0 + $1.myMessageCount }
        let activeGroups = statsResults.filter { $0.isGroup }.count
        let totalGroups = whitelist.filter { $0.isGroup }.count
        let activePrivate = statsResults.filter { !$0.isGroup }.count
        let workMsgs = statsResults.filter { $0.category == .work }.reduce(0) { $0 + $1.messageCount }
        let workRatio = totalMessages > 0 ? Double(workMsgs) / Double(totalMessages) : 0

        let globalStats = BriefingStats(
            totalMessages: totalMessages, myMessages: myMessages,
            activeGroups: activeGroups, totalGroups: totalGroups,
            activePrivateChats: activePrivate, workRatio: workRatio
        )

        let insightPairs = results.compactMap { (key, value) -> (chatName: String, result: ChatInsightResult)? in
            guard let e = whitelist.first(where: { $0.id == key }) else { return nil }
            return (chatName: e.displayName, result: value)
        }

        let briefing = await chatInsightService.generateGlobalBriefing(
            selfName: selfDisplayName, date: dateStr,
            chatInsights: insightPairs, globalStats: globalStats
        )

        chatInsights = results
        globalBriefing = briefing
        insightLoading = false
        insightProgress = ""
        insightProgressFraction = 1.0
    }

    /// Analyze a single whitelist entry — shared by analyzeOneChat and loadInsight.
    private func analyzeEntry(
        _ entry: WhitelistEntry,
        selfUsername: String,
        selfDisplayName: String
    ) async -> ChatInsightResult? {
        let todayStart = Calendar.current.startOfDay(for: Date())
        guard let messages = try? reader.getMessages(chatUsername: entry.id, limit: 200) else { return nil }
        let todayMessages = messages.filter { Date(timeIntervalSince1970: Double($0.createTime)) >= todayStart }
        guard !todayMessages.isEmpty else { return nil }

        let formatted = todayMessages
            .sorted { $0.createTime < $1.createTime }
            .map { (sender: $0.senderName, body: $0.text, time: $0.createTime) }

        let recalled = recalledMessages
            .filter { $0.chatUsername == entry.id }
            .map { (sender: $0.senderName, content: $0.originalText) }

        let memoryStr = store.loadConversationMemory(chatUsername: entry.id)?
            .formatForPrompt() ?? ""

        return await chatInsightService.analyzeChat(
            chatUsername: entry.id,
            chatName: entry.displayName,
            chatType: entry.isGroup ? "group" : "private",
            category: entry.category.rawValue,
            selfName: selfDisplayName,
            timeRange: "今天",
            messages: formatted,
            recalledMessages: recalled,
            memory: memoryStr
        )
    }

    /// Return active contacts not yet whitelisted — candidates for the
    /// AI whitelist scan. Uses `topActiveContacts` from the WeChat DB so
    /// the scan works even when there are no current unread items.
    struct ScanCandidate {
        let username: String
        let displayName: String
        let isGroup: Bool
        let recentCount: Int
    }

    func scanCandidates(limit: Int = 50) -> [ScanCandidate] {
        let whitelisted = Set(store.loadContacts(level: nil).map(\.username))
        let dismissed = store.dismissedScanUsernames()
        let excluded = whitelisted.union(dismissed)
        guard let active = try? reader.topActiveContacts(limit: limit + excluded.count) else {
            return []
        }
        return active
            .filter { !excluded.contains($0.username) }
            .prefix(limit)
            .map { ScanCandidate(
                username: $0.username,
                displayName: $0.displayName,
                isGroup: $0.isGroup,
                recentCount: $0.recentCount
            ) }
    }

    /// Load recent messages for a chat as (sender, body) tuples — used by
    /// WhitelistScanView to give the AI categorizer real content.
    func recentMessages(chatUsername: String, limit: Int = 20) -> [(sender: String, body: String)] {
        (try? reader.getMessages(chatUsername: chatUsername, limit: limit, sinceLocalId: nil))?
            .map { (sender: $0.senderName, body: $0.text) } ?? []
    }

    /// All WeChat contacts (username → displayName) from the encrypted DB.
    func wechatContacts() -> [String: String] {
        reader.allContacts()
    }

    /// Run AI relationship inference for a contact, using the shared inferrer.
    func inferRelationship(contactUsername: String, contactName: String) async -> RelationshipProfile? {
        let msgs = (try? reader.getMessages(chatUsername: contactUsername, limit: 50)) ?? []
        let myUname = reader.myUsername()
        return await relationshipInferrer.infer(
            contactUsername: contactUsername,
            contactName: contactName,
            isGroup: contactUsername.contains("@chatroom"),
            messages: msgs,
            myUsername: myUname,
            myDisplayName: reader.displayName(for: myUname),
            mySelfNames: reader.mySelfNames
        )
    }

    /// Batch-infer relationship profiles for all contacts.
    /// Returns the number of successfully inferred profiles.
    func inferAllRelationships(contacts: [ContactEntry], progress: @MainActor @escaping (Int, Int) -> Void) async -> Int {
        guard !contacts.isEmpty else { return 0 }
        var count = 0
        for (i, contact) in contacts.enumerated() {
            await progress(i + 1, contacts.count)
            let result = await inferRelationship(contactUsername: contact.username, contactName: contact.displayName)
            if result != nil { count += 1 }
        }
        return count
    }

    /// Save a reply draft for later sending.
    func saveDraft(chatUsername: String, chatName: String, text: String) throws {
        try store.saveDraft(chatUsername: chatUsername, chatName: chatName, text: text, sendAt: nil)
    }

    /// Record AI reply feedback (adopted/ignored) for the learning loop.
    func recordReplyFeedback(adopted: Bool, chatUsername: String) throws {
        try store.writeAIFeedback(AIFeedbackEntry(
            id: 0,
            ts: Date(),
            msgUID: "reply_suggest:\(chatUsername):\(Int(Date().timeIntervalSince1970))",
            feedbackType: adopted ? .truePositive : .falsePositive,
            originalOutput: "",
            userAction: adopted ? "adopted_suggestion" : "ignored_suggestion",
            note: nil
        ))
    }

    /// Load conversation memory for a chat.
    func loadConversationMemory(chatUsername: String) -> ConversationMemory? {
        store.loadConversationMemory(chatUsername: chatUsername)
    }

    func loadAutopilotConfig() -> AutopilotConfig {
        store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
    }

    /// Compute relationship strength score (0-100) for a contact.
    func relationshipStrength(chatUsername: String) -> RelationshipStrength {
        let trend = chatTrend(chatUsername: chatUsername)
        let totalMessages = trend.reduce(0) { $0 + $1.count }
        let activeDays = trend.filter { $0.count > 0 }.count
        let daysSinceLastActive = trend.reversed().firstIndex { $0.count > 0 } ?? 7

        // Score: frequency (0-50) + recency (0-50)
        let frequencyScore = min(totalMessages * 3, 50)
        let recencyScore = max(50 - daysSinceLastActive * 10, 0)
        let score = min(frequencyScore + recencyScore, 100)

        let label: String
        switch score {
        case 80...100: label = "活跃"
        case 50..<80: label = "正常"
        case 20..<50: label = "冷却中"
        default: label = "疏远"
        }

        return RelationshipStrength(
            score: score,
            label: label,
            daysSinceLastInteraction: daysSinceLastActive
        )
    }

    /// Compute 7-day message trend for a chat. Returns daily counts (oldest first).
    func chatTrend(chatUsername: String) -> [DayMessageCount] {
        let messages = (try? reader.getMessages(chatUsername: chatUsername, limit: 200, sinceLocalId: nil)) ?? []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var counts: [Int: Int] = [:]  // daysAgo → count
        for msg in messages {
            let msgDate = Date(timeIntervalSince1970: Double(msg.createTime))
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: msgDate), to: today).day ?? 7
            if daysAgo >= 0 && daysAgo < 7 {
                counts[daysAgo, default: 0] += 1
            }
        }
        return (0..<7).reversed().map { daysAgo in
            let date = cal.date(byAdding: .day, value: -daysAgo, to: today)!
            return DayMessageCount(date: date, count: counts[daysAgo] ?? 0)
        }
    }

    /// Export a Markdown report to the Desktop.
    func exportReport() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())
        let filename = "WeChatHUD-Report-\(dateStr).md"
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)

        var md = "# WeChatHUD 报告 — \(dateStr)\n\n"

        // Stats
        md += "## 概览\n\n"
        md += "- 未读: \(stats.unreadCount)\n"
        md += "- @提醒: \(stats.atMentionCount)\n"
        md += "- VIP: \(stats.vipCount)\n"
        md += "- 待回复: \(stats.replyDebtCount)\n\n"

        // Daily report
        if let report = dailyReport {
            md += "## 日报\n\n"
            md += "\(report.todaySummary)\n\n"
            md += "### 明天第一件事\n\n\(report.tomorrowFirstThing.action)\n\n"
        }

        // Commitments
        let pending = commitments.filter { $0.status == .pending }
        if !pending.isEmpty {
            md += "## 进行中的承诺 (\(pending.count))\n\n"
            for c in pending {
                md += "- \(c.content) → \(c.commitTo)"
                if let d = c.deadlineAt { md += " (截止: \(df.string(from: d)))" }
                md += "\n"
            }
            md += "\n"
        }

        // Reply debt
        if !replyDebtItems.isEmpty {
            md += "## 待回复 (\(replyDebtItems.count))\n\n"
            for item in replyDebtItems.prefix(10) {
                md += "- [\(item.priority.rawValue.uppercased())] \(item.chatName): \(item.preview)\n"
            }
            md += "\n"
        }

        // Whitelist stats
        let whitelist = store.getWhitelist()
        md += "## 白名单 (\(whitelist.count))\n\n"
        let vips = whitelist.filter { $0.attentionLevel == .vip }
        let watches = whitelist.filter { $0.attentionLevel == .watch }
        md += "- VIP: \(vips.count) 人\n"
        md += "- 关注: \(watches.count) 人\n\n"

        md += "---\n*由 WeChatHUD 自动生成*\n"

        do {
            try md.write(to: desktop, atomically: true, encoding: .utf8)
            return desktop
        } catch {
            print("[WCHUD] export failed: \(error)")
            return nil
        }
    }

    /// Update a commitment's status and refresh the published list.
    func updateCommitmentStatus(msgUID: String, status: CommitmentStatus) throws {
        try store.updateCommitmentStatus(msgUID: msgUID, status: status)
        commitments = store.loadCommitments()
    }

    /// Load pending asks for a specific chat. Used by Person Profile card.
    func pendingAsksForChat(_ chatUsername: String) -> [PendingAsk] {
        Array(store.loadPendingAsks(status: .pending)
            .filter { $0.chatUsername == chatUsername }
            .prefix(3))
    }

    /// Refresh the reply suggester's config from the settings DB.
    /// Called by AppDelegate when the user changes AI settings.
    func refreshReplySuggesterConfig() async {
        let cfg = store.loadAIConfig()
        await relationshipInferrer.updateConfig(cfg)
        await briefingGenerator.updateConfig(cfg)
        await inboxSummarizer.updateConfig(cfg)
        await dailyRetrospector.updateConfig(cfg)
        await chatInsightService.updateConfig(cfg)
        await aiGroupCatchup.updateConfig(cfg)
    }

    /// Rebuild `dismissedInbox` / `snoozedInbox` / `silencedInbox` from
    /// `chat_actions`. Called at `start()` so the inbox view opens with
    /// the same handled state the user left it in last session.
    ///
    /// Mapping is the inverse of what the action methods write:
    ///   - snoozed_until > now   → snoozedInbox[user] = until
    ///   - silenced_at > now+1yr → silencedInbox.insert(user)   (permanent)
    ///   - silenced_at > 0       → dismissedInbox[user] = silenced_at
    private func hydrateInboxActionsFromStore() {
        let actions = store.loadChatActions()
        let nowEpoch = Int(Date().timeIntervalSince1970)
        // Anything silenced further than a year ahead is from the
        // "silence forever" branch (which writes now + 10 years).
        let permanentThreshold = nowEpoch + 365 * 86400

        dismissedInbox.removeAll(keepingCapacity: true)
        snoozedInbox.removeAll(keepingCapacity: true)
        silencedInbox.removeAll(keepingCapacity: true)

        for (user, action) in actions {
            if action.snoozedUntil > nowEpoch {
                snoozedInbox[user] = Date(timeIntervalSince1970: TimeInterval(action.snoozedUntil))
            }
            if action.silencedAt > permanentThreshold {
                silencedInbox.insert(user)
            } else if action.silencedAt > 0 {
                dismissedInbox[user] = Int64(action.silencedAt)
            }
        }
    }

    /// Dismiss an inbox item. Persists via `chat_actions.silenced_at` so
    /// the dismissal survives restarts; anything newer than this
    /// timestamp reactivates normally.
    func dismissInboxItem(_ item: InboxItem) {
        let ts = Int(item.timestamp.timeIntervalSince1970)
        dismissedInbox[item.chatUsername] = Int64(ts)
        try? store.silenceChat(chatUsername: item.chatUsername, silencedAt: ts)
        rebuildInbox()
    }

    /// Snooze an inbox item until a specific date. Persists via
    /// `chat_actions.snoozed_until` — the next scan after expiry will
    /// repopulate the chat into the active inbox automatically.
    func snoozeInboxItem(_ item: InboxItem, until: Date) {
        snoozedInbox[item.chatUsername] = until
        let untilEpoch = Int(until.timeIntervalSince1970)
        try? store.snoozeChat(chatUsername: item.chatUsername, until: untilEpoch)
        rebuildInbox()
    }

    /// Silence a chat from the inbox. We use a far-future `silenced_at`
    /// (10 years out) to cover "silence forever" — strictly newer
    /// messages than that get through, but in practice nothing will
    /// arrive from 10 years in the future. Cheaper than adding a new
    /// dedicated column for what amounts to the same mechanism.
    func silenceInboxItem(_ item: InboxItem) {
        silencedInbox.insert(item.chatUsername)
        let farFuture = Int(Date().timeIntervalSince1970) + 315_360_000 // ~10 years
        try? store.silenceChat(chatUsername: item.chatUsername, silencedAt: farFuture)
        rebuildInbox()
    }

    /// Restore a handled item back to the active inbox.
    func restoreInboxItem(_ item: InboxItem) {
        dismissedInbox.removeValue(forKey: item.chatUsername)
        snoozedInbox.removeValue(forKey: item.chatUsername)
        silencedInbox.remove(item.chatUsername)
        // Drop the persisted side too — otherwise a user who silences
        // via ExtendedTabsView (persistent) then clicks "restore" in
        // the inbox would only clear the in-memory hint, and the
        // chat would stay silenced in the store forever.
        try? store.clearChatAction(chatUsername: item.chatUsername)
        rebuildInbox()
    }

    /// Unsilence a chat (remove from silenced set).
    func unsilenceInboxItem(_ item: InboxItem) {
        silencedInbox.remove(item.chatUsername)
        rebuildInbox()
    }

    /// Rebuild the inbox from current state. Used by all inbox mutation methods.
    private func rebuildInbox() {
        let result = InboxBuilder.build(
            replyDebtItems: replyDebtItems,
            notifications: recentNotifications,
            dismissed: dismissedInbox,
            snoozed: snoozedInbox,
            silenced: silencedInbox
        )
        inboxItems = result.active
        handledItems = result.handled

        // Apply cached AI summaries
        for i in inboxItems.indices {
            let key = "\(inboxItems[i].chatUsername)_\(Int(inboxItems[i].timestamp.timeIntervalSince1970))"
            if let cached = summaryCache[key] {
                inboxItems[i].aiSummary = cached
            }
        }

        // Prune stale cache entries
        cleanSummaryCache()
    }

    /// Generate reply suggestions for a reply debt item.
    func loadReplySuggestions(for item: ReplyDebtItem) async -> [AIReplySuggester.Suggestion] {
        // Fetch style profile to make suggestions match user's writing style
        let style = await styleProfiler.getProfile(chatUsername: item.chatUsername)

        let input = AIReplySuggester.Input(
            messageBody: item.preview,
            senderName: item.senderName,
            chatName: item.chatName,
            isGroup: item.isGroup,
            askType: .none,
            relationship: "work",
            styleHint: buildStyleHint(style),
            feedbackContext: buildFeedbackHint()
        )
        return await replySuggester.suggest(input) ?? []
    }

    /// Build the "用户采纳了 X/Y 条建议" hint from persisted AI feedback.
    /// Extracted so both reply-suggestion entry points (ReplyDebt and
    /// InboxItem) share the same learning signal — otherwise one path
    /// gets smarter with use and the other stays frozen.
    private func buildFeedbackHint() -> String? {
        let recent = store.loadAIFeedback(limit: 10, msgUIDPrefix: "reply_suggest:")
        guard !recent.isEmpty else { return nil }
        let adopted = recent.filter { $0.feedbackType == .truePositive }.count
        let rejected = recent.filter { $0.feedbackType == .falsePositive }.count
        let notes = recent.compactMap(\.note).filter { !$0.isEmpty }.prefix(3)
        var parts: [String] = []
        if adopted > 0 { parts.append("用户采纳了 \(adopted)/\(recent.count) 条建议") }
        if rejected > 0 { parts.append("拒绝了 \(rejected) 条") }
        if !notes.isEmpty { parts.append("偏好备注: \(notes.joined(separator: "; "))") }
        return parts.isEmpty ? nil : parts.joined(separator: "。")
    }

    private func buildStyleHint(_ style: StyleProfiler.StyleProfile) -> String? {
        guard !style.isEmpty else { return nil }
        return "用户风格: \(style.toneDescription). 常用语: \(style.frequentPhrases.prefix(3).joined(separator: "、"))"
    }

    /// Generate AI summaries for inbox items that don't have cached summaries.
    /// Called after scan. Runs async, updates inboxItems progressively.
    private func generateSummaries() {
        let items = inboxItems.filter { $0.aiSummary == nil }
        guard !items.isEmpty else { return }

        // Sort by priority — P0 summaries first
        let sorted = items.sorted { $0.priority < $1.priority }

        let readerRef = reader
        let storeRef = store
        let summarizer = inboxSummarizer

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for item in sorted {
                // Check cache first
                let cacheKey = "\(item.chatUsername)_\(Int(item.timestamp.timeIntervalSince1970))"
                if let cached = self.summaryCache[cacheKey] {
                    self.updateItemSummary(chatUsername: item.chatUsername, timestamp: item.timestamp, summary: cached)
                    continue
                }

                // Build InboxContext — trigger message MUST be the latest
                // inbound (peer) message in the window. Without the
                // self-filter, a user's own ack ("收到") that came after
                // the real trigger would be picked as the trigger
                // message, the AI would faithfully summarize it as
                // "收到", and the row would end up displaying
                // "陈总: 收到" — where 陈总 is the peer sender from the
                // debt item but "收到" is the summary of the user's
                // own reply. Alignment with ReplyDebtScorer's
                // latestInbound requires the same predicate here.
                let msgs = (try? readerRef.getMessages(chatUsername: item.chatUsername, limit: 50)) ?? []
                let cutoff48h = Date().addingTimeInterval(-48 * 3600)
                let myUname = readerRef.myUsername()
                let myDisplay = readerRef.displayName(for: myUname)
                let mySelfNames = readerRef.mySelfNames
                let filtered = msgs.filter { msg in
                    let inWindow = Date(timeIntervalSince1970: Double(msg.createTime)) >= cutoff48h
                    let isSelf = MessageHelpers.isFromSelf(
                        msg,
                        chatUsername: item.chatUsername,
                        myUsername: myUname,
                        myDisplayName: myDisplay,
                        mySelfNames: mySelfNames
                    )
                    return inWindow && !isSelf
                }
                guard let triggerMsg = filtered.first else { continue }

                let context = InboxContextBuilder.build(
                    chatUsername: item.chatUsername,
                    triggerMessage: triggerMsg,
                    reader: readerRef,
                    store: storeRef,
                    myUsername: myUname,
                    contactEntry: storeRef.getContact(username: item.chatUsername),
                    whitelistEntry: storeRef.getWhitelistEntry(username: item.chatUsername)
                )

                // Call AI
                let summary = await summarizer.summarize(context)
                guard let summary = summary else { continue }

                // Cache + update UI
                self.summaryCache[cacheKey] = summary
                self.updateItemSummary(chatUsername: item.chatUsername, timestamp: item.timestamp, summary: summary)
            }
        }
    }

    /// Pre-generate ActionPanel data in the background. Fires ALL
    /// items in parallel and commits each slot (analysis / replies)
    /// to the cache as soon as it resolves, so the user doesn't
    /// wait for the slowest round-trip in a serial queue.
    ///
    /// Earlier versions ran one item at a time (`for ... await`),
    /// which meant a row with a slow 7-second analysis blocked
    /// every subsequent row — if the user hovered the 3rd item
    /// the spinner was guaranteed to show even though prefetch
    /// had "started". Now each item has its own Task and each
    /// piece (analysis vs replies) writes its slot independently.
    ///
    /// Cache key: chatUsername. Each slot entry is stamped with
    /// the item's timestamp so a newer message invalidates it.
    private func prefetchActionPanelData() {
        let items = inboxItems.filter { $0.actionRequired }
        guard !items.isEmpty else { return }

        for item in items {
            let ts = Int(item.timestamp.timeIntervalSince1970)
            // Skip if we already have a fully-materialized entry
            // for this exact (chat, timestamp) pair.
            if let existing = actionPrefetch[item.chatUsername],
               existing.timestamp == ts,
               (existing.groupAnalysis != nil || existing.privateAnalysis != nil),
               (!existing.hasProfile || !existing.replies.isEmpty) {
                continue
            }

            let chatUsername = item.chatUsername
            let captured = item  // for Task capture
            let hasProfile = hasRelationshipProfile(for: chatUsername)

            // Fire analysis and replies in parallel. Each writes
            // back to the cache on completion — partial entries
            // are valid and the UI can render whichever slot
            // arrives first. Completion is recorded via
            // `analysisAttempted` / `repliesAttempted` so a silent
            // API failure switches the UI to an error state
            // instead of spinning forever.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                var group: ChatAnalyzer.GroupAnalysis?
                var priv: ChatAnalyzer.PrivateAnalysis?
                if captured.isGroup {
                    let (result, _) = await self.analyzeGroupChat(item: captured)
                    group = result
                } else {
                    let (result, _) = await self.analyzePrivateChat(item: captured)
                    priv = result
                }
                guard self.isItemStillCurrent(chatUsername: chatUsername, ts: ts) else { return }
                self.mergeActionPrefetch(
                    chatUsername: chatUsername,
                    ts: ts,
                    groupAnalysis: group,
                    privateAnalysis: priv,
                    replies: nil,
                    hasProfile: hasProfile,
                    markAnalysisAttempted: true,
                    markRepliesAttempted: false
                )
            }

            if hasProfile {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let replies = (await self.loadReplySuggestions(for: captured)) ?? []
                    guard self.isItemStillCurrent(chatUsername: chatUsername, ts: ts) else { return }
                    self.mergeActionPrefetch(
                        chatUsername: chatUsername,
                        ts: ts,
                        groupAnalysis: nil,
                        privateAnalysis: nil,
                        replies: replies,
                        hasProfile: hasProfile,
                        markAnalysisAttempted: false,
                        markRepliesAttempted: true
                    )
                }
            } else {
                // No profile → no replies ever coming. Mark attempted
                // immediately so UI doesn't wait on a task that
                // won't run.
                mergeActionPrefetch(
                    chatUsername: chatUsername,
                    ts: ts,
                    groupAnalysis: nil,
                    privateAnalysis: nil,
                    replies: nil,
                    hasProfile: hasProfile,
                    markAnalysisAttempted: false,
                    markRepliesAttempted: true
                )
            }
        }
    }

    /// True when the inbox still contains an item matching the
    /// given (chatUsername, timestamp) pair. Used by prefetch
    /// tasks to avoid committing stale results for items that
    /// have been dismissed / replaced during the AI round-trip.
    private func isItemStillCurrent(chatUsername: String, ts: Int) -> Bool {
        inboxItems.contains {
            $0.chatUsername == chatUsername &&
            Int($0.timestamp.timeIntervalSince1970) == ts
        }
    }

    /// Merge partial prefetch results into the cache entry for a
    /// (chat, timestamp) pair. `nil` result args leave the existing
    /// slot alone; non-nil args overwrite it. `markAnalysisAttempted`
    /// / `markRepliesAttempted` flip their flags to true regardless
    /// of whether the corresponding result arg is nil — so a failed
    /// API call still records "we tried". Timestamp mismatch wipes
    /// and restarts the entry (a newer message invalidated it).
    private func mergeActionPrefetch(
        chatUsername: String,
        ts: Int,
        groupAnalysis: ChatAnalyzer.GroupAnalysis?,
        privateAnalysis: ChatAnalyzer.PrivateAnalysis?,
        replies: [SuggestedReply]?,
        hasProfile: Bool,
        markAnalysisAttempted: Bool,
        markRepliesAttempted: Bool
    ) {
        let existing = actionPrefetch[chatUsername]
        let sameGeneration = existing?.timestamp == ts
        actionPrefetch[chatUsername] = PrefetchedAction(
            timestamp: ts,
            groupAnalysis: groupAnalysis ?? (sameGeneration ? existing?.groupAnalysis : nil),
            privateAnalysis: privateAnalysis ?? (sameGeneration ? existing?.privateAnalysis : nil),
            replies: replies ?? (sameGeneration ? existing?.replies ?? [] : []),
            hasProfile: hasProfile,
            analysisAttempted: markAnalysisAttempted || (sameGeneration && existing?.analysisAttempted == true),
            repliesAttempted: markRepliesAttempted || (sameGeneration && existing?.repliesAttempted == true)
        )
    }

    /// Update a single item's aiSummary without rebuilding the list.
    /// Matches on `(chatUsername, timestamp)` because the same chat can
    /// legitimately have multiple inbox entries (different unread
    /// bursts), and the cache key is timestamped — matching on just
    /// `chatUsername` could paint the wrong row's summary when two are
    /// in flight.
    ///
    /// Also updates `handledItems`: if the user dismisses / snoozes /
    /// silences a row between scan and summary arrival, the item
    /// migrates out of `inboxItems`. Writing the summary there too
    /// means "restore" brings back the enriched row instead of a blank
    /// one that would force a re-summarize.
    private func updateItemSummary(chatUsername: String, timestamp: Date, summary: String) {
        let ts = Int(timestamp.timeIntervalSince1970)
        if let idx = inboxItems.firstIndex(where: {
            $0.chatUsername == chatUsername && Int($0.timestamp.timeIntervalSince1970) == ts
        }) {
            inboxItems[idx].aiSummary = summary
            return
        }
        if let idx = handledItems.firstIndex(where: {
            $0.chatUsername == chatUsername && Int($0.timestamp.timeIntervalSince1970) == ts
        }) {
            handledItems[idx].aiSummary = summary
        }
    }

    /// Clean summary cache entries not matching any current inbox or
    /// handled item. Without keeping handled items in the live set,
    /// restoring a dismissed row would force re-summarization — we
    /// keep them cached as long as the row is still visible somewhere.
    private func cleanSummaryCache() {
        func key(_ item: InboxItem) -> String {
            "\(item.chatUsername)_\(Int(item.timestamp.timeIntervalSince1970))"
        }
        let activeKeys = Set(inboxItems.map(key)).union(handledItems.map(key))
        summaryCache = summaryCache.filter { activeKeys.contains($0.key) }
    }

    /// Generate a structured AI briefing for an inbox item (situation + suggestion + replies).
    /// Called when the user expands an inbox row. Returns nil on failure.
    func loadBriefing(for item: InboxItem) async -> InboxBriefing? {
        // Re-fetch the latest message from the reader to build full context
        guard let latestMessage = (try? reader.getMessages(chatUsername: item.chatUsername, limit: 1))?.first else {
            return nil
        }

        let contactEntry = store.getContact(username: item.chatUsername)
        let whitelistEntry = store.getWhitelistEntry(username: item.chatUsername)

        let context = InboxContextBuilder.build(
            chatUsername: item.chatUsername,
            triggerMessage: latestMessage,
            reader: reader,
            store: store,
            myUsername: reader.myUsername(),
            contactEntry: contactEntry,
            whitelistEntry: whitelistEntry
        )

        // Get style profile for personalized replies
        let style = await styleProfiler.getProfile(chatUsername: item.chatUsername)
        let styleHint = style.isEmpty
            ? nil
            : "用户风格: \(style.toneDescription). 常用语: \(style.frequentPhrases.prefix(3).joined(separator: "、"))"

        return await briefingGenerator.generate(context, styleHint: styleHint)
    }

    // MARK: - On-demand chat analysis

    func analyzeGroupChat(item: InboxItem) async -> (ChatAnalyzer.GroupAnalysis?, String?) {
        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: item.chatUsername, limit: 50)
        } catch {
            return (nil, "读取消息失败: \(error.localizedDescription)")
        }
        if messages.isEmpty { return (nil, "没有找到消息记录") }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let filtered = messages.filter {
            Date(timeIntervalSince1970: Double($0.createTime)) >= cutoff
        }
        if filtered.isEmpty { return (nil, "48小时内没有消息") }
        let myUname = reader.myUsername()
        let result = await chatAnalyzer.analyzeGroup(
            chatUsername: item.chatUsername,
            chatName: item.chatName,
            messages: filtered,
            myUsername: myUname,
            myName: "我",
            myDisplayName: reader.displayName(for: myUname),
            mySelfNames: reader.mySelfNames
        )
        return (result, result == nil ? "AI 分析返回为空，可能超时或解析失败" : nil)
    }

    func analyzePrivateChat(item: InboxItem) async -> (ChatAnalyzer.PrivateAnalysis?, String?) {
        let messages: [MessageInfo]
        do {
            messages = try reader.getMessages(chatUsername: item.chatUsername, limit: 50)
        } catch {
            return (nil, "读取消息失败: \(error.localizedDescription)")
        }
        if messages.isEmpty { return (nil, "没有找到消息记录") }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let filtered = messages.filter {
            Date(timeIntervalSince1970: Double($0.createTime)) >= cutoff
        }
        if filtered.isEmpty { return (nil, "48小时内没有消息") }
        let myUname = reader.myUsername()
        let result = await chatAnalyzer.analyzePrivate(
            chatUsername: item.chatUsername,
            contactName: item.chatName,
            messages: filtered,
            myUsername: myUname,
            myName: "我",
            myDisplayName: reader.displayName(for: myUname),
            mySelfNames: reader.mySelfNames
        )
        return (result, result == nil ? "AI 分析返回为空，可能超时或解析失败" : nil)
    }

    func loadReplySuggestions(for item: InboxItem) async -> [SuggestedReply]? {
        guard let profile = store.getRelationshipProfile(username: item.chatUsername) else {
            return nil
        }
        let relationship = "\(profile.relationship) (\(profile.hierarchy.label))"
        let style = await styleProfiler.getProfile(chatUsername: item.chatUsername)

        let input = AIReplySuggester.Input(
            messageBody: item.preview,
            senderName: item.senderName,
            chatName: item.chatName,
            isGroup: item.isGroup,
            askType: item.askType,
            relationship: relationship,
            styleHint: buildStyleHint(style),
            feedbackContext: buildFeedbackHint()
        )

        guard let suggestions = await replySuggester.suggest(input) else { return nil }
        return suggestions.map { s in
            SuggestedReply(text: s.text, tone: s.tone, recommended: false)
        }
    }

    func hasRelationshipProfile(for username: String) -> Bool {
        store.getRelationshipProfile(username: username) != nil
    }

    /// Fetch the relationship profile for a chat (used by the weekly
    /// report to decide whether a counterpart is superior / peer /
    /// subordinate). Returns nil when the user hasn't inferred a
    /// profile for this contact yet — the caller must handle that
    /// gracefully (those items flow through "未分类" sections).
    func relationshipProfile(for username: String) -> RelationshipProfile? {
        store.getRelationshipProfile(username: username)
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
            let config = store.loadAIConfig()
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

