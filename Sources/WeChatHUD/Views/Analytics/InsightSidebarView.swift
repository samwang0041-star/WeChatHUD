import SwiftUI

struct InsightSidebarView: View {
    @ObservedObject var insightStore: InsightStore
    @ObservedObject var insightCoordinator: InsightCoordinator
    @ObservedObject var store: HUDStore
    @Binding var selectedChat: String?
    @Binding var searchText: String
    let onRefresh: () -> Void
    let onAnalyzeChat: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            chatList
            Divider()
            refreshButton
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("搜索聊天...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let whitelist = insightStore.filteredWhitelist(store: store, searchText: searchText)
                if !whitelist.isEmpty {
                    sidebarSection("关注", icon: "star", count: whitelist.count)
                    ForEach(whitelist, id: \.id) { entry in
                        whitelistRow(entry)
                    }
                }

                let others = insightStore.filteredOtherSessions(searchText: searchText)
                if !others.isEmpty {
                    sidebarSection("其他活跃", icon: "clock", count: others.count)
                    ForEach(others) { session in
                        otherSessionRow(session)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var refreshButton: some View {
        Button(action: {
            selectedChat = nil
            onRefresh()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 11))
                Text("今日态势")
                    .font(.system(size: 11))
            }
            .foregroundColor(.accentColor)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
        let hasInsight = insightCoordinator.chatInsights[entry.id] != nil
        let isAnalyzing = insightCoordinator.chatInsightLoading.contains(entry.id)
        let insight = insightCoordinator.chatInsights[entry.id]
        let stats = insightStore.allStats[entry.id]

        return Button(action: {
            selectedChat = entry.id
            if !hasInsight {
                onAnalyzeChat(entry.id)
            }
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
                    Text("\(session.messageCount)条消息")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }

                Spacer()

                Text("\(session.messageCount)")
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

    private func categoryColor(_ cat: WhitelistCategory) -> Color {
        switch cat {
        case .work: return .blue
        case .life: return .green
        case .other: return .orange
        }
    }
}
