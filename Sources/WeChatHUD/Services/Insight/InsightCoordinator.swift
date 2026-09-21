import Foundation
import Combine

/// Coordinates all insight-related operations: scheduling stats loading, running AI analysis,
/// generating global briefings, and managing the insight lifecycle.
///
/// Data preparation is delegated to `ChatInsightService`.
@MainActor
final class InsightCoordinator: ObservableObject {
    // MARK: - Published State

    /// AI-suggested chat insight results keyed by chatUsername.
    @Published var chatInsights: [String: ChatInsightResult] = [:]
    /// Per-chat insight jobs currently running.
    @Published var chatInsightLoading: Set<String> = []
    /// Per-chat insight error messages.
    @Published var chatInsightErrors: [String: String] = [:]
    /// Global briefing across all whitelisted chats.
    @Published var globalBriefing: GlobalBriefing? = nil
    /// When `globalBriefing` was produced, by our own clock.
    ///
    /// `briefing.date` is the model's free-text 「日期」 field — the prompt asks
    /// for a date, not a timestamp, and the model echoes back whatever it
    /// likes. The freshness check used to parse that string as ISO8601, get
    /// `nil`, fall back to `.distantPast`, and therefore treat *every* briefing
    /// as infinitely old: a full AI batch over the whole whitelist re-ran on
    /// every scan. Freshness is a local fact, so it is recorded locally.
    private(set) var briefingGeneratedAt: Date?
    /// True while insight analysis is running.
    @Published var insightLoading: Bool = false
    /// Insight progress: "正在分析 3/12…"
    @Published var insightProgress: String = ""
    /// Insight progress fraction 0-1
   @Published var insightProgressFraction: Double = 0

    /// Bulk briefing failed because the follow list could not be read.
    /// Distinct from an empty whitelist: that one means nobody is followed.
    @Published var briefingError: String?

    // MARK: - Dependencies

    private var requestVersions: [String: UUID] = [:]
    private var resultDays: [String: Date] = [:]

    /// A briefing stays useful for this long; past it, the next refresh
    /// regenerates. See `briefingGeneratedAt`.
    static let briefingTTL: TimeInterval = 1800

    private let readerActor: WeChatReaderActor
    private let store: HUDStore
    private let aiService: AIService
    private let now: () -> Date
    private lazy var chatInsightService: ChatInsightService = {
        ChatInsightService(readerActor: readerActor, store: store, aiService: aiService)
    }()

    /// Insight load task — kept so we can cancel and avoid duplicates.
    private var insightLoadTask: Task<Void, Never>?

    init(reader: WeChatReader, store: HUDStore, aiService: AIService, now: @escaping () -> Date = Date.init) {
        self.readerActor = WeChatReaderActor(reader)
        self.store = store
        self.aiService = aiService
        self.now = now
    }

    deinit {
        insightLoadTask?.cancel()
    }

    // MARK: - Public API

    /// Whether a scheduled refresh may be skipped because the current briefing
    /// is still fresh.
    ///
    /// A briefing with no recorded generation time is treated as expired, not
    /// as infinitely old-and-fresh: the old code reached the same conclusion by
    /// parsing the model's free-text date and falling back to `.distantPast`,
    /// which made every briefing look stale and re-ran the whole AI batch on
    /// every scan.
    nonisolated static func shouldSkipBriefingRefresh(
        force: Bool,
        briefing: GlobalBriefing?,
        generatedAt: Date?,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard !force, briefing != nil, let generatedAt else { return false }
        return now.timeIntervalSince(generatedAt) < ttl
    }

    /// Trigger a background insight refresh. Idempotent — if one is already
    /// running, the call is ignored.
    func refreshInBackground(force: Bool = false) {
        guard insightLoadTask == nil else { return }
        insightLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadInsight(force: force)
            self.insightLoadTask = nil
        }
    }

    /// Analyze a single chat on-demand for a specific date.
    /// If a result for a different date exists, it is replaced.
   func analyzeOneChat(chatUsername: String, date: Date = Date()) async {
       let request = UUID()
       requestVersions[chatUsername] = request

       let entry: WhitelistEntry
       switch store.whitelistEntryRead(chatUsername) {
       case .value(let found):
           entry = found
       case .unreadable:
           chatInsightErrors[chatUsername] = CompanionInteractionCopy.followListUnreadableAnalysis
           return
       case .absent:
           chatInsightErrors[chatUsername] = CompanionInteractionCopy.notOnFollowList
           return
       }

        // Only the real analysis job is a busy state. A follow-list miss
        // used to insert loading first, which painted the header as a
        // filled 「正在分析…」 for a frame before snapping back to 「再试一次」.
        chatInsightLoading.insert(chatUsername)
        chatInsightErrors[chatUsername] = nil
        insightProgress = "正在分析单聊…"
        defer {
            if requestVersions[chatUsername] == request {
                chatInsightLoading.remove(chatUsername)
                if !insightLoading { insightProgress = "" }
            }
        }

       let selfUsername = await readerActor.myUsername()
        let selfDisplayName = await readerActor.displayName(for: selfUsername)

        guard let result = await chatInsightService.analyzeEntry(
            entry, date: date,
            selfUsername: selfUsername, selfDisplayName: selfDisplayName
        ) else {
            guard requestVersions[chatUsername] == request else { return }
            chatInsightErrors[chatUsername] = "该日期没有可分析内容，或 AI 暂时不可用"
            return
        }

        guard requestVersions[chatUsername] == request, !Task.isCancelled else { return }
        resultDays[chatUsername] = Calendar.current.startOfDay(for: date)
       chatInsights[chatUsername] = result
   }

    /// Date picker changes must not wipe a previous day's result just to
    /// reprint the same follow-list error. Re-read the list; only start a
    /// real analysis when the chat is still followed.
   func analyzeOneChatOnDateChange(chatUsername: String, date: Date) async {
       await analyzeOneChatIfFollowed(chatUsername: chatUsername, date: date)
   }

    /// Sidebar taps share the date-change gate. An unreadable follow list
    /// is not 「this chat has no analysis」 — stamp the error and leave any
    /// existing result in place.
    func analyzeOneChatIfFollowed(chatUsername: String, date: Date) async {
        switch store.whitelistEntryRead(chatUsername) {
        case .unreadable:
            chatInsightErrors[chatUsername] = CompanionInteractionCopy.followListUnreadableAnalysis
            return
        case .absent:
            chatInsightErrors[chatUsername] = CompanionInteractionCopy.notOnFollowList
            return
        case .value:
            break
        }
       await analyzeOneChat(chatUsername: chatUsername, date: date)
   }

    /// Coming back from 关注谁: if this chat is now followed and still has no
    /// result, start analysis. A leftover 「不在关注列表中」 must not sit there
    /// after the user did what the button asked.
    func resumeInsightChatIfNeeded(chatUsername: String, date: Date) async {
        if result(for: chatUsername, date: date) != nil { return }
        await analyzeOneChatIfFollowed(chatUsername: chatUsername, date: date)
    }

 func seedPreviewResult(chatUsername: String, date: Date = Date(), result: ChatInsightResult) {
        resultDays[chatUsername] = Calendar.current.startOfDay(for: date)
        chatInsights[chatUsername] = result
    }

    func result(for chatUsername: String, date: Date) -> ChatInsightResult? {
        let resultDay = resultDays[chatUsername] ?? Calendar.current.startOfDay(for: Date())
        guard Calendar.current.isDate(resultDay, inSameDayAs: date) else { return nil }
        return chatInsights[chatUsername]
    }

    // MARK: - Full Insight Load

    /// Full insight load with progress reporting.
    private func loadInsight(force: Bool = false) async {
        guard !insightLoading else { return }

        // Cache check: skip while the current briefing is still fresh.
        if Self.shouldSkipBriefingRefresh(
            force: force, briefing: globalBriefing,
            generatedAt: briefingGeneratedAt, now: now(), ttl: Self.briefingTTL
        ) {
            return
        }

       insightLoading = true
       insightProgress = "正在准备…"
       insightProgressFraction = 0

        let whitelist: [WhitelistEntry]
        switch store.whitelistAllRead() {
        case .unreadable:
            insightLoading = false
            insightProgress = ""
            briefingError = CompanionInteractionCopy.followListUnreadableAnalysis
            return
        case .value(let entries):
            briefingError = nil
            whitelist = entries
        }
        let selfUsername = await readerActor.myUsername()
        let selfDisplayName = await readerActor.displayName(for: selfUsername)
        let dateStr = ISO8601DateFormatter().string(from: Date())

        // Filter to chats with today's messages — one batch read (ScanEngine pattern).
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayProbe = (try? await readerActor.messagesBatch(
            whitelist.map {
                WeChatReader.MessageBatchRequest(chatUsername: $0.id, limit: 50)
            }
        )) ?? [:]
        var activeEntries: [WhitelistEntry] = []
        for entry in whitelist {
            let messages = todayProbe[entry.id] ?? []
            let hasToday = messages.contains {
                Date(timeIntervalSince1970: Double($0.createTime)) >= todayStart
            }
            if hasToday { activeEntries.append(entry) }
        }

        let total = activeEntries.count
        let initialRequestVersions = requestVersions
        var results: [String: ChatInsightResult] = [:]
        var statsResults: [ChatStatsData] = []
        let dayLoader = InsightDataLoader()

        for (i, entry) in activeEntries.enumerated() {
            // Cooperative cancellation
            guard !Task.isCancelled else { break }

            insightProgress = "正在分析 \(i + 1)/\(total) \(visibleName(entry))…"
            insightProgressFraction = Double(i) / Double(max(total, 1))

            if let result = await chatInsightService.analyzeEntry(
                entry, date: todayStart,
                selfUsername: selfUsername, selfDisplayName: selfDisplayName
            ) {
                results[entry.id] = result
            }

           if let stats = await dayLoader.statsForDay(
                chatUsername: entry.id, chatName: visibleName(entry),
                isGroup: entry.isGroup, category: entry.category,
                date: todayStart, readerActor: readerActor
            ), stats.messageCount > 0 {
                statsResults.append(stats)
            }
        }

        guard !Task.isCancelled else {
            insightLoading = false
            insightProgress = ""
            return
        }

        insightProgress = "正在生成整体总结…"
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
            return (chatName: visibleName(e), result: value)
        }

        let briefing = await chatInsightService.generateGlobalBriefing(
            selfName: selfDisplayName, date: dateStr,
            chatInsights: insightPairs, globalStats: globalStats
        )
        let chatNames = Dictionary(uniqueKeysWithValues: whitelist.map { ($0.id, visibleName($0)) })

        for (chatUsername, result) in results {
            // A later user-selected day takes precedence over this bulk run.
            guard requestVersions[chatUsername] == initialRequestVersions[chatUsername],
                  !chatInsightLoading.contains(chatUsername) else { continue }
            if let selectedDay = resultDays[chatUsername],
               !Calendar.current.isDate(selectedDay, inSameDayAs: todayStart) { continue }
            resultDays[chatUsername] = todayStart
            chatInsights[chatUsername] = result
        }
        globalBriefing = briefing?.bindingChatUsernames(names: chatNames)
        briefingGeneratedAt = briefing == nil ? nil : now()
        insightLoading = false
       insightProgress = ""
       insightProgressFraction = 1.0
   }

    private func visibleName(_ entry: WhitelistEntry) -> String {
        ContactIdentityIndex.visibleName(
            username: entry.id,
            stored: store.storedDisplayName(entry.id),
            readerName: entry.displayName)
    }
}
