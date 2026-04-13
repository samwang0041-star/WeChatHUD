import SwiftUI

/// Main chat insight view — a scrollable briefing flow.
struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @State private var selectedCard: ChatCardData? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            if monitor.insightLoading && monitor.globalBriefing == nil {
                loadingView
            } else if let briefing = monitor.globalBriefing {
                briefingContent(briefing)
            } else {
                emptyView
            }
        }
        .task { await monitor.loadInsight() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("聊天洞察")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            if monitor.insightLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }

            Button(action: { Task { await monitor.loadInsight(force: true) } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    // MARK: - Briefing content

    @ViewBuilder
    private func briefingContent(_ briefing: GlobalBriefing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Action required section
                if !briefing.actionRequired.isEmpty {
                    sectionCard(title: "🔴 需要你行动", color: .red) {
                        ForEach(Array(briefing.actionRequired.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.source): \(item.what)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.85))
                                    Text("等了\(String(format: "%.0f", item.waitingHours))小时")
                                        .font(.system(size: 9))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                            }
                        }
                    }
                }

                // Global overview
                sectionCard(title: "📊 今日全景", color: .blue) {
                    // Stats row
                    HStack(spacing: 8) {
                        statPill("消息", "\(briefing.stats.totalMessages)")
                        statPill("群聊", "\(briefing.stats.activeGroups)/\(briefing.stats.totalGroups)")
                        statPill("私聊", "\(briefing.stats.activePrivateChats)")
                        statPill("工作", "\(Int(briefing.stats.workRatio * 100))%")
                    }

                    Text(briefing.headline)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(4)
                }

                // Per-chat cards grouped by category
                let sortedInsights = sortedChatCards()
                let workChats = sortedInsights.filter { $0.category == .work }
                let lifeChats = sortedInsights.filter { $0.category == .life }
                let otherChats = sortedInsights.filter { $0.category == .other }

                if !workChats.isEmpty {
                    chatSection(title: "🏢 工作", chats: workChats)
                }
                if !lifeChats.isEmpty {
                    chatSection(title: "🏠 生活", chats: lifeChats)
                }
                if !otherChats.isEmpty {
                    chatSection(title: "💬 其他", chats: otherChats)
                }

                // Cross-chat topics
                if !briefing.crossTopics.isEmpty {
                    sectionCard(title: "🔗 跨群话题", color: .purple) {
                        ForEach(Array(briefing.crossTopics.enumerated()), id: \.offset) { _, topic in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(topic.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                    Spacer()
                                    Text(topic.status)
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                Text(topic.chats.joined(separator: " · "))
                                    .font(.system(size: 9))
                                    .foregroundColor(.purple.opacity(0.7))
                                Text(topic.summary)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(2)
                                if let conflict = topic.conflict {
                                    Text("⚠ \(conflict)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.yellow.opacity(0.8))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Dark signals
                if let darkHeadline = briefing.darkSignals.headline, !darkHeadline.isEmpty {
                    sectionCard(title: "🔇 暗信号", color: .orange) {
                        Text(darkHeadline)
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.8))
                            .lineLimit(4)
                    }
                }

                // Top suggestion
                sectionCard(title: "💡 建议", color: .green) {
                    Text(briefing.topSuggestion)
                        .font(.system(size: 11))
                        .foregroundColor(.green.opacity(0.8))
                }

                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .sheet(item: $selectedCard) { card in
            ChatInsightDetailView(chatUsername: card.id, chatName: card.name, result: card.result)
                .environmentObject(monitor)
        }
    }

    // MARK: - Chat card data

    struct ChatCardData: Identifiable {
        let id: String  // chatUsername
        let name: String
        let category: WhitelistCategory
        let result: ChatInsightResult
        let score: Int
    }

    private func sortedChatCards() -> [ChatCardData] {
        let whitelist = store.getWhitelist()
        return monitor.chatInsights.compactMap { (username, result) -> ChatCardData? in
            guard let entry = whitelist.first(where: { $0.id == username }) else { return nil }
            let stats = ChatStatsData(
                chatUsername: username, chatName: entry.displayName,
                isGroup: entry.isGroup, category: entry.category,
                messageCount: result.topics.reduce(0) { $0 + $1.messageCount },
                myMessageCount: 0, participantCount: 0,
                messagesByHour: Array(repeating: 0, count: 24),
                avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
                topSenders: [], silentMembers: [], ignoredMessages: []
            )
            let score = ChatInsightEngine.sortingScore(stats, hasActionForMe: result.needsMyAttention)
            return ChatCardData(id: username, name: entry.displayName,
                              category: entry.category, result: result, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - Chat section

    @ViewBuilder
    private func chatSection(title: String, chats: [ChatCardData]) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))
            .padding(.top, 4)

        ForEach(chats) { chat in
            Button(action: { selectedCard = chat }) {
                chatCard(chat)
            }
            .buttonStyle(.plain)
        }
    }

    private func chatCard(_ chat: ChatCardData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(chat.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if chat.result.needsMyAttention {
                    Text("⚠")
                        .font(.system(size: 9))
                }
                Text(chat.result.overallMood)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Topics as tags
            HStack(spacing: 4) {
                ForEach(Array(chat.result.topics.prefix(3).enumerated()), id: \.offset) { _, topic in
                    Text(topic.name)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
            }

            Text(chat.result.headline)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionCard(title: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color.opacity(0.8))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }

    private func statPill(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(.white.opacity(0.8))
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("正在分析聊天...")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Text("暂无分析数据")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Text("点击刷新开始分析")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
