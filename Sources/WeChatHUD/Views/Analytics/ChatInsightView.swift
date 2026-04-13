import SwiftUI

/// Main chat insight view — shows chat list immediately, triggers AI on demand.
struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @State private var selectedChat: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Left: chat list (always visible, no AI needed)
            chatListSidebar
                .frame(width: 260)

            Divider().background(Color.white.opacity(0.1))

            // Right: detail or global briefing
            if let chatId = selectedChat,
               let entry = store.getWhitelist().first(where: { $0.id == chatId }) {
                ChatInsightDetailView(
                    chatUsername: chatId,
                    chatName: entry.displayName,
                    result: monitor.chatInsights[chatId]
                )
                .environmentObject(monitor)
                .id(chatId)  // force refresh on selection change
            } else {
                globalPanel
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
    }

    // MARK: - Chat list sidebar

    private var chatListSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("聊天洞察")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button(action: { Task { await monitor.loadInsight(force: true) } }) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(.orange.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("AI 全局分析")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Progress bar
            if monitor.insightLoading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: monitor.insightProgressFraction)
                        .tint(.orange)
                    Text(monitor.insightProgress)
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Divider().background(Color.white.opacity(0.08))

            // Chat list grouped by category
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let whitelist = store.getWhitelist()
                    let groups = whitelist.filter { $0.isGroup }
                    let privates = whitelist.filter { !$0.isGroup }

                    let workGroups = groups.filter { $0.category == .work }
                    let lifeGroups = groups.filter { $0.category == .life }
                    let otherGroups = groups.filter { $0.category == .other }
                    let workPrivate = privates.filter { $0.category == .work }
                    let lifePrivate = privates.filter { $0.category == .life }
                    let otherPrivate = privates.filter { $0.category == .other }

                    if !workGroups.isEmpty || !workPrivate.isEmpty {
                        categorySection("工作", entries: workGroups + workPrivate)
                    }
                    if !lifeGroups.isEmpty || !lifePrivate.isEmpty {
                        categorySection("生活", entries: lifeGroups + lifePrivate)
                    }
                    if !otherGroups.isEmpty || !otherPrivate.isEmpty {
                        categorySection("其他", entries: otherGroups + otherPrivate)
                    }
                }
                .padding(.top, 6)
            }
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.1))
    }

    @ViewBuilder
    private func categorySection(_ title: String, entries: [WhitelistEntry]) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

        ForEach(entries, id: \.id) { entry in
            chatRow(entry)
        }
    }

    private func chatRow(_ entry: WhitelistEntry) -> some View {
        let isSelected = selectedChat == entry.id
        let hasInsight = monitor.chatInsights[entry.id] != nil
        let insight = monitor.chatInsights[entry.id]

        return Button(action: {
            selectedChat = entry.id
            // Trigger AI analysis when user clicks (if not already done)
            if !hasInsight {
                Task { await monitor.analyzeOneChat(chatUsername: entry.id) }
            }
        }) {
            HStack(spacing: 8) {
                // Group/private icon
                Image(systemName: entry.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.white.opacity(isSelected ? 0.95 : 0.7))
                        .lineLimit(1)

                    if let insight = insight {
                        Text(insight.headline)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Analysis status indicator
                if hasInsight {
                    if insight?.needsMyAttention == true {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                    } else {
                        Circle().fill(Color.green.opacity(0.5)).frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Global panel (right side when no chat selected)

    private var globalPanel: some View {
        VStack(spacing: 0) {
            if let briefing = monitor.globalBriefing {
                globalBriefingView(briefing)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.15))

                    Text("选择左侧聊天查看分析")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.4))

                    Text("或点击 ✨ 生成全局简报")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))

                    if monitor.insightLoading {
                        VStack(spacing: 6) {
                            ProgressView(value: monitor.insightProgressFraction)
                                .frame(width: 200)
                                .tint(.orange)
                            Text(monitor.insightProgress)
                                .font(.system(size: 10))
                                .foregroundColor(.orange.opacity(0.6))
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func globalBriefingView(_ briefing: GlobalBriefing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Stats
                HStack(spacing: 12) {
                    statCard("消息", "\(briefing.stats.totalMessages)", .blue)
                    statCard("群聊", "\(briefing.stats.activeGroups)/\(briefing.stats.totalGroups)", .purple)
                    statCard("私聊", "\(briefing.stats.activePrivateChats)", .cyan)
                    statCard("工作占比", "\(Int(briefing.stats.workRatio * 100))%", .orange)
                }

                // Headline
                Text(briefing.headline)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(8)

                // Action required
                if !briefing.actionRequired.isEmpty {
                    sectionBlock("需要你行动", color: .red) {
                        ForEach(Array(briefing.actionRequired.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.source): \(item.what)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.85))
                                    Text("等了 \(String(format: "%.0f", item.waitingHours)) 小时 · \(item.urgency)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red.opacity(0.6))
                                }
                            }
                        }
                    }
                }

                // Cross topics
                if !briefing.crossTopics.isEmpty {
                    sectionBlock("跨群话题", color: .purple) {
                        ForEach(Array(briefing.crossTopics.enumerated()), id: \.offset) { _, topic in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(topic.name).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.85))
                                    Spacer()
                                    Text(topic.status).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                                }
                                Text(topic.chats.joined(separator: " · ")).font(.system(size: 10)).foregroundColor(.purple.opacity(0.6))
                                Text(topic.summary).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).lineLimit(3)
                            }
                        }
                    }
                }

                // Dark signals
                if let headline = briefing.darkSignals.headline, !headline.isEmpty {
                    sectionBlock("暗信号", color: .orange) {
                        Text(headline).font(.system(size: 12)).foregroundColor(.orange.opacity(0.8))
                    }
                }

                // Top suggestion
                sectionBlock("建议", color: .green) {
                    Text(briefing.topSuggestion).font(.system(size: 12)).foregroundColor(.green.opacity(0.8))
                }

                Spacer().frame(height: 20)
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private func statCard(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundColor(color.opacity(0.9))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.06))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func sectionBlock(_ title: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color.opacity(0.7))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }
}
