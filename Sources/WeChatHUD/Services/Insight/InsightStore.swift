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

    func reload(store: HUDStore, reader: WeChatReader, replyDebtItems: [ReplyDebtItem]) async {
        detailStatsCache.removeAll()
        statsLoaded = false
        overview = nil
        reloadError = nil

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

    func statsForDay(chatUsername: String, chatName: String, isGroup: Bool,
                     category: WhitelistCategory, date: Date, reader: WeChatReader) -> ChatStatsData? {
        let key = "\(chatUsername):\(InsightDataLoader.dayRange(for: date).start)"
        if let cached = detailStatsCache[key] { return cached }
        let stats = dataLoader.statsForDay(chatUsername: chatUsername, chatName: chatName,
                                          isGroup: isGroup, category: category, date: date, reader: reader)
        detailStatsCache[key] = stats
        return stats
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
        reader: WeChatReader
    ) async -> [String: ChatStatsData] {
        await Task.detached(priority: .utility) {
            let loader = InsightDataLoader()
            var out: [String: ChatStatsData] = [:]
            for request in requests {
                if let stats = loader.statsForDay(
                    chatUsername: request.username,
                    chatName: request.displayName,
                    isGroup: request.isGroup,
                    category: request.category,
                    date: date,
                    reader: reader
                ) {
                    out[request.username] = stats
                }
            }
            return out
        }.value
    }

    /// Store finished day stats so the single-chat detail view can read them
    /// synchronously from its body instead of re-reading the day itself.
    func primeDayStats(_ stats: [String: ChatStatsData], date: Date) {
        let dayStart = InsightDataLoader.dayRange(for: date).start
        for (username, value) in stats {
            detailStatsCache["\(username):\(dayStart)"] = value
        }
    }

    /// Runs `InsightDataLoader.load` off the main actor. Kept as a single
    /// `nonisolated` hop so the heavy call cannot accidentally be awaited in a
    /// main-actor context.
    nonisolated private static func loadInBackground(
        loader: InsightDataLoader,
        store: HUDStore,
        reader: WeChatReader,
        replyDebtItems: [ReplyDebtItem],
        window: InsightTimeWindow,
        scope: InsightScope
    ) async -> InsightDataLoader.LoadResult? {
        await Task.detached(priority: .userInitiated) {
            loader.load(store: store, reader: reader, replyDebtItems: replyDebtItems,
                        window: window, scope: scope)
        }.value
    }

    private func repairStaleDisplayNames(store: HUDStore, reader: WeChatReader) {
        for entry in store.getWhitelist() {
            let name = entry.displayName
            guard name.contains("@chatroom") || name.hasPrefix("wxid_") else { continue }
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
