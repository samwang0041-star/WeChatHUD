import Combine
import Foundation

enum InsightScope: String, CaseIterable {
    case whitelist = "白名单"
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
        case .today: return 24 * 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        case .quarter: return 90 * 86400
        case .all: return nil
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

    func reload(store: HUDStore, reader: WeChatReader, replyDebtItems: [ReplyDebtItem]) async {
        statsLoaded = false
        overview = nil
        reloadError = nil

        repairStaleDisplayNames(store: store, reader: reader)

        let result = dataLoader.load(
            store: store,
            reader: reader,
            replyDebtItems: replyDebtItems,
            window: selectedWindow,
            scope: selectedScope
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

    func statsForSession(_ session: InsightSessionEntry, reader: WeChatReader) -> ChatStatsData? {
        dataLoader.statsForSession(session, reader: reader)
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
