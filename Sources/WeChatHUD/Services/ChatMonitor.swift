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

struct ContactInferenceStatus {
    var total: Int
    var completed: Int
    var succeeded: Int
    var isRunning: Bool

    var label: String {
        if isRunning {
            return total > 0 ? "后台分析 \(completed)/\(total)" : "后台分析准备中"
        }
        return "完成 \(succeeded) 个画像"
    }
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
    /// Cached daily report, regenerated every 30 minutes.
    @Published var dailyReport: DailyReport? = nil
    @Published var dailyReportGeneratedAt: Date?
    var dailyReportCache: [String: Date] = [:]  // dateKey -> generatedAt = nil
    @Published var dailyReportError: String? = nil
    @Published var dailyReportIsLoading: Bool = false
    @Published var dailyReportActionInsights: [String: DailyReportActionInsight] = [:]
    @Published var dailyReportViewedDate: Date = Date()
    /// Token for the most recent daily-report request. Async enrichment from
    /// an older date must never overwrite the report selected most recently.
    private(set) var dailyReportLoadGeneration: UUID?

    func beginDailyReportLoad() -> UUID {
        let generation = UUID()
        dailyReportLoadGeneration = generation
        return generation
    }
    /// Autopilot state — exposed for UI.
    @Published var autopilotActive = false
    @Published var autopilotPaused = false
    @Published var autopilotManuallyPaused = false
    @Published var autopilotLog: [AutopilotLogEntry] = []
    @Published var autopilotSessionSent = 0
    @Published var autopilotSessionPending = 0
    @Published var autopilotPendingSendQueue: [PendingSend] = []
    @Published var autopilotSessionStats = AutopilotService.SessionStats()
    /// In-memory session ledger: one entry per verified outgoing message
    /// per chat during an active autopilot session. Reset on start/stop.
    /// Capped at 20 entries per chat (FIFO eviction).
    @Published private(set) var autopilotSessionLedger: [String: [LedgerEntry]] = [:]
    @Published var inboxItems: [InboxItem] = []
    /// Published handled items for the UI (dismissed/snoozed/silenced).
    @Published var handledItems: [InboxItem] = []
    @Published var unsavedReplyDraftEdits: [Int64: String] = [:]
    @Published var composerDraftEdits: [String: String] = [:]
    /// Persisted action failures stay visible until acknowledged or a retry succeeds.
    @Published var inboxActionError: String?
    /// All currently silenced inbox items (for management UI).
    var silencedItems: [InboxItem] {
        handledItems.filter { $0.status == .silenced }
    }
    let insightCoordinator: InsightCoordinator
    @Published var contactInferenceStatus: ContactInferenceStatus? = nil
    /// Tracks dismissed inbox items: chatUsername → timestamp at time of dismiss.
    private var dismissedInbox: [String: Int64] = [:]
    /// Tracks snoozed inbox items: chatUsername → snooze expiry date.
    private var snoozedInbox: [String: Date] = [:]
    /// Tracks silenced (permanently muted) chats.
    private var silencedInbox: Set<String> = []
    /// The autopilot service instance. Initialized lazily on first toggle.
    private(set) var autopilotService: AutopilotService?
    private let recentLimit = 10

    let reader: WeChatReader
    nonisolated(unsafe) let store: HUDStore
    let aiService: AIService

    // MARK: - Retrospective surface (Plan M6.0)
    //
    // These nonisolated read accessors let the retrospective adapter actors
    // (ChatMonitorScopeProvider / ChatMonitorMessageQuery) reach the
    // private fields without breaking encapsulation. HUDStore is internally
    // FULLMUTEX-safe; AIService is an actor; reader.myUsername() is a
    // synchronous lookup. All safe to call cross-isolation.

    nonisolated var hudStore: HUDStore { store }
    nonisolated var myUsername: String { reader.myUsername() }
    nonisolated var myDisplayName: String {
        let me = myUsername
        return store.getWhitelistEntry(username: me)?.displayName ?? ""
    }

    /// AI service witness for retrospective services that depend on
    /// `any AIServiceProtocol` instead of the concrete actor type.
    nonisolated var aiServiceRef: any AIServiceProtocol { aiService }

    /// Date-range message query. Wraps `reader.getMessages(chatUsername:limit:)`
    /// and filters by `createTime`. MessageInfo.createTime is `Int` (unix ts);
    /// we convert the start/end Dates before comparison.
    nonisolated func messagesInRange(
        chatUsername: String,
        start: Date,
        end: Date,
        fetchLimit: Int = 1000
    ) -> [MessageInfo] {
        let raw: [MessageInfo]
        do {
            raw = try reader.getMessages(chatUsername: chatUsername, limit: fetchLimit, sinceLocalId: nil)
        } catch {
            return []
        }
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int(end.timeIntervalSince1970)
        return raw.filter { msg in
            msg.createTime >= startTs && msg.createTime <= endTs
        }
    }

    /// Sample messages for AI group screening — first N messages in the
    /// date range, formatted as plain text strings (no metadata).
    nonisolated func sampleMessageTexts(
        chatUsername: String,
        start: Date,
        end: Date,
        limit: Int = 20
    ) -> [String] {
        messagesInRange(chatUsername: chatUsername, start: start, end: end, fetchLimit: 1000)
            .prefix(limit)
            .map { AIService.sanitizeForAI($0.text) }
    }

    /// Lazy retrospective orchestrator. Owns the @MainActor RetrospectiveJob
    /// + two adapter actors that bridge ChatMonitor APIs to the
    /// retrospective protocols. UI binds to `retrospectiveJob.$state` for
    /// progress + completion notifications.
    @MainActor
    lazy var retrospectiveJob: RetrospectiveJob = {
        return RetrospectiveJob(
            store: hudStore,
            aiService: aiServiceRef,
            scopeCandidatesProvider: ChatMonitorScopeProvider(monitor: self),
            messageQuery: ChatMonitorMessageQuery(monitor: self),
            config: .default
        )
    }()
    private let groupContextBriefingService: GroupContextBriefingService
    private let aiGroupCatchup: AIGroupCatchup
    private let contextAnalyzer: ContextAnalyzer
    lazy var aiClassifier: AIClassifier = {
        AIClassifier(store: store, aiService: aiService)
    }()
    @Published var classificationPendingCount = 0
    @Published var classificationProcessing = false
    @Published var discussionPendingCount = 0
    @Published var discussionProcessing = false
    private var discussionWorker: Task<Void, Never>?
    private var discussionWorkerGeneration = UUID()
    var classificationWorker: Task<Void, Never>?
    private lazy var commitmentTracker: CommitmentTracker = {
        CommitmentTracker(store: store, aiService: aiService)
    }()
    private lazy var discussionTracker: DiscussionTracker = {
        DiscussionTracker(store: store, aiService: aiService)
    }()
    @Published var discussionItems: [DiscussionItem] = []
    private lazy var vipAggregator: VIPAggregator = {
        VIPAggregator(store: store, aiService: aiService)
    }()
    private lazy var recallAnalyzer: RecallAnalyzer = {
        RecallAnalyzer(store: store, aiService: aiService)
    }()
    lazy var replySuggester: AIReplySuggester = {
        AIReplySuggester(store: store, aiService: aiService)
    }()
    lazy var styleProfiler: StyleProfiler = {
        StyleProfiler(reader: reader, store: store)
    }()
    private lazy var memoryUpdater: ConversationMemoryUpdater = {
        ConversationMemoryUpdater(reader: reader, store: store, aiService: aiService)
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
    lazy var dailyReportGenerator: AIDailyReportGenerator = {
        AIDailyReportGenerator(aiService: aiService, store: store)
    }()
    lazy var dailyReportActionInsightGenerator: AIDailyReportActionInsightGenerator = {
        AIDailyReportActionInsightGenerator(aiService: aiService, store: store)
    }()
    private lazy var briefingGenerator: AIBriefingGenerator = {
        AIBriefingGenerator(store: store, aiService: aiService)
    }()
    lazy var chatAnalyzer: ChatAnalyzer = {
        ChatAnalyzer(store: store, aiService: aiService)
    }()
    private lazy var relationshipInferrer: RelationshipInferrer = {
        RelationshipInferrer(store: store, config: store.loadAIConfig())
    }()
    private lazy var inboxSummarizer: AIInboxSummarizer = {
        AIInboxSummarizer(store: store, aiService: aiService)
    }()
    /// Cache: chatUsername + msgTimestamp → AI summary string
    private var summaryCache: [String: String] = [:]
    private var summaryInFlight: Set<String> = []
    private let inboxSummaryAnalysisType = "inbox_row_summary_v3"
    private var contactInferenceTask: Task<Void, Never>?

    /// Pre-generated expand-panel data — analysis + reply suggestions
    /// fired in the background right after scan, so when the user
    /// clicks an inbox row the action panel reads from cache and
    /// renders instantly instead of spinning on "正在整理重点…".
    /// Keyed by chatUsername; `timestamp` binds each entry to a
    /// specific message so stale cache from a prior message gets
    /// rejected when a newer one arrives.
    struct PrefetchedAction {
        let timestamp: Int
        let generationKey: String
        let groupAnalysis: ChatAnalyzer.GroupAnalysis?
        let privateAnalysis: ChatAnalyzer.PrivateAnalysis?
        let analysisError: String?
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
    @Published var actionPrefetch: [String: PrefetchedAction] = [:]

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

    init(reader: WeChatReader, store: HUDStore, aiService: AIService) {
        self.reader = reader
        self.store = store
        self.aiService = aiService
        self.groupContextBriefingService = GroupContextBriefingService(
            reader: reader,
            store: store,
            client: aiService
        )
        self.aiGroupCatchup = AIGroupCatchup(store: store, aiService: aiService)
        self.contextAnalyzer = ContextAnalyzer(store: store, aiService: aiService)
        self.insightCoordinator = InsightCoordinator(reader: reader, store: store, aiService: aiService)
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
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Snooze expiry is time-based, so reevaluate it even when
                // WeChat is closed or its databases have not changed.
                self.refreshExpiredSnoozes()
                // Deadline reminders must keep running even when the scan is
                // gated because WeChat is closed or its DB is unavailable.
                // Read only active commitments from durable storage so a
                // stale published snapshot cannot resurrect completed work.
                let activeCommitments = self.store.loadCommitments(status: .pending)
                    + self.store.loadCommitments(status: .overdue)
                self.alertEngine.evaluateCommitmentDeadlines(commitments: activeCommitments)

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

                self.resumeDiscussionExtraction()

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
        discussionWorkerGeneration = UUID()
        discussionWorker?.cancel()
        discussionWorker = nil
        discussionProcessing = false
        classificationWorker?.cancel()
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
        guard !PreviewRuntime.isEnabled else { reloadAIData(); return }
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
            // Reuse the exact source-centered window loaded by phase 1. If
            // the source was unavailable, never let phase 2 reinterpret the
            // chat's newest messages as the trigger context.
            guard !result.contextMessages.isEmpty else { return }
            let supportsDeepActionContext = notification.supportsDeepActionContext
            let contextMessages = result.contextMessages

            // AIGroupCatchup: enrich briefing with headline / highlights.
            let catchupInput = AIGroupCatchup.Input(
                chatName: notification.chatName,
                selfName: myUname,
                messages: contextMessages.map { ($0.senderName, AIService.sanitizeForAI($0.text)) }
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
                    if supportsDeepActionContext, briefing.deepWhatTheyWant == nil, !summary.highlights.isEmpty {
                        briefing.deepWhatTheyWant = summary.highlights.joined(separator: " · ")
                    }
                    state.briefing = briefing
                    self.groupContextStates[key] = state
                }
            }

            // ContextAnalyzer: fill deep* fields using a synthetic PendingAsk.
            guard supportsDeepActionContext else { return }
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
        dismissedInbox[chatUsername] = Int64(currentMax)
        snoozedInbox.removeValue(forKey: chatUsername)
        silencedInbox.remove(chatUsername)
        moveToSuppressed(chatUsername: chatUsername)
        rebuildInbox()
    }

    /// Snooze an entire chat until an absolute unix timestamp. Items
    /// move to `suppressedItems`; when the snooze expires the next scan
    /// will repopulate them into `unreadItems`.
    func snoozeChat(_ chatUsername: String, until: Int) {
        try? store.snoozeChat(chatUsername: chatUsername, until: until)
        snoozedInbox[chatUsername] = Date(timeIntervalSince1970: Double(until))
        dismissedInbox.removeValue(forKey: chatUsername)
        silencedInbox.remove(chatUsername)
        moveToSuppressed(chatUsername: chatUsername)
        rebuildInbox()
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
        do {
            try store.ignoreSender(chatUsername: chatUsername, chatName: chatName,
                                   senderUsername: senderUsername, senderName: senderName)
            inboxActionError = nil
        } catch {
            inboxActionError = "屏蔽规则未保存，消息仍保持原状。请重试。"
            return
        }

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
        do {
            try store.unignoreSender(chatUsername: chatUsername,
                                     senderUsername: senderUsername, senderName: senderName)
            inboxActionError = nil
        } catch {
            inboxActionError = "屏蔽规则未能恢复，原规则仍保留。请重试。"
            return
        }
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
        dismissedInbox.removeValue(forKey: chatUsername)
        snoozedInbox.removeValue(forKey: chatUsername)
        silencedInbox.remove(chatUsername)
        let restored = suppressedItems.filter {
            $0.chatUsername == chatUsername && !$0.isIgnored
        }
        if !restored.isEmpty {
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
        }
        rebuildInbox()
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

    func setInboxItemVIP(_ item: InboxItem, isVIP: Bool) {
        updateWhitelistAttention(
            username: item.chatUsername,
            displayName: item.chatName,
            isGroup: item.isGroup,
            fallbackCategory: item.isGroup ? .work : .life,
            attentionLevel: isVIP ? .vip : .watch
        )
    }

    func untrackInboxItem(_ item: InboxItem) {
        try? store.removeFromWhitelist(username: item.chatUsername)
        dismissedInbox.removeValue(forKey: item.chatUsername)
        snoozedInbox.removeValue(forKey: item.chatUsername)
        silencedInbox.remove(item.chatUsername)
        replyDebtItems.removeAll { $0.chatUsername == item.chatUsername }
        recentNotifications.removeAll { $0.chatUsername == item.chatUsername }
        if latestNotification?.chatUsername == item.chatUsername {
            latestNotification = nil
        }
        rebuildInbox()
        Task { @MainActor in
            await self.scan()
        }
    }

    func ignoreInboxItemSender(_ item: InboxItem) {
        guard item.isGroup, !item.senderName.isEmpty else { return }
        ignoreSender(
            chatUsername: item.chatUsername,
            chatName: item.chatName,
            senderUsername: "",
            senderName: item.senderName
        )
        recentNotifications.removeAll {
            $0.chatUsername == item.chatUsername && $0.senderName == item.senderName
        }
        rebuildInbox()
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

        activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.wechatBundleIDs.contains(bid) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.autopilotActive else { return }
                await self.autopilotService?.onUserBecameActive()
                if let service = self.autopilotService {
                    self.autopilotPaused = await service.isPaused
                    self.autopilotManuallyPaused = await service.manuallyPaused
                }
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
                guard let self, self.autopilotActive else { return }
                await self.autopilotService?.onUserBecameInactive()
                if let service = self.autopilotService {
                    self.autopilotPaused = await service.isPaused
                    self.autopilotManuallyPaused = await service.manuallyPaused
                }
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

        // Directory enumeration cannot prove which account is currently logged in.
        // Stop only when the explicitly configured source is no longer available.
        if reader.hasAccountSwitched() {
            print("[WCHUD] scan gated — configured database directory unavailable")
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
        let apActive = autopilotActive
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
                recentLimit: rLimit,
                autopilotActive: apActive
            )
        }.value

        let ms = Int(Date().timeIntervalSince(scanStart) * 1000)

        guard let o = outcome else {
            print("[WCHUD] scan failed after \(ms)ms")
            stats = HUDStats(
                unreadCount: stats.unreadCount,
                atMentionCount: stats.atMentionCount,
                vipCount: stats.vipCount,
                replyDebtCount: stats.replyDebtCount,
                syncStatus: .error("scan failed"),
                lastSyncAt: stats.lastSyncAt
            )
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
        // Rows written before the naming fallback existed still carry raw
        // `…@chatroom` ids. Repair before reloading so the published lists
        // already show readable names.
        let repairedNames = repairStaleChatNames()
        if repairedNames > 0 {
            print("[WCHUD] repaired \(repairedNames) persisted chat name rows")
        }
        let repairedTargets = repairStaleCommitTargets()
        if repairedTargets > 0 {
            print("[WCHUD] repaired \(repairedTargets) commitment target rows")
        }
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
            let durableMsgs = store.loadPendingAutopilotInbound(limit: 200)
            var seenMsgUIDs: Set<String> = []
            let msgs = (durableMsgs + o.newInboundMessages)
                .sorted { lhs, rhs in
                    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                    return lhs.msgUID < rhs.msgUID
                }
                .filter { msg in
                    if seenMsgUIDs.contains(msg.msgUID) { return false }
                    seenMsgUIDs.insert(msg.msgUID)
                    return true
                }
            let config = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
            let myUname = reader.myUsername()
            Task {
                let result = await service.handleNewMessages(msgs, config: config, myUsername: myUname)
                if !result.ackedMsgUIDs.isEmpty {
                    try? self.store.deleteAutopilotInbound(msgUIDs: result.ackedMsgUIDs)
                }
                let queue = await service.pendingSendQueue
                let stats = await service.sessionStats
                let manPaused = await service.manuallyPaused
                let paused = await service.isPaused
                let sentCount = await service.sessionSent
                await MainActor.run {
                    self.autopilotSessionSent = sentCount
                    self.autopilotSessionPending += result.totalPending
                    self.autopilotPendingSendQueue = queue
                    self.autopilotSessionStats = stats
                    self.autopilotManuallyPaused = manPaused
                    self.autopilotPaused = paused
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
        discussionItems = store.loadDiscussionItems()
    }

    /// Update a discussion item's status (done / dismissed / archived).
    /// UI calls this from the 工作台 tab — reloads the published list
    /// so the row vanishes from the active view immediately.
    func updateDiscussionItemStatus(id: Int64, status: DiscussionItemStatus) {
        try? store.updateDiscussionItemStatus(id: id, status: status)
        discussionItems = store.loadDiscussionItems()
    }

    /// Native workspace write path: only publish after durable storage succeeds.
    func setDiscussionItemStatus(id: Int64, status: DiscussionItemStatus) throws {
        try store.updateDiscussionItemStatus(id: id, status: status)
        if let item = discussionItems.first(where: { $0.id == id }),
           let feedback = DiscussionCorrection.feedback(for: item, status: status) {
            try store.writeAIFeedback(feedback)
        }
        discussionItems = store.loadDiscussionItems()
    }

    /// Corrects an AI responsibility label and records that correction for
    /// later prompt/evaluation work.
    func setDiscussionItemOwner(id: Int64, owner: DiscussionItemOwner) throws {
        guard let item = discussionItems.first(where: { $0.id == id }) else { return }
        guard try store.updateDiscussionItemOwner(id: id, owner: owner) else { return }
        if let feedback = DiscussionCorrection.feedback(for: item, correctedOwner: owner) {
            try store.writeAIFeedback(feedback)
        }
        discussionItems = store.loadDiscussionItems()
    }

    func setDiscussionItemCorrection(
        id: Int64,
        content: String,
        owner: DiscussionItemOwner,
        dueAt: Date?
    ) throws {
        guard let item = discussionItems.first(where: { $0.id == id }) else { return }
        guard try store.updateDiscussionItemCorrection(id: id, content: content, owner: owner, dueAt: dueAt) else { return }
        if let feedback = DiscussionCorrection.feedback(for: item, correctedOwner: owner) {
            try store.writeAIFeedback(feedback)
        }
        discussionItems = store.loadDiscussionItems()
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

        // 1b. Cross-group VIP notifications: fire one macOS banner per
        // (vip, group) pair in this batch. A trace is cross-group when
        // the chat is a group AND that group's own whitelist entry is
        // not VIP-attention (if it were, the existing VIP-chat banner
        // path already covers it). Coalesces by batch so three
        // back-to-back messages from the same VIP in the same group
        // produce one notification, not three.
        let whitelistEntries = storeRef.getWhitelist()
        let vipGroupUsernames: Set<String> = Set(
            whitelistEntries
                .filter { $0.attentionLevel == .vip && $0.isGroup }
                .map(\.id)
        )
        var crossGroupBuckets: [String: (vipName: String, vipUsername: String,
                                         groupName: String, groupUsername: String,
                                         firstPreview: String, count: Int,
                                         latestTime: Int)] = [:]
        for trace in outcome.vipTraceMessages {
            guard trace.chatUsername.contains("@chatroom"),
                  !vipGroupUsernames.contains(trace.chatUsername) else { continue }
            let key = "\(trace.vipUsername)|\(trace.chatUsername)"
            if var existing = crossGroupBuckets[key] {
                existing.count += 1
                if trace.msgTime > existing.latestTime {
                    existing.latestTime = trace.msgTime
                    existing.firstPreview = trace.rawText
                }
                crossGroupBuckets[key] = existing
            } else {
                crossGroupBuckets[key] = (
                    vipName: trace.vipName,
                    vipUsername: trace.vipUsername,
                    groupName: trace.chatName,
                    groupUsername: trace.chatUsername,
                    firstPreview: trace.rawText,
                    count: 1,
                    latestTime: trace.msgTime
                )
            }
        }
        if !crossGroupBuckets.isEmpty {
            let engine = alertEngine
            Task { @MainActor in
                for bucket in crossGroupBuckets.values {
                    engine.pushCrossGroupVIPAlert(
                        vipName: bucket.vipName,
                        vipUsername: bucket.vipUsername,
                        groupName: bucket.groupName,
                        groupUsername: bucket.groupUsername,
                        preview: bucket.firstPreview,
                        messageCount: bucket.count
                    )
                }
            }
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

        // 3. Drain durable classification work, including failures from earlier scans.
        drainClassificationQueue()

        // 4. Commitment tracking for self outgoing messages (async)
        if !outcome.selfOutgoingMessages.isEmpty {
            let tracker = commitmentTracker
            let readerRef = reader
            // Resolve names off the main actor: `canonicalDisplayName` reads
            // the reader's contact cache under its own lock.
            let resolveName: (String) -> String? = { [weak self] username in
                self?.canonicalDisplayName(for: username)
            }
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

                    guard result.isCommitment, result.confidence >= 0.72 else { continue }

                    let messageDate = Date(timeIntervalSince1970: Double(item.msg.createTime))
                    let sourceText = result.sourceText.isEmpty
                        ? item.msg.text
                        : result.sourceText
                    let deadline = CommitmentDeadlineResolver.resolve(
                        extracted: result.deadlineExtracted,
                        label: result.deadlineLabel,
                        sourceText: sourceText,
                        messageDate: messageDate
                    )
                    let contextText = result.contextText.isEmpty
                        ? Self.commitmentContextSnapshot(window.messages, targetID: item.msg.id)
                        : result.contextText
                    let deadlineLabel = result.deadlineLabel.isEmpty
                        ? Self.commitmentDeadlineLabel(result.deadlineExtracted, resolved: deadline)
                        : result.deadlineLabel
                    let nextStep = result.nextStep.isEmpty
                        ? "回到「\(item.chatName)」确认并推进：\(result.content)"
                        : result.nextStep
                    let captureReason = result.captureReason.isEmpty
                        ? "你的发言承诺了后续动作"
                        : result.captureReason
                    // The model sometimes echoes the room id when it cannot tell
                    // who the promise was made to; resolve it to the same name
                    // the rest of the UI shows.
                    let commitTo = ContactIdentityIndex.isRawChatIdentifier(result.commitTo)
                        ? (resolveName(result.commitTo) ?? resolveName(item.chatUsername) ?? result.commitTo)
                        : result.commitTo
                    try? storeRef.upsertCommitment(
                        msgUID: item.msg.id,
                        chatUsername: item.chatUsername,
                        chatName: item.chatName,
                        content: result.content,
                        commitTo: commitTo,
                        deadlineAt: deadline,
                        confidence: result.confidence,
                        promptVersion: "commitment_v1",
                        sourceText: sourceText,
                        contextText: contextText,
                        captureReason: captureReason,
                        nextStep: nextStep,
                        deadlineLabel: deadlineLabel,
                        commitmentKind: result.commitmentKind,
                        createdAt: messageDate
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

        // 6. Conversation memory — extracted to ConversationMemoryUpdater
        // (shared with AutopilotService, eliminates duplicate inline logic)
        let memUpdater = memoryUpdater
        Task { await memUpdater.updateStaleMemories() }

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

        // 9. Discussion messages were durably queued by ScanEngine before
        // its source cursor advanced. Drain oldest batches without re-reading
        // a newest-40 window that could skip a burst or an earlier failure.
        resumeDiscussionExtraction()

        // 10. Commitment fulfillment closure.
        //
        // For each pending commitment, look at what the user sent
        // subsequently in the same chat. If there's a "已发 / 搞定 /
        // 完成" keyword or a file/image/link in a commitment that
        // talks about deliverables → auto-mark fulfilled. If the
        // deadline has passed with no evidence → auto-mark overdue.
        //
        // `autoAdvanceCommitmentStatus` protects manual rows. Fulfillment
        // also checks overdue commitments so late "已发/搞定" evidence can
        // recover them.
        let pendingCommitments = commitments.filter { $0.status == .pending || $0.status == .overdue }
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

    func refreshInsightInBackground(force: Bool = false) {
        insightCoordinator.refreshInBackground(force: force)
    }

    func analyzeOneChat(chatUsername: String, date: Date = Date()) async {
        await insightCoordinator.analyzeOneChat(chatUsername: chatUsername, date: date)
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

    /// Source used by the settings scan. Its async scan owns the detached
    /// reader work; the view only receives value-type results and progress.
    func contactRecommendationScanSource() -> ContactRecommendationScanSource {
        ContactRecommendationScanSource(reader: reader)
    }

    /// Throwing candidate read for settings and diagnostics. The legacy
    /// `scanCandidates` wrapper below intentionally keeps its empty fallback
    /// for existing callers.
    func scanCandidatesThrowing(limit: Int = 50) throws -> [ScanCandidate] {
        let whitelisted = Set(store.loadContacts(level: nil).map(\.username))
        let dismissed = store.dismissedScanUsernames()
        let excluded = whitelisted.union(dismissed)
        return try contactRecommendationScanSource()
            .loadCandidates(limit: limit, excluding: excluded)
            .map { ScanCandidate(
                username: $0.username,
                displayName: $0.displayName,
                isGroup: $0.isGroup,
                recentCount: $0.recentCount
            ) }
    }

    func scanCandidates(limit: Int = 50) -> [ScanCandidate] {
        (try? scanCandidatesThrowing(limit: limit)) ?? []
    }

    /// Load recent messages for a chat as (sender, body) tuples — used by
    /// WhitelistScanView to give the AI categorizer real content.
    func recentMessagesThrowing(chatUsername: String, limit: Int = 20) throws -> [(sender: String, body: String)] {
        try contactRecommendationScanSource()
            .readMessages(chatUsername: chatUsername, limit: limit)
            .map { (sender: $0.sender, body: $0.body) }
    }

    func recentMessages(chatUsername: String, limit: Int = 20) -> [(sender: String, body: String)] {
        (try? recentMessagesThrowing(chatUsername: chatUsername, limit: limit)) ?? []
    }

    /// Last message in `chatUsername` that did NOT come from the user.
    /// Used when appending a manual send to the autopilot session ledger
    /// so the model knows what the reply was responding to. Returns nil
    /// if the reader can't be read or no peer message is found in the
    /// recent window.
    func lastPeerMessage(chatUsername: String, limit: Int = 15) -> String? {
        guard let msgs = try? reader.getMessages(chatUsername: chatUsername, limit: limit, sinceLocalId: nil) else {
            return nil
        }
        let myUname = reader.myUsername()
        let myDisplay = reader.displayName(for: myUname)
        let selfNames = reader.mySelfNames
        // getMessages returns newest-first; find the first peer message.
        for msg in msgs {
            let fromSelf = MessageHelpers.isFromSelf(
                msg, chatUsername: chatUsername,
                myUsername: myUname,
                myDisplayName: myDisplay,
                mySelfNames: selfNames
            )
            if !fromSelf {
                let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// All WeChat contacts (username → displayName) from the encrypted DB.
    func wechatContacts() -> [String: String] {
        // The contacts UI may open before or long after the first scan; an
        // empty cache must not be presented as "there are no contacts".
        _ = try? reader.refreshContactsIfChanged()
        let contacts = reader.allContacts()
        print("[WCHUD] wechatContacts dbDir=\(reader.dbDir) count=\(contacts.count)")
        return contacts
    }

    /// Fallback source when the contact index is unavailable. Real sessions
    /// still identify active private chats; this avoids blocking setup while
    /// preserving explicit user selection.
    struct ActiveChatCandidate: Identifiable, Equatable {
        let username: String
        let displayName: String
        let unreadCount: Int
        let lastTimestamp: Int
        var id: String { username }
    }

    func activePrivateChatCandidates(limit: Int = 500) -> [ActiveChatCandidate] {
        guard !PreviewRuntime.isEnabled, !reader.dbDir.isEmpty, !reader.hasAccountSwitched() else { return [] }
        let sessions = (try? reader.getSessions()) ?? []
        let excluded = Set(store.loadContacts(level: nil).map(\.username))
            .union(store.dismissedScanUsernames())
        let noisePrefixes: Set<String> = ["gh_", "fmessage", "medianote", "newsapp", "notification_", "notifymessage",
                                          "floatbottle", "qqmail", "brandsessionholder", "masssend", "officialaccounts", "tmessage"]
        let noiseExact: Set<String> = ["weixin", "filehelper", "voip", "voipapp", "qqsync", "qqsafe", "facebook", "feedsapp"]
        return sessions
            .filter { !$0.isGroup }
            .filter { !excluded.contains($0.username) }
            .filter { !$0.username.contains("@openim") && !$0.username.contains("@im.chatroom") }
            .filter { !noiseExact.contains($0.username) && !noisePrefixes.contains(where: $0.username.hasPrefix) }
            .sorted { $0.lastTimestamp != $1.lastTimestamp ? $0.lastTimestamp > $1.lastTimestamp : $0.username < $1.username }
            .prefix(max(0, limit))
            .map { ActiveChatCandidate(
                username: $0.username,
                displayName: reader.displayName(for: $0.username),
                unreadCount: $0.unreadCount,
                lastTimestamp: $0.lastTimestamp
            ) }
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
            progress(i + 1, contacts.count)
            let result = await inferRelationship(contactUsername: contact.username, contactName: contact.displayName)
            if result != nil { count += 1 }
        }
        return count
    }

    /// Start relationship profile inference as a monitor-owned background job.
    /// The contacts UI only observes `contactInferenceStatus`, so users can
    /// keep editing or switch tabs while AI calls continue.
    func startContactInference(contacts: [ContactEntry]) {
        guard contactInferenceStatus?.isRunning != true else { return }
        let candidates = contacts.filter { $0.attentionLevel != .stranger }
        guard !candidates.isEmpty else {
            contactInferenceStatus = ContactInferenceStatus(total: 0, completed: 0, succeeded: 0, isRunning: false)
            return
        }

        contactInferenceStatus = ContactInferenceStatus(total: candidates.count, completed: 0, succeeded: 0, isRunning: true)
        contactInferenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = 0
            for (index, contact) in candidates.enumerated() {
                if Task.isCancelled { break }
                self.contactInferenceStatus = ContactInferenceStatus(
                    total: candidates.count,
                    completed: index,
                    succeeded: succeeded,
                    isRunning: true
                )
                let result = await self.inferRelationship(
                    contactUsername: contact.username,
                    contactName: contact.displayName
                )
                if result != nil { succeeded += 1 }
                self.contactInferenceStatus = ContactInferenceStatus(
                    total: candidates.count,
                    completed: index + 1,
                    succeeded: succeeded,
                    isRunning: true
                )
            }
            self.contactInferenceStatus = ContactInferenceStatus(
                total: candidates.count,
                completed: self.contactInferenceStatus?.completed ?? candidates.count,
                succeeded: succeeded,
                isRunning: false
            )
            self.contactInferenceTask = nil
        }
    }

    func cancelContactInference() {
        contactInferenceTask?.cancel()
        contactInferenceTask = nil
        if let status = contactInferenceStatus {
            contactInferenceStatus = ContactInferenceStatus(
                total: status.total,
                completed: status.completed,
                succeeded: status.succeeded,
                isRunning: false
            )
        }
    }

    /// Save a reply draft for later sending.
    func saveDraft(chatUsername: String, chatName: String, text: String, replacingDraftID: Int64? = nil) throws {
        if let replacingDraftID {
            try store.updateDraft(id: replacingDraftID, chatUsername: chatUsername, text: text)
        } else {
            try store.saveDraft(chatUsername: chatUsername, chatName: chatName, text: text, sendAt: nil)
        }
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

    func sendAutopilotNow(id: UUID, config: AutopilotConfig) async -> AutopilotService.ManualSendOutcome {
        guard let service = autopilotService else { return .notFound }
        let outcome = await service.sendNow(id: id, config: config)
        await refreshAutopilotLiveState()
        refreshAutopilotSessionState()
        return outcome
    }

    func editAndSendAutopilot(id: UUID, newText: String, config: AutopilotConfig) async -> AutopilotService.ManualSendOutcome {
        guard let service = autopilotService else { return .notFound }
        let outcome = await service.editAndSend(id: id, newText: newText, config: config)
        await refreshAutopilotLiveState()
        refreshAutopilotSessionState()
        return outcome
    }

    private func refreshAutopilotLiveState() async {
        guard let service = autopilotService else { return }
        autopilotPendingSendQueue = await service.pendingSendQueue
        autopilotSessionStats = await service.sessionStats
        autopilotManuallyPaused = await service.manuallyPaused
    }

    /// Compute relationship strength score (0-100) for a contact.
    func relationshipStrength(chatUsername: String) -> RelationshipStrength {
        let trend = chatTrend(chatUsername: chatUsername)
        let totalMessages = trend.reduce(0) { $0 + $1.count }
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
    /// Update a commitment's status and refresh the published list.
    func updateCommitmentStatus(msgUID: String, status: CommitmentStatus) throws {
        try store.updateCommitmentStatus(msgUID: msgUID, status: status)
        commitments = store.loadCommitments()
    }

    private static func commitmentContextSnapshot(_ messages: [AnnotatedMessage], targetID: String) -> String {
        let before = messages
            .filter { !$0.isTarget && $0.id != targetID && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
        let lines = before.map { msg in
            let text = AIService.sanitizeForAI(msg.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(msg.senderName): \(text)"
        }
        return lines.joined(separator: " / ")
    }

    private static func commitmentDeadlineLabel(_ extracted: String, resolved: Date?) -> String {
        let normalized = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "none" {
            return resolved == nil ? "无明确时间" : "有时间，待确认"
        }
        switch normalized {
        case "tomorrow": return "明天前"
        case "vague_soon": return "尽快/稍后"
        case "inherit": return "沿用上文时间"
        default: return normalized
        }
    }

    /// Manual retry bypasses persisted and in-memory backoff, but retains all
    /// source messages and still rechecks the current whitelist before sending.
    func retryDiscussionExtraction() throws {
        try store.retryDiscussionMessages()
        let tracker = discussionTracker
        Task { @MainActor [weak self] in
            await tracker.resetRetryBackoff()
            self?.resumeDiscussionExtraction()
        }
    }

    /// Retry durable discussion work even when WeChat has no new messages.
    /// One worker owns a bounded run; the next timer tick handles remaining work.
    private func resumeDiscussionExtraction() {
        guard !PreviewRuntime.isEnabled else { return }
        if let count = try? store.discussionQueueCount() { discussionPendingCount = count }
        guard discussionWorker == nil, discussionPendingCount > 0,
              !reader.dbDir.isEmpty, !reader.hasAccountSwitched() else { return }
        let tracker = discussionTracker
        let username = reader.myUsername()
        guard !username.isEmpty else { return }
        let displayName = reader.displayName(for: username)
        let names = reader.mySelfNames
        let generation = UUID()
        discussionWorkerGeneration = generation
        discussionProcessing = true
        discussionWorker = Task { @MainActor [weak self] in
            let inserted = await tracker.resumePending(myUsername: username, myDisplayName: displayName, mySelfNames: names)
            guard let self, self.discussionWorkerGeneration == generation else { return }
            self.discussionWorker = nil
            self.discussionProcessing = false
            if let count = try? self.store.discussionQueueCount() { self.discussionPendingCount = count }
            if inserted > 0 { self.discussionItems = self.store.loadDiscussionItems() }
        }
    }

    /// Load pending asks for a specific chat. Used by Person Profile card.
    func pendingAsksForChat(_ chatUsername: String) -> [PendingAsk] {
        Array(store.loadPendingAsks(status: .pending)
            .filter { $0.chatUsername == chatUsername }
            .prefix(3))
    }

    func pendingAsks() -> [PendingAsk] {
        store.loadPendingAsks(status: .pending)
    }

    /// Refresh the reply suggester's config from the settings DB.
    /// Called by AppDelegate when the user changes AI settings.
    func refreshReplySuggesterConfig() async {
        let cfg = store.loadAIConfig()
        await relationshipInferrer.updateConfig(cfg)
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

    /// Dismiss an inbox item only after its watermark is persisted. Newer
    /// messages remain eligible to surface normally.
    @discardableResult
    func dismissInboxItem(_ item: InboxItem) -> Bool {
        let ts = Int(item.timestamp.timeIntervalSince1970)
        do {
            try store.silenceChat(chatUsername: item.chatUsername, silencedAt: ts)
            dismissedInbox[item.chatUsername] = Int64(ts)
            inboxActionError = nil
            rebuildInbox()
            return true
        } catch {
            inboxActionError = "未能保存已处理状态，消息仍保持原状态。请重试。"
            return false
        }
    }

    /// Persist before changing the visible queue; a failed write must not
    /// promise a future reminder that was never scheduled.
    @discardableResult
    func snoozeInboxItem(_ item: InboxItem, until: Date) -> Bool {
        let untilEpoch = Int(until.timeIntervalSince1970)
        do {
            try store.snoozeChat(chatUsername: item.chatUsername, until: untilEpoch)
            snoozedInbox[item.chatUsername] = Date(timeIntervalSince1970: TimeInterval(untilEpoch))
            silencedInbox.remove(item.chatUsername)
            inboxActionError = nil
            rebuildInbox()
            return true
        } catch {
            inboxActionError = "未能保存稍后提醒，消息仍保持原状态。请重试。"
            return false
        }
    }

    /// Silence a chat with the existing far-future watermark representation.
    @discardableResult
    func silenceInboxItem(_ item: InboxItem) -> Bool {
        let farFuture = Int(Date().timeIntervalSince1970) + 315_360_000
        do {
            try store.silenceChat(chatUsername: item.chatUsername, silencedAt: farFuture)
            silencedInbox.insert(item.chatUsername)
            snoozedInbox.removeValue(forKey: item.chatUsername)
            inboxActionError = nil
            rebuildInbox()
            return true
        } catch {
            inboxActionError = "未能保存静默状态，消息仍保持原状态。请重试。"
            return false
        }
    }

    /// Restore all suppression state atomically with the existing single-row
    /// delete. Do not show an item as active if that delete fails.
    @discardableResult
    func restoreInboxItem(_ item: InboxItem) -> Bool {
        do {
            try store.clearChatAction(chatUsername: item.chatUsername)
            dismissedInbox.removeValue(forKey: item.chatUsername)
            snoozedInbox.removeValue(forKey: item.chatUsername)
            silencedInbox.remove(item.chatUsername)
            inboxActionError = nil
            rebuildInbox()
            return true
        } catch {
            inboxActionError = "未能恢复这条消息，原处理状态仍保留。请重试。"
            return false
        }
    }

    /// The persisted operation removes the entire action row, so clear every
    /// corresponding in-memory suppression flag as well.
    @discardableResult
    func unsilenceInboxItem(_ item: InboxItem) -> Bool {
        restoreInboxItem(item)
    }

    /// Rebuild the inbox from current state. Used by all inbox mutation methods.
    func rebuildInbox() {
        let result = InboxBuilder.build(
            replyDebtItems: replyDebtItems,
            notifications: recentNotifications,
            dismissed: dismissedInbox,
            snoozed: snoozedInbox,
            silenced: silencedInbox
        )
        inboxItems = result.active
        handledItems = result.handled

        // Apply cached AI summaries. This reads both the in-memory
        // hot cache and the persistent analysis cache, so ordinary
        // updates don't fall back to raw previews after app restart.
        applyCachedInboxSummaries(to: &inboxItems)
        applyCachedInboxSummaries(to: &handledItems)

        // Prune stale cache entries
        cleanSummaryCache()
    }

    /// Re-evaluate time-based snoozes independently of message scans. This
    /// lets a snoozed item reappear when its deadline passes even if WeChat is
    /// closed or its databases remain unchanged.
    ///
    /// `now` is injectable so expiry behavior can be tested without sleeping.
    func refreshExpiredSnoozes(now: Date = Date()) {
        let expired = snoozedInbox.compactMap { username, expiry in
            expiry <= now ? username : nil
        }
        guard !expired.isEmpty else { return }
        for username in expired {
            snoozedInbox.removeValue(forKey: username)
        }
        rebuildInbox()
    }

    /// Generate reply suggestions for a reply debt item.
    func loadReplySuggestions(for item: ReplyDebtItem) async -> [AIReplySuggester.Suggestion] {
        // Fetch style profile to make suggestions match user's writing style
        let style = await styleProfiler.getProfile(chatUsername: item.chatUsername)
        let profile = store.getRelationshipProfile(username: item.chatUsername)
        let pendingAsk = store.loadPendingAsks(status: .pending)
            .first { $0.chatUsername == item.chatUsername }
        let context = buildReplySuggestionContext(for: item, pendingAsk: pendingAsk)

        let input = AIReplySuggester.Input(
            messageBody: item.preview,
            senderName: item.senderName,
            chatName: item.chatName,
            isGroup: item.isGroup,
            askType: pendingAsk?.askType ?? .none,
            relationship: profile.map { "\($0.relationship) (\($0.hierarchy.rawValue)/\($0.hierarchy.label))" } ?? "unknown",
            styleHint: buildRichStyleHint(style) ?? buildStyleHint(style),
            feedbackContext: buildFeedbackHint(),
            contextWindow: context.contextWindow,
            myLastReply: context.myLastReply,
            analysisSummary: context.analysisSummary,
            relationshipHierarchy: profile?.hierarchy.rawValue,
            tonePreference: profile?.tonePreference.rawValue,
            knownConstraints: context.knownConstraints
        )
        return await replySuggester.suggest(input) ?? []
    }

    /// Build the "用户采纳了 X/Y 条建议" hint from persisted AI feedback.
    /// Extracted so both reply-suggestion entry points (ReplyDebt and
    /// InboxItem) share the same learning signal — otherwise one path
    /// gets smarter with use and the other stays frozen.
    func buildFeedbackHint() -> String? {
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
        let items = InboxPresentationPolicy.summaryCandidates(inboxItems)
            .filter { $0.aiSummary == nil }
        guard !items.isEmpty else { return }

        // Sort by priority — P0 summaries first, then newest visible
        // rows. Passive rows are capped by InboxPresentationPolicy so
        // a noisy group list cannot fan out dozens of AI calls.
        let sorted = items.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.timestamp > $1.timestamp
        }

        let readerRef = reader
        let storeRef = store
        let summarizer = inboxSummarizer

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for item in sorted {
                let cacheKey = item.generationKey
                let sourceNotification = item.contextNotification.flatMap { notification in
                    notification.kind == .groupAt ? notification : nil
                }
                // Validate a group @ source before consulting cache; an old
                // summary must not survive after its triggering row vanished.
                let sourceCentered: [MessageInfo]?
                if let sourceNotification {
                    sourceCentered = GroupContextSourceLoader.load(
                        notification: sourceNotification, reader: readerRef
                    )
                    guard sourceCentered != nil else { continue }
                } else {
                    sourceCentered = nil
                }
                // Check cache after source validation.
                if let cached = self.loadCachedInboxSummary(for: item) {
                    self.updateItemSummary(generationKey: item.generationKey, summary: cached)
                    continue
                }
                guard !self.summaryInFlight.contains(cacheKey) else { continue }
                self.summaryInFlight.insert(cacheKey)
                defer { self.summaryInFlight.remove(cacheKey) }

                let myUname = readerRef.myUsername()
                let myDisplay = readerRef.displayName(for: myUname)
                let mySelfNames = readerRef.mySelfNames
                // Private/debt rows retain the historical latest-inbound
                // behavior below. Group @ rows take the exact source branch
                // first, so later chatter cannot replace the trigger.
                let msgs: [MessageInfo]
                if let sourceNotification {
                    // Group @ summaries must stay anchored to the notification
                    // source. If it is no longer readable, do not summarize a
                    // different message and attach it to this row.
                    guard let centered = sourceCentered,
                          let trigger = centered.first(where: {
                              $0.id == sourceNotification.messageID &&
                              $0.chatUsername == sourceNotification.chatUsername
                          }) else {
                        continue
                    }
                    msgs = centered
                    let context = InboxContextBuilder.build(
                        chatUsername: item.chatUsername,
                        triggerMessage: trigger,
                        reader: readerRef,
                        store: storeRef,
                        myUsername: myUname,
                        contactEntry: storeRef.getContact(username: item.chatUsername),
                        whitelistEntry: storeRef.getWhitelistEntry(username: item.chatUsername),
                        sourceContextMessages: centered
                    )
                    let summary = await summarizer.summarize(context)
                    guard let summary,
                          self.inboxItems.contains(where: { $0.generationKey == item.generationKey }) else { continue }
                    self.cacheAndUpdateInboxSummary(summary, for: item)
                    continue
                } else {
                    msgs = (try? readerRef.getMessages(chatUsername: item.chatUsername, limit: 50)) ?? []
                }
                let cutoff48h = Date().addingTimeInterval(-48 * 3600)
                let filtered = msgs.filter { msg in
                    let inWindow = Date(timeIntervalSince1970: Double(msg.createTime)) >= cutoff48h
                    let isSelf = MessageHelpers.isFromSelf(
                        msg,
                        chatUsername: item.chatUsername,
                        myUsername: myUname,
                        myDisplayName: myDisplay,
                        mySelfNames: mySelfNames
                    )
                    return inWindow
                        && !isSelf
                        && MessageHelpers.isReadableAIContent(msg.text, allowMediaPlaceholder: true)
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
                guard self.inboxItems.contains(where: {
                    $0.generationKey == item.generationKey
                }) else { continue }

                // Cache + update UI
                self.cacheAndUpdateInboxSummary(summary, for: item)
            }
        }
    }

    private func applyCachedInboxSummaries(to items: inout [InboxItem]) {
        for i in items.indices {
            guard items[i].aiSummary == nil,
                  let cached = loadCachedInboxSummary(for: items[i]) else { continue }
            items[i].aiSummary = cached
        }
    }

    private func loadCachedInboxSummary(for item: InboxItem) -> String? {
        let key = item.generationKey
        if let cached = summaryCache[key], !cached.isEmpty {
            return cached
        }
        guard let cached = store.loadAnalysisCache(
            chatUsername: item.chatUsername,
            analysisType: inboxSummaryAnalysisType,
            inputHash: key
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cached.isEmpty else {
            return nil
        }
        summaryCache[key] = cached
        return cached
    }

    func cacheAndUpdateInboxSummary(_ summary: String, for item: InboxItem) {
        let cleaned = trimInboxSummary(summary)
        guard !cleaned.isEmpty else { return }
        let key = item.generationKey
        summaryCache[key] = cleaned
        try? store.writeAnalysisCache(
            chatUsername: item.chatUsername,
            analysisType: inboxSummaryAnalysisType,
            inputHash: key,
            result: cleaned,
            ttlHours: 72
        )
        updateItemSummary(generationKey: key, summary: cleaned)
    }

    func trimInboxSummary(_ value: String, limit: Int = 25) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(limit))
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
        let items = inboxItems.filter { $0.participatesInActionQueue }
        guard !items.isEmpty else { return }
        let latestTimestampByChat = items.reduce(into: [String: Int]()) { result, item in
            let ts = Int(item.timestamp.timeIntervalSince1970)
            result[item.chatUsername] = max(result[item.chatUsername] ?? ts, ts)
        }

        for item in items {
            let ts = Int(item.timestamp.timeIntervalSince1970)
            guard latestTimestampByChat[item.chatUsername] == ts else {
                continue
            }
            // Skip if we already have a fully-materialized entry
            // for this exact trigger generation.
            if let existing = actionPrefetch[item.chatUsername],
               existing.generationKey == item.generationKey {
                continue
            }
            if let existing = actionPrefetch[item.chatUsername],
               existing.timestamp > ts {
                continue
            }

            let chatUsername = item.chatUsername
            let captured = item  // for Task capture
            let hasProfile = hasRelationshipProfile(for: chatUsername)

            // Claim the slot immediately so a user click during the
            // prefetch round-trip can render loading state instead of
            // launching duplicate on-demand AI calls.
            mergeActionPrefetch(
                chatUsername: chatUsername,
                ts: ts,
                generationKey: captured.generationKey,
                groupAnalysis: nil,
                privateAnalysis: nil,
                analysisError: nil,
                replies: nil,
                hasProfile: hasProfile,
                markAnalysisAttempted: false,
                markRepliesAttempted: false
            )

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
                var analysisError: String?
                if captured.isGroup {
                    let (result, err) = await self.analyzeGroupChat(item: captured)
                    group = result
                    analysisError = err
                    if result == nil {
                        print("[WCHUD] prefetch: analyzeGroupChat nil for '\(captured.chatName)' err=\(err ?? "none")")
                    }
                } else {
                    let (result, err) = await self.analyzePrivateChat(item: captured)
                    priv = result
                    analysisError = err
                    if result == nil {
                        print("[WCHUD] prefetch: analyzePrivateChat nil for '\(captured.chatName)' err=\(err ?? "none")")
                    }
                }
                guard self.isItemStillCurrent(generationKey: captured.generationKey) else { return }
                self.mergeActionPrefetch(
                    chatUsername: chatUsername,
                    ts: ts,
                    generationKey: captured.generationKey,
                    groupAnalysis: group,
                    privateAnalysis: priv,
                    analysisError: analysisError,
                    replies: nil,
                    hasProfile: hasProfile,
                    markAnalysisAttempted: true,
                    markRepliesAttempted: false
                )
            }

            if captured.automaticReplySuggestionsAllowed {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let replies = (await self.loadReplySuggestions(for: captured)) ?? []
                    guard self.isItemStillCurrent(generationKey: captured.generationKey) else { return }
                    self.mergeActionPrefetch(
                        chatUsername: chatUsername,
                        ts: ts,
                        generationKey: captured.generationKey,
                        groupAnalysis: nil,
                        privateAnalysis: nil,
                        analysisError: nil,
                        replies: replies,
                        hasProfile: hasProfile,
                        markAnalysisAttempted: false,
                        markRepliesAttempted: true
                    )
                }
            } else {
                // No automatic reply path for manual/hidden states.
                // Mark attempted immediately so UI does not wait on a
                // task that will not run.
                mergeActionPrefetch(
                    chatUsername: chatUsername,
                    ts: ts,
                    generationKey: captured.generationKey,
                    groupAnalysis: nil,
                    privateAnalysis: nil,
                    analysisError: nil,
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
    private func isItemStillCurrent(generationKey: String) -> Bool {
        inboxItems.contains { $0.generationKey == generationKey }
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
        generationKey: String,
        groupAnalysis: ChatAnalyzer.GroupAnalysis?,
        privateAnalysis: ChatAnalyzer.PrivateAnalysis?,
        analysisError: String?,
        replies: [SuggestedReply]?,
        hasProfile: Bool,
        markAnalysisAttempted: Bool,
        markRepliesAttempted: Bool
    ) {
        let existing = actionPrefetch[chatUsername]
        if let existing, existing.timestamp > ts {
            return
        }
        let sameGeneration = existing?.generationKey == generationKey
        actionPrefetch[chatUsername] = PrefetchedAction(
            timestamp: ts,
            generationKey: generationKey,
            groupAnalysis: groupAnalysis ?? (sameGeneration ? existing?.groupAnalysis : nil),
            privateAnalysis: privateAnalysis ?? (sameGeneration ? existing?.privateAnalysis : nil),
            analysisError: analysisError ?? (sameGeneration ? existing?.analysisError : nil),
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
    private func updateItemSummary(generationKey: String, summary: String) {
        if let idx = inboxItems.firstIndex(where: { $0.generationKey == generationKey }) {
            inboxItems[idx].aiSummary = summary
            return
        }
        if let idx = handledItems.firstIndex(where: { $0.generationKey == generationKey }) {
            handledItems[idx].aiSummary = summary
        }
    }

    /// Clean summary cache entries not matching any current inbox or
    /// handled item. Without keeping handled items in the live set,
    /// restoring a dismissed row would force re-summarization — we
    /// keep them cached as long as the row is still visible somewhere.
    private func cleanSummaryCache() {
        let activeKeys = Set(inboxItems.map(\.generationKey)).union(handledItems.map(\.generationKey))
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
            autopilotService = AutopilotService(
                store: store,
                reader: reader,
                aiService: aiService,
                ledgerRead: { [weak self] chatUsername in
                    self?.autopilotSessionLedger[chatUsername] ?? []
                },
                ledgerWrite: { [weak self] chatUsername, text, peerLastMessage, topic in
                    self?.appendLedgerEntry(
                        LedgerEntry(
                            timestamp: Date(),
                            outgoingText: text,
                            peerLastMessage: peerLastMessage,
                            topic: topic
                        ),
                        for: chatUsername
                    )
                }
            )
        }
        let service = autopilotService
        // Clear any stale ledger entries from a previous session before
        // flipping the active flag, so observers never see fresh-active
        // state with stale entries.
        resetSessionLedger()
        Task {
            do {
                try await service?.start()
                let recoveredQueue = await service?.pendingSendQueue ?? []
                let recoveredStats = await service?.sessionStats ?? AutopilotService.SessionStats()
                await MainActor.run {
                    self.autopilotActive = true
                    self.autopilotSessionSent = recoveredStats.totalSent
                    self.autopilotSessionPending = recoveredStats.totalPending
                    self.autopilotPendingSendQueue = recoveredQueue
                    self.autopilotSessionStats = recoveredStats
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
        // Drop ledger entries after marking inactive — anything accumulated
        // while autopilot was off-by-a-hair shouldn't leak into the next
        // session.
        resetSessionLedger()
        print("[WCHUD] Autopilot: OFF")
    }

    /// Append one verified outgoing message to the session ledger for
    /// `chatUsername`. Caps the per-chat list at 20 entries (FIFO).
    /// Safe to call from any context on @MainActor.
    func appendLedgerEntry(_ entry: LedgerEntry, for chatUsername: String) {
        autopilotSessionLedger = Self.ledgerByAppending(
            entry, to: autopilotSessionLedger, for: chatUsername
        )
    }

    /// Clear the entire session ledger across all chats. Called when
    /// autopilot starts or stops.
    func resetSessionLedger() {
        autopilotSessionLedger = [:]
    }

    /// Pure function exposed for tests. Returns the ledger dictionary
    /// with `entry` appended under `chatUsername`, capped at 20 entries
    /// per chat (FIFO — oldest evicted first).
    nonisolated static func ledgerByAppending(
        _ entry: LedgerEntry,
        to ledger: [String: [LedgerEntry]],
        for chatUsername: String
    ) -> [String: [LedgerEntry]] {
        var next = ledger
        var list = next[chatUsername] ?? []
        list.append(entry)
        if list.count > 20 {
            list.removeFirst(list.count - 20)
        }
        next[chatUsername] = list
        return next
    }

    /// Pure-function counterpart to `resetSessionLedger()`. Always
    /// returns an empty dictionary. Kept as a separate helper so tests
    /// can assert the exact cleared shape without touching live state.
    nonisolated static func ledgerByResetting(_ ledger: [String: [LedgerEntry]]) -> [String: [LedgerEntry]] {
        [:]
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
