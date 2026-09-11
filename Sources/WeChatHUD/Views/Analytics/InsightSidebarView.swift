import SwiftUI

struct InsightSidebarView: View {
    @ObservedObject var insightStore: InsightStore
    @ObservedObject var insightCoordinator: InsightCoordinator
    @ObservedObject var store: HUDStore
    @ObservedObject var reader: WeChatReader
    @Binding var selectedChat: String?
    @Binding var searchText: String
    let onAnalyzeChat: (String) -> Void
    var selectedDate: Date = Date()
    @State private var filter: ChatReviewFilter = .all
    /// Day stats for the selected (non-today) date, computed off the main
    /// thread. Reading them straight from the body called `getMessages(limit:
    /// Int.max)` once per row — and once per session in "其他最近聊天" — during
    /// SwiftUI body evaluation, before any filter was applied.
    @State private var dayStatsByChat: [String: ChatStatsData] = [:]

    private enum ChatReviewFilter: String, CaseIterable {
        case all = "全部"
        case groups = "群聊"
        case direct = "单聊"
        case updated = "有更新"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider()
            chatList
        }
        .background(CompanionPalette.canvas)
        .task(id: dayStatsTaskID) { await refreshDayStats() }
    }

    /// Reload key for the precomputed day stats: the date plus the set of chats
    /// the sidebar can show.
    private var dayStatsTaskID: String {
        let requests = dayStatsRequests()
        let key = requests
            .map { "\($0.username)|\($0.isGroup)|\($0.category.rawValue)" }
            .joined(separator: ",")
        return "\(Int(selectedDate.timeIntervalSince1970))#\(key)"
    }

    private func dayStatsRequests() -> [(username: String, displayName: String, isGroup: Bool, category: WhitelistCategory)] {
        let whitelist: [(username: String, displayName: String, isGroup: Bool, category: WhitelistCategory)] =
            insightStore.filteredWhitelist(store: store, searchText: "").map {
            (username: $0.id, displayName: $0.displayName, isGroup: $0.isGroup, category: $0.category)
        }
        let others: [(username: String, displayName: String, isGroup: Bool, category: WhitelistCategory)] =
            insightStore.otherActiveSessions.map {
            (username: $0.id, displayName: $0.displayName, isGroup: $0.isGroup, category: WhitelistCategory.other)
        }
        return whitelist + others
    }

    private func refreshDayStats() async {
        guard !Calendar.current.isDateInToday(selectedDate) else {
            dayStatsByChat = [:]
            return
        }
        let requests = dayStatsRequests()
        guard !requests.isEmpty else {
            dayStatsByChat = [:]
            return
        }
        let date = selectedDate
        let stats = await InsightStore.computeDayStats(requests: requests, date: date, reader: reader)
        dayStatsByChat = stats
        // The detail view asks for the selected chat's day stats from its own
        // body; those now come from the cache this primes instead of a read.
        insightStore.primeDayStats(stats, date: date)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("搜索聊天或联系人", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("搜索聊天或联系人")
            if !searchText.isEmpty {
                Button("清除搜索") { searchText = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CompanionPalette.jade)
            }
        }
        .padding(8)
        .background(CompanionPalette.surface)
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ChatReviewFilter.allCases, id: \.self) { value in
                CompanionFilterPill(title: value.rawValue, selected: filter == value) {
                    filter = value
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let whitelist = insightStore.filteredWhitelist(store: store, searchText: searchText).filter(matchesFilter)
                if !whitelist.isEmpty {
                    sidebarSection("关注的对话", icon: "star", count: whitelist.count)
                    ForEach(whitelist, id: \.id) { entry in
                        whitelistRow(entry)
                    }
                }

                let others = insightStore.filteredOtherSessions(searchText: searchText).filter { session in
                    matchesFilter(
                        isGroup: session.isGroup,
                        id: session.id,
                        messageCount: dayMessageCount(
                            username: session.id,
                            displayName: session.displayName,
                            isGroup: session.isGroup,
                            category: .other,
                            fallback: session.messageCount
                        )
                    )
                }
                if !others.isEmpty && filter != .updated {
                    sidebarSection("其他最近聊天", icon: "clock", count: others.count)
                    ForEach(others) { session in
                        otherSessionRow(session)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sidebarSection(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func whitelistRow(_ entry: WhitelistEntry) -> some View {
        let isSelected = selectedChat == entry.id
        let insight = insightCoordinator.result(for: entry.id, date: selectedDate)
        let hasInsight = insight != nil
        let isAnalyzing = insightCoordinator.chatInsightLoading.contains(entry.id)
        let stats = dayStats(
            username: entry.id,
            displayName: entry.displayName,
            isGroup: entry.isGroup,
            category: entry.category,
            fallback: insightStore.allStats[entry.id]
        )

        return Button(action: {
            selectedChat = entry.id
            onAnalyzeChat(entry.id)
        }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(categoryColor(entry.category).opacity(0.15))
                        .frame(width: 28, height: 28)
                    Text(String(entry.displayName.prefix(1)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(categoryColor(entry.category))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let insight = insight {
                        Text(insight.headline)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if let s = stats {
                        Text("\(s.messageCount)条消息 · \(s.participantCount)人")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    } else {
                        Text(entry.category.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }

                Spacer()

                if let s = stats, s.messageCount > 0 {
                    Text("\(s.messageCount)")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(4)
                }

                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else if hasInsight {
                    if insight?.needsMyAttention == true {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func otherSessionRow(_ session: InsightSessionEntry) -> some View {
        let isSelected = selectedChat == session.id
        let count = dayMessageCount(
            username: session.id,
            displayName: session.displayName,
            isGroup: session.isGroup,
            category: .other,
            fallback: session.messageCount
        )

        return Button(action: {
            selectedChat = session.id
        }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 28, height: 28)
                    Image(systemName: session.isGroup ? "person.3" : "person")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(count)条消息")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }

                Spacer()

                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func matchesFilter(_ entry: WhitelistEntry) -> Bool {
        matchesFilter(
            isGroup: entry.isGroup,
            id: entry.id,
            messageCount: dayMessageCount(
                username: entry.id,
                displayName: entry.displayName,
                isGroup: entry.isGroup,
                category: entry.category,
                fallback: insightStore.allStats[entry.id]?.messageCount ?? 0
            )
        )
    }

    private func matchesFilter(isGroup: Bool, id: String, messageCount: Int) -> Bool {
        switch filter {
        case .all: return true
        case .groups: return isGroup
        case .direct: return !isGroup
        case .updated:
            return insightCoordinator.result(for: id, date: selectedDate) != nil || messageCount > 0
        }
    }

    private func dayStats(
        username: String,
        displayName: String,
        isGroup: Bool,
        category: WhitelistCategory,
        fallback: ChatStatsData?
    ) -> ChatStatsData? {
        if Calendar.current.isDateInToday(selectedDate) { return fallback }
        return dayStatsByChat[username] ?? fallback
    }

    private func dayMessageCount(
        username: String,
        displayName: String,
        isGroup: Bool,
        category: WhitelistCategory,
        fallback: Int
    ) -> Int {
        if Calendar.current.isDateInToday(selectedDate) { return fallback }
        return dayStatsByChat[username]?.messageCount ?? fallback
    }

    private func categoryColor(_ cat: WhitelistCategory) -> Color {
        switch cat {
        case .work: return .blue
        case .life: return .green
        case .other: return .orange
        }
    }
}
