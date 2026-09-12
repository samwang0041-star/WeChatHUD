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
            if selectedChat == nil {
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
        ContentUnavailableView(
            "选一个对话",
            systemImage: "bubble.left.and.text.bubble.right",
            description: Text("看这段时间里发生了什么，或回到原文和待办。")
        )
    }
}
