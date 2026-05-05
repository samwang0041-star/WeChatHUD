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
    /// True while insight analysis is running.
    @Published var insightLoading: Bool = false
    /// Insight progress: "正在分析 3/12..."
    @Published var insightProgress: String = ""
    /// Insight progress fraction 0-1
    @Published var insightProgressFraction: Double = 0

    // MARK: - Dependencies

    private let reader: WeChatReader
    private let store: HUDStore
    private let aiService: AIService
    private lazy var chatInsightService: ChatInsightService = {
        ChatInsightService(reader: reader, store: store, aiService: aiService)
    }()

    /// Insight load task — kept so we can cancel and avoid duplicates.
    private var insightLoadTask: Task<Void, Never>?

    init(reader: WeChatReader, store: HUDStore, aiService: AIService) {
        self.reader = reader
        self.store = store
        self.aiService = aiService
    }

    deinit {
        insightLoadTask?.cancel()
    }

    // MARK: - Public API

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
        chatInsightLoading.insert(chatUsername)
        chatInsightErrors[chatUsername] = nil
        insightProgress = "正在分析单聊..."

        defer {
            chatInsightLoading.remove(chatUsername)
            if !insightLoading {
                insightProgress = ""
            }
        }

        guard let entry = store.getWhitelist().first(where: { $0.id == chatUsername }) else {
            chatInsightErrors[chatUsername] = "不在关注列表中"
            return
        }

        let selfUsername = reader.myUsername()
        let selfDisplayName = reader.displayName(for: selfUsername)

        guard let result = await chatInsightService.analyzeEntry(
            entry, date: date,
            selfUsername: selfUsername, selfDisplayName: selfDisplayName
        ) else {
            chatInsightErrors[chatUsername] = "该日期没有可分析内容，或 AI 暂时不可用"
            return
        }

        chatInsights[chatUsername] = result
    }

    // MARK: - Full Insight Load

    /// Full insight load with progress reporting.
    private func loadInsight(force: Bool = false) async {
        guard !insightLoading else { return }

        // Cache check: skip if generated within last 30 minutes
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
            // Cooperative cancellation
            guard !Task.isCancelled else { break }

            insightProgress = "正在分析 \(i + 1)/\(total) \(entry.displayName)..."
            insightProgressFraction = Double(i) / Double(max(total, 1))

            if let result = await chatInsightService.analyzeEntry(
                entry, date: Date(),
                selfUsername: selfUsername, selfDisplayName: selfDisplayName
            ) {
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

        guard !Task.isCancelled else {
            insightLoading = false
            insightProgress = ""
            return
        }

        insightProgress = "正在生成整体简报..."
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
}
