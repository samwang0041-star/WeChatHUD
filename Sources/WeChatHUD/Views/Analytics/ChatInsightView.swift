import SwiftUI

struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var reader: WeChatReader
    @EnvironmentObject var panelState: PanelState
    @ObservedObject var insightCoordinator: InsightCoordinator
    @State private var selectedChat: String? = nil
    @State private var searchText = ""
    @State private var selectedDate = Date()
    @State private var expandedRadarFindingID: String? = nil
    @State private var expandedModules: Set<String> = []
    @StateObject private var insightStore = InsightStore()

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 800 {
                HSplitView {
                    // The smallest supported window leaves this page about
                    // 528pt after the sidebar and padding; 220 + 480 could not
                    // fit, and the list column rendered over the divider with
                    // its rows cut off. The floors now fit, and ideal widths
                    // keep the split unchanged on a roomy window.
                    conversationSidebar.frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                    detailArea.frame(minWidth: 300, idealWidth: 480)
                }
            } else {
                VStack(spacing: 0) {
                    conversationSidebar.frame(height: 190)
                    Divider()
                    detailArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            reloadInsightStats()
            // `--preview-insight-overview` keeps the overview selected so the
            // page can be screenshotted; every real launch lands on a chat.
            if selectedChat == nil, !PreviewRuntime.opensInsightOverviewByDefault {
                selectedChat = store.getWhitelist().first?.id
            }
        }
        .onChange(of: monitor.stats.lastSyncAt) { _, _ in
            reloadInsightStats()
        }
        .onChange(of: insightStore.selectedWindow) { _, _ in
            reloadInsightStats()
        }
        .onChange(of: insightStore.selectedScope) { _, _ in
            reloadInsightStats()
        }
        .onChange(of: selectedDate) { _, newDate in
            guard let chatId = selectedChat else { return }
            // Clear existing result for this chat so re-analysis triggers
            insightCoordinator.chatInsights.removeValue(forKey: chatId)
            Task {
                await monitor.analyzeOneChat(chatUsername: chatId, date: newDate)
            }
        }
    }

    private var conversationSidebar: some View {
        InsightSidebarView(
            insightStore: insightStore,
            insightCoordinator: insightCoordinator,
            store: store,
            reader: reader,
            selectedChat: $selectedChat,
            searchText: $searchText,
            onAnalyzeChat: { chatUsername in
                guard insightCoordinator.result(for: chatUsername, date: selectedDate) == nil else { return }
                Task { await monitor.analyzeOneChat(chatUsername: chatUsername, date: selectedDate) }
            },
            selectedDate: selectedDate
        )
    }

    private func reloadInsightStats() {
        if PreviewRuntime.opensInsightOverviewByDefault {
            insightStore.applyProductPreviewFixture(chatStats: PreviewRuntime.previewChatStats())
            return
        }
        Task {
            await insightStore.reload(store: store, reader: reader, replyDebtItems: monitor.replyDebtItems)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        if let chatId = selectedChat {
            if let entry = store.getWhitelist().first(where: { $0.id == chatId }) {
                ChatInsightDetailView(
                    chatUsername: chatId,
                    chatName: entry.displayName,
                    isGroup: entry.isGroup,
                    category: entry.category,
                    stats: insightStore.statsForDay(chatUsername: chatId, chatName: entry.displayName,
                        isGroup: entry.isGroup, category: entry.category, date: selectedDate, reader: reader),
                    result: insightCoordinator.result(for: chatId, date: selectedDate),
                    insightCoordinator: insightCoordinator,
                    selectedDate: $selectedDate
                )
                .environmentObject(monitor)
                .id(chatId)
            } else if let session = insightStore.otherActiveSessions.first(where: { $0.id == chatId }) {
                let stats = insightStore.statsForDay(chatUsername: chatId, chatName: session.displayName,
                    isGroup: session.isGroup, category: .other, date: selectedDate, reader: reader)
                ChatInsightDetailView(
                    chatUsername: chatId,
                    chatName: session.displayName,
                    isGroup: session.isGroup,
                    category: .other,
                    stats: stats,
                    result: nil,
                    insightCoordinator: insightCoordinator,
                    selectedDate: $selectedDate
                )
                .environmentObject(monitor)
                .id(chatId)
            } else {
                overviewDashboard
            }
        } else {
            overviewDashboard
        }
    }

    private var overviewDashboard: some View {
        InsightOverviewDashboard(
            insightStore: insightStore,
            insightCoordinator: monitor.insightCoordinator,
            store: store,
            onRefresh: { monitor.refreshInsightInBackground(force: true) },
            onCopyReport: {
                CompanionClipboard.write(
                    InsightOverviewReport.markdown(
                        overview: insightStore.overview,
                        briefing: monitor.insightCoordinator.globalBriefing
                    )
                )
            },
            onSelectChat: { selectedChat = $0 },
            onExpandModule: { expandedModules.insert($0) },
            selectedDate: $selectedDate,
            expandedRadarFindingID: $expandedRadarFindingID,
            expandedModules: $expandedModules
        )
    }
}

/// The overview page's 「复制为 Markdown 总结」. Built from the same numbers the
/// page shows, so a copied report and the screen cannot disagree.
enum InsightOverviewReport {
    static func markdown(
        overview: ChatInsightEngine.GlobalOverview?,
        briefing: GlobalBriefing?
    ) -> String {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        lines.append("# 聊天总览 · \(formatter.string(from: Date()))")

        if let overview {
            lines.append("")
            lines.append("- 消息 \(overview.totalMessages) 条 · 回复率 \(Int(overview.responseRate * 100))% · \(overview.boundarySummary)")
            lines.append("- 待办 \(overview.pendingAsks) 项 · 紧急 \(overview.urgentAsks) 项 · 撤回 \(overview.recalledMessages) 条")
        }

        if let briefing {
            if !briefing.headline.isEmpty {
                lines.append("")
                lines.append("## 态势")
                lines.append(briefing.headline)
            }
            let actions = briefing.actionRequired.filter { !$0.what.isEmpty }
            if !actions.isEmpty {
                lines.append("")
                lines.append("## 需要你处理")
                for item in actions {
                    let waiting = item.waitingHours > 0 ? "（已等 \(Int(item.waitingHours)) 小时）" : ""
                    lines.append("- \(item.source)：\(item.what)\(waiting)")
                }
            }
            let topics = briefing.crossTopics.filter { !$0.name.isEmpty && $0.chats.count >= 2 }
            if !topics.isEmpty {
                lines.append("")
                lines.append("## 跨对话话题")
                for topic in topics {
                    let detail = topic.conflict?.isEmpty == false ? topic.conflict! : topic.summary
                    lines.append("- \(topic.name)（\(topic.chats.joined(separator: "、"))）：\(detail)")
                }
            }
            if !briefing.topSuggestion.isEmpty {
                lines.append("")
                lines.append("## 建议")
                lines.append(briefing.topSuggestion)
            }
        }

        if lines.count == 1 {
            lines.append("")
            lines.append("还没有可导出的分析结果。")
        }
        return lines.joined(separator: "\n")
    }
}
