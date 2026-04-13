import SwiftUI

/// Main chat insight view — macOS native style, white background.
/// Left sidebar: chat list. Right: analysis content with card layout.
struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var panelState: PanelState
    @State private var selectedChat: String? = nil
    @State private var searchText = ""
    @State private var selectedDate = Date()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, maxWidth: 280)
            detailArea
                .frame(minWidth: 500)
        }
        .frame(minWidth: 800, minHeight: 550)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("搜索群聊...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Chat list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let whitelist = filteredWhitelist()
                    let groups = whitelist.filter { $0.isGroup }
                    let privates = whitelist.filter { !$0.isGroup }

                    if !groups.isEmpty {
                        sidebarSection("群聊", count: groups.count)
                        ForEach(groups, id: \.id) { entry in
                            sidebarRow(entry)
                        }
                    }
                    if !privates.isEmpty {
                        sidebarSection("私聊", count: privates.count)
                        ForEach(privates, id: \.id) { entry in
                            sidebarRow(entry)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Bottom: global analysis button
            Button(action: { selectedChat = nil; Task { await monitor.loadInsight(force: true) } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 11))
                    Text("全局分析")
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func filteredWhitelist() -> [WhitelistEntry] {
        let all = store.getWhitelist()
        if searchText.isEmpty { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private func sidebarSection(_ title: String, count: Int) -> some View {
        HStack {
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

    private func sidebarRow(_ entry: WhitelistEntry) -> some View {
        let isSelected = selectedChat == entry.id
        let hasInsight = monitor.chatInsights[entry.id] != nil
        let insight = monitor.chatInsights[entry.id]

        return Button(action: {
            selectedChat = entry.id
            if !hasInsight {
                Task { await monitor.analyzeOneChat(chatUsername: entry.id) }
            }
        }) {
            HStack(spacing: 8) {
                // Avatar placeholder
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
                    } else {
                        Text(entry.category.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }

                Spacer()

                if hasInsight {
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

    private func categoryColor(_ cat: WhitelistCategory) -> Color {
        switch cat {
        case .work: return .blue
        case .life: return .green
        case .other: return .orange
        }
    }

    // MARK: - Detail area (right side)

    @ViewBuilder
    private var detailArea: some View {
        if let chatId = selectedChat,
           let entry = store.getWhitelist().first(where: { $0.id == chatId }) {
            ChatInsightDetailView(
                chatUsername: chatId,
                chatName: entry.displayName,
                isGroup: entry.isGroup,
                category: entry.category,
                result: monitor.chatInsights[chatId],
                selectedDate: $selectedDate
            )
            .environmentObject(monitor)
            .id(chatId)
        } else {
            globalPlaceholder
        }
    }

    private var globalPlaceholder: some View {
        VStack(spacing: 16) {
            if monitor.insightLoading {
                VStack(spacing: 10) {
                    ProgressView(value: monitor.insightProgressFraction)
                        .frame(width: 240)
                    Text(monitor.insightProgress)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else if let briefing = monitor.globalBriefing {
                globalBriefingContent(briefing)
            } else {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("选择左侧聊天查看分析")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Text("或点击「全局分析」生成全景简报")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    @ViewBuilder
    private func globalBriefingContent(_ briefing: GlobalBriefing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全局简报")
                            .font(.system(size: 18, weight: .bold))
                        Text(briefing.date)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // Stats row
                HStack(spacing: 12) {
                    globalStatCard("消息总数", "\(briefing.stats.totalMessages)", "bubble.left.and.bubble.right.fill", .blue)
                    globalStatCard("活跃群聊", "\(briefing.stats.activeGroups)/\(briefing.stats.totalGroups)", "person.3.fill", .purple)
                    globalStatCard("活跃私聊", "\(briefing.stats.activePrivateChats)", "person.fill", .cyan)
                    globalStatCard("工作占比", "\(Int(briefing.stats.workRatio * 100))%", "briefcase.fill", .orange)
                }

                // Headline
                Text(briefing.headline)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)

                // Action required
                if !briefing.actionRequired.isEmpty {
                    globalCard("需要你行动", icon: "exclamationmark.circle.fill", color: .red) {
                        ForEach(Array(briefing.actionRequired.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.source): \(item.what)")
                                        .font(.system(size: 12))
                                    Text("等了 \(String(format: "%.0f", item.waitingHours)) 小时")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                            }
                        }
                    }
                }

                // Suggestion
                globalCard("建议", icon: "lightbulb.fill", color: .green) {
                    Text(briefing.topSuggestion)
                        .font(.system(size: 12))
                }
            }
            .padding(24)
        }
    }

    private func globalStatCard(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func globalCard(_ title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}
