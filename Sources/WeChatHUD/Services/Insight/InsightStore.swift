import Combine
import Foundation

enum InsightScope: String, CaseIterable {
    case whitelist = "已关注"
    case all = "所有人"
}

enum InsightTimeWindow: String, CaseIterable {
    case today = "今天"
    case week = "近 7 天"
    case month = "近 30 天"
    case quarter = "近 90 天"
    case all = "全部"

    /// The overview page's heading. It used to be the literal 「今天聊了什么」
    /// while the picker right beside it could say 近 30 天.
    var overviewHeading: String { "\(rawValue)聊了什么" }

    var seconds: Int? {
        switch self {
        case .all: return nil
        default: return dayCount * 86400
        }
    }

    /// Calendar-day span used for density / averages. ".today" is 1 day.
    var dayCount: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return 365
        }
    }

    var fetchLimit: Int {
        switch self {
        case .today: return 100
        case .week: return 200
        case .month: return 500
        case .quarter: return 1000
        case .all: return 2000
        }
    }
}

struct InsightSessionEntry: Identifiable {
    let id: String
    let displayName: String
    let isGroup: Bool
    let lastTimestamp: Int
    let messageCount: Int
}

@MainActor
final class InsightStore: ObservableObject {
    @Published var allStats: [String: ChatStatsData] = [:]
    @Published var overview: ChatStatsEngine.GlobalOverview?
    @Published var statsLoaded = false
    @Published var selectedScope: InsightScope = .all
    @Published var selectedWindow: InsightTimeWindow = .today
    @Published var otherActiveSessions: [InsightSessionEntry] = []

    @Published var reloadError: String?

    private let dataLoader = InsightDataLoader()
    private var detailStatsCache: [String: ChatStatsData] = [:]

    /// Preview-only: put the overview page into a renderable state without a
    /// WeChat database. The numbers still come from the shipped
    /// `computeGlobalOverview`, so a screenshot is not a mock-up of the math.
    func applyProductPreviewFixture(chatStats: [String: ChatStatsData]) {
        guard PreviewRuntime.isEnabled else { return }
        allStats = chatStats
        statsLoaded = true
        reloadError = nil
        overview = ChatInsightEngine.computeGlobalOverview(
            allStats: chatStats,
            contacts: [],
            commitments: [],
            replyDebtItems: [],
            vipUsernames: [],
            pendingAskCount: 3,
            urgentAskCount: 1,
            recalledMessageCount: 2
        )
    }

    /// What made this reload happen.
    enum ReloadTrigger {
        /// The user opened the page or changed window / scope / date.
        case userInitiated
        /// A scan completed. `monitor.stats.lastSyncAt` is stamped on every
        /// scan whether or not anything arrived, and one reload is a
        /// library-wide walk, so this trigger cannot be taken literally.
        case newData
    }

    /// Scan ticks are not evidence that anything arrived — `stats.lastSyncAt`
    /// is stamped on every completed scan — so the tick has to ask instead of
    /// trigger. Its own type because a `static let` on a `@MainActor` class is
    /// not readable from the nonisolated predicate.
    nonisolated enum AutoReload {
        /// Minimum gap between two automatic reloads. The page still refreshes
        /// instantly for anything the user asks for.
        static let interval: TimeInterval = 300

        static func permitted(last: Date?, now: Date) -> Bool {
            guard let last else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    private var lastAutoReloadAt: Date?
    private var isReloading = false
    private var userReloadWhileBusy = false

    func reload(
        store: HUDStore, reader: WeChatReader, replyDebtItems: [ReplyDebtItem],
        trigger: ReloadTrigger, now: Date = Date()
    ) async {
        if trigger == .newData {
            guard !isReloading else { return }
            guard Self.AutoReload.permitted(last: lastAutoReloadAt, now: now) else { return }
            lastAutoReloadAt = now
            // New data must not blank the page: a spinner every few minutes on
            // a view that is already showing correct numbers reads as a crash.
            await performReload(
                store: store, reader: reader, replyDebtItems: replyDebtItems, clearsView: false
            )
            return
        }
        if isReloading {
            userReloadWhileBusy = true
            return
        }
        await performReload(
            store: store, reader: reader, replyDebtItems: replyDebtItems, clearsView: true
        )
        if userReloadWhileBusy {
            // The window/scope the user picked while a walk was running has to
            // win; a silent drop would leave the page labelled 近 30 天 while
            // showing 今天's numbers.
            userReloadWhileBusy = false
            await performReload(
                store: store, reader: reader, replyDebtItems: replyDebtItems, clearsView: true
            )
        }
    }

    private func performReload(
        store: HUDStore, reader: WeChatReader, replyDebtItems: [ReplyDebtItem],
        clearsView: Bool
    ) async {
        isReloading = true
        defer { isReloading = false }
        detailStatsCache.removeAll()
        if clearsView {
            statsLoaded = false
            overview = nil
            reloadError = nil
        }

        repairStaleDisplayNames(store: store, reader: reader)

        // `load` walks every `message_*.db` table row by row — measured on this
        // machine: 4648 table/shard pairs, ~288k rows, ~550 MB of page cache,
        // and the "全部" window applies no time filter at all. Running it on the
        // main actor froze the window on every open, every window switch, and
        // once per completed scan (`onChange(of: monitor.stats.lastSyncAt)`).
        // The load is read-only against lock-protected stores; only the
        // published writes below stay on the main actor.
        let window = selectedWindow
        let scope = selectedScope
        let result = await Self.loadInBackground(
            loader: dataLoader, store: store, reader: reader,
            replyDebtItems: replyDebtItems, window: window, scope: scope
        )

        guard let result else {
            reloadError = "无法读取会话列表"
            statsLoaded = true
            return
        }

        allStats = result.stats
        overview = result.overview
        otherActiveSessions = result.otherActiveSessions
        statsLoaded = true
    }

    func filteredWhitelist(store: HUDStore, searchText: String) -> [WhitelistEntry] {
        let all = store.getWhitelist()
        let filtered = searchText.isEmpty
            ? all
            : all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        return filtered.sorted { lhs, rhs in
            let leftHasMessages = allStats[lhs.id]?.messagesByHour.isEmpty == false ? 1 : 0
            let rightHasMessages = allStats[rhs.id]?.messagesByHour.isEmpty == false ? 1 : 0
            let leftCount = allStats[lhs.id]?.messageCount ?? 0
            let rightCount = allStats[rhs.id]?.messageCount ?? 0
            if leftHasMessages != rightHasMessages { return leftHasMessages > rightHasMessages }
            return leftCount > rightCount
        }
    }

    func filteredOtherSessions(searchText: String) -> [InsightSessionEntry] {
        guard !searchText.isEmpty else { return otherActiveSessions }
        return otherActiveSessions.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// Day statistics already computed for one chat, or nil.
    ///
    /// Deliberately cache-only: the previous version fell through to
    /// `dataLoader.statsForDay`, a synchronous `getMessages(limit: Int.max)`
    /// that decrypts every shard the chat spans. Called from SwiftUI body
    /// evaluation on the main actor, that stalled the insight page on every
    /// chat selection and date change — most visibly for today, which the
    /// sidebar's precompute skips. Views now read this and load what is missing
    /// through `computeDayStats`.
    func cachedDayStats(chatUsername: String, date: Date) -> ChatStatsData? {
        detailStatsCache["\(chatUsername):\(InsightDataLoader.dayRange(for: date).start)"]
    }

    // MARK: - Day stats without the main actor

    /// Detail stats for one calendar day, computed on a background executor.
    ///
    /// A single entry decodes that chat's whole day (`limit: Int.max`); the
    /// sidebar asks for this once per row, so doing it inside SwiftUI body
    /// evaluation meant hundreds of full-day reads on the main thread.
    nonisolated static func computeDayStats(
        requests: [(username: String, displayName: String, isGroup: Bool, category: WhitelistCategory)],
        date: Date,
        readerActor: WeChatReaderActor
    ) async -> [String: ChatStatsData] {
        let loader = InsightDataLoader()
        var out: [String: ChatStatsData] = [:]
        for request in requests {
            if let stats = await loader.statsForDay(
                chatUsername: request.username,
                chatName: request.displayName,
                isGroup: request.isGroup,
                category: request.category,
                date: date,
                readerActor: readerActor
            ) {
                out[request.username] = stats
            }
        }
        return out
    }

    /// Store finished day stats so the single-chat detail view can read them
    /// synchronously from its body instead of re-reading the day itself.
    func primeDayStats(_ stats: [String: ChatStatsData], date: Date) {
        let dayStart = InsightDataLoader.dayRange(for: date).start
        for (username, value) in stats {
            detailStatsCache["\(username):\(dayStart)"] = value
        }
    }

    /// Runs async `InsightDataLoader.load(readerActor:)` off the main actor.
    /// Creates a `WeChatReaderActor` hop so bulk sessions/stats share ScanEngine's
    /// isolation boundary while published writes stay on the main actor.
    nonisolated private static func loadInBackground(
        loader: InsightDataLoader,
        store: HUDStore,
        reader: WeChatReader,
        replyDebtItems: [ReplyDebtItem],
        window: InsightTimeWindow,
        scope: InsightScope
    ) async -> InsightDataLoader.LoadResult? {
        let readerActor = WeChatReaderActor(reader)
        return await loader.load(
            store: store,
            readerActor: readerActor,
            replyDebtItems: replyDebtItems,
            window: window,
            scope: scope
        )
    }

    private func repairStaleDisplayNames(store: HUDStore, reader: WeChatReader) {
        for entry in store.getWhitelist() {
            let name = entry.displayName
            guard MessageHelpers.isGroupChat(name) || name.hasPrefix("wxid_") else { continue }
            let resolved = reader.displayName(for: entry.id)
            guard resolved != entry.id && resolved != name else { continue }
            try? store.addToWhitelist(
                username: entry.id,
                displayName: resolved,
                isGroup: entry.isGroup,
                category: entry.category,
                attentionLevel: entry.attentionLevel
            )
        }
    }
}
