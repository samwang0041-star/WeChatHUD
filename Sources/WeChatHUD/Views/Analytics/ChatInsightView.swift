import SwiftUI

struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var insightCoordinator: InsightCoordinator
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var reader: WeChatReader
    @EnvironmentObject var panelState: PanelState
    @State private var selectedChat: String? = nil
    @State private var searchText = ""
    @State private var selectedDate = Date()
    @State private var expandedRadarFindingID: String?
    @State private var expandedModules: Set<String> = []
    @StateObject private var insightStore = InsightStore()

    var body: some View {
        HSplitView {
            InsightSidebarView(
                insightStore: insightStore,
                insightCoordinator: insightCoordinator,
                store: store,
                selectedChat: $selectedChat,
                searchText: $searchText,
                onRefresh: { monitor.refreshInsightInBackground(force: true) },
                onAnalyzeChat: { chatUsername in
                    Task { await monitor.analyzeOneChat(chatUsername: chatUsername, date: selectedDate) }
                }
            )
            .frame(minWidth: 220, maxWidth: 300)

            detailArea
                .frame(minWidth: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            reloadInsightStats()
            monitor.refreshInsightInBackground()
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

    private func reloadInsightStats() {
        Task {
            await insightStore.reload(store: store, reader: reader, replyDebtItems: monitor.replyDebtItems)
        }
    }

    private func statsForSession(_ session: InsightSessionEntry) -> ChatStatsData? {
        insightStore.statsForSession(session, reader: reader)
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
                    stats: insightStore.allStats[chatId],
                    result: insightCoordinator.chatInsights[chatId],
                    selectedDate: $selectedDate
                )
                .environmentObject(monitor)
                .environmentObject(insightCoordinator)
                .id(chatId)
            } else if let session = insightStore.otherActiveSessions.first(where: { $0.id == chatId }) {
                let stats = statsForSession(session)
                ChatInsightDetailView(
                    chatUsername: chatId,
                    chatName: session.displayName,
                    isGroup: session.isGroup,
                    category: .other,
                    stats: stats,
                    result: nil,
                    selectedDate: $selectedDate
                )
                .environmentObject(monitor)
                .environmentObject(insightCoordinator)
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
            insightCoordinator: insightCoordinator,
            store: store,
            onRefresh: { monitor.refreshInsightInBackground(force: true) },
            onCopyReport: copyAsReport,
            onSelectChat: { selectedChat = $0 },
            onExpandModule: { expandedModules.insert($0) },
            selectedDate: $selectedDate,
            expandedRadarFindingID: $expandedRadarFindingID,
            expandedModules: $expandedModules
        )
    }

    private func copyAsReport() {
        guard let o = insightStore.overview else { return }
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        lines.append("# WeChatHUD \(insightStore.selectedWindow.rawValue) 报告 · \(df.string(from: Date()))")
        lines.append("")
        if let b = insightCoordinator.globalBriefing {
            lines.append("## 头条")
            lines.append(b.headline)
            lines.append("")
            if !b.topSuggestion.isEmpty {
                lines.append("**建议**: \(b.topSuggestion)")
                lines.append("")
            }
            if !b.actionRequired.isEmpty {
                lines.append("## 需要行动")
                for item in b.actionRequired {
                    lines.append("- **\(item.source)**: \(item.what) (等 \(formatHoursShort(item.waitingHours)))")
                }
                lines.append("")
            }
        }
        lines.append("## 关键指标")
        lines.append("- 消息总量: \(o.totalMessages) (\(densityHint(o.recentDensityRatio)))")
        lines.append("- 非工时占比: \(Int(o.afterHoursRatio * 100))%")
        lines.append("- 平均响应: \(formatResponseTime(o.avgResponseSeconds))")
        lines.append("- 回复率: \(Int(o.responseRate * 100))%")
        lines.append("- 承诺履约: \(Int(o.commitmentCompletionRate * 100))% (已完成 \(o.fulfilledCommitments) / 超期 \(o.overdueCommitments))")
        lines.append("- 边界分: \(o.boundaryScore)/100 · 非工时工作 \(o.workAfterHoursCount) 条")
        lines.append("")
        lines.append("## 时间节奏")
        lines.append("最忙 \(weekdayNames[o.busiestWeekday]) \(o.busiestHour) 点 · 工作日 \(o.weekdayTotal) / 周末 \(o.weekendTotal)")
        lines.append("")
        if !o.neglectedHighValue.isEmpty {
            lines.append("## 被忽略的重要联系人")
            for item in o.neglectedHighValue.prefix(5) {
                lines.append("- \(item.name) (\(item.role))")
            }
        }
        WeChatLauncher.copyText(lines.joined(separator: "\n"))
    }

    private func formatHoursShort(_ hours: Double) -> String {
        if hours < 1 { return "\(Int(hours * 60))m" }
        if hours < 24 { return "\(Int(hours))h" }
        return "\(Int(hours / 24))d"
    }

    private func formatResponseTime(_ seconds: Double) -> String {
        if seconds <= 0 { return "--" }
        if seconds < 60 { return "\(Int(seconds))秒" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟" }
        return "\(String(format: "%.1f", seconds / 3600))小时"
    }

    private func densityHint(_ ratio: Double) -> String {
        if ratio > 1.3 { return "+\(Int((ratio - 1) * 100))% 近期偏忙" }
        if ratio < 0.7 { return "-\(Int((1 - ratio) * 100))% 近期偏闲" }
        return "节奏正常"
    }

    private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
}
