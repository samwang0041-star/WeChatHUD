import SwiftUI

/// Main chat insight view — macOS native style, white background.
/// Left sidebar: chat list. Right: analysis content with card layout.
struct ChatInsightView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var reader: WeChatReader
    @EnvironmentObject var panelState: PanelState
    @State private var selectedChat: String? = nil
    @State private var searchText = ""
    @State private var selectedDate = Date()
    @State private var allStats: [String: ChatStatsData] = [:]
    @State private var statsLoaded = false
    /// All active sessions (including non-whitelisted), sorted by last message time
    @State private var otherActiveSessions: [SessionEntry] = []

    /// Lightweight entry for non-whitelisted active chats
    struct SessionEntry: Identifiable {
        let id: String  // username
        let displayName: String
        let isGroup: Bool
        let lastTimestamp: Int
        let messageCount: Int
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, maxWidth: 300)
            detailArea
                .frame(minWidth: 540)
        }
        .frame(minWidth: 900, minHeight: 620)
        .padding(.bottom, 16)
        .task {
            computeAllStats()
        }
    }

    // MARK: - Compute stats (pure algorithm, instant)

    private func computeAllStats() {
        let whitelist = store.getWhitelist()
        let whitelistIds = Set(whitelist.map { $0.id })
        let selfUsername = reader.myUsername()
        var stats: [String: ChatStatsData] = [:]

        // Stats for whitelisted chats
        for entry in whitelist {
            do {
                let messages = try reader.getMessages(chatUsername: entry.id, limit: 200)
                let s = ChatInsightEngine.computeStats(
                    messages: messages,
                    selfUsername: selfUsername,
                    chatUsername: entry.id,
                    chatName: entry.displayName,
                    isGroup: entry.isGroup,
                    category: entry.category
                )
                stats[entry.id] = s
            } catch {}
        }

        // Load all sessions to find non-whitelisted active chats
        let todayStart = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        var others: [SessionEntry] = []
        if let sessions = try? reader.getSessions() {
            for s in sessions {
                guard !whitelistIds.contains(s.username) else { continue }
                guard s.lastTimestamp > todayStart else { continue }
                // Filter out system accounts
                guard !s.username.hasPrefix("gh_"),
                      !s.username.contains("@app"),
                      s.username != "filehelper",
                      s.username != "floatbottle",
                      !s.username.hasPrefix("fake_") else { continue }

                let name = reader.displayName(for: s.username)
                // Quick message count for today
                let msgCount = (try? reader.getMessages(chatUsername: s.username, limit: 50))?.filter {
                    $0.createTime > todayStart
                }.count ?? 0
                guard msgCount > 0 else { continue }

                others.append(SessionEntry(
                    id: s.username,
                    displayName: name,
                    isGroup: s.isGroup,
                    lastTimestamp: s.lastTimestamp,
                    messageCount: msgCount
                ))
            }
        }

        allStats = stats
        otherActiveSessions = others.sorted { $0.lastTimestamp > $1.lastTimestamp }
        statsLoaded = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Search
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

            Divider()

            // Chat list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Whitelisted chats — sorted by most recent message
                    let whitelist = filteredWhitelist()
                    if !whitelist.isEmpty {
                        sidebarSection("关注", icon: "star", count: whitelist.count)
                        ForEach(whitelist, id: \.id) { entry in
                            sidebarRow(entry)
                        }
                    }

                    // Other active chats today (not in whitelist)
                    let others = filteredOthers()
                    if !others.isEmpty {
                        sidebarSection("其他活跃", icon: "clock", count: others.count)
                        ForEach(others) { session in
                            otherSessionRow(session)
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
        let filtered: [WhitelistEntry]
        if searchText.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        // Sort by most recent message time (newest first)
        return filtered.sorted { a, b in
            let ta = allStats[a.id]?.messagesByHour.isEmpty == false ? 1 : 0
            let tb = allStats[b.id]?.messagesByHour.isEmpty == false ? 1 : 0
            let ma = allStats[a.id]?.messageCount ?? 0
            let mb = allStats[b.id]?.messageCount ?? 0
            if ta != tb { return ta > tb }  // chats with messages first
            return ma > mb
        }
    }

    private func filteredOthers() -> [SessionEntry] {
        if searchText.isEmpty { return otherActiveSessions }
        return otherActiveSessions.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private func otherSessionRow(_ session: SessionEntry) -> some View {
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

    private func sidebarRow(_ entry: WhitelistEntry) -> some View {
        let isSelected = selectedChat == entry.id
        let hasInsight = monitor.chatInsights[entry.id] != nil
        let insight = monitor.chatInsights[entry.id]
        let stats = allStats[entry.id]

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

                // Message count badge
                if let s = stats, s.messageCount > 0 {
                    Text("\(s.messageCount)")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(4)
                }

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
        if let chatId = selectedChat {
            if let entry = store.getWhitelist().first(where: { $0.id == chatId }) {
                // Whitelisted chat
                ChatInsightDetailView(
                    chatUsername: chatId,
                    chatName: entry.displayName,
                    isGroup: entry.isGroup,
                    category: entry.category,
                    stats: allStats[chatId],
                    result: monitor.chatInsights[chatId],
                    selectedDate: $selectedDate
                )
                .environmentObject(monitor)
                .id(chatId)
            } else if let session = otherActiveSessions.first(where: { $0.id == chatId }) {
                // Non-whitelisted active chat — compute stats on the fly
                let stats = computeStatsForSession(session)
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
                .id(chatId)
            } else {
                overviewDashboard
            }
        } else {
            overviewDashboard
        }
    }

    private func computeStatsForSession(_ session: SessionEntry) -> ChatStatsData? {
        guard let messages = try? reader.getMessages(chatUsername: session.id, limit: 200) else { return nil }
        return ChatInsightEngine.computeStats(
            messages: messages,
            selfUsername: reader.myUsername(),
            chatUsername: session.id,
            chatName: session.displayName,
            isGroup: session.isGroup,
            category: .other
        )
    }

    // MARK: - Overview Dashboard (no chat selected)

    private var overviewDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if monitor.insightLoading {
                    VStack(spacing: 10) {
                        ProgressView(value: monitor.insightProgressFraction)
                            .frame(width: 240)
                        Text(monitor.insightProgress)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else if let briefing = monitor.globalBriefing {
                    globalBriefingContent(briefing)
                } else if statsLoaded {
                    overviewStatsContent
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在加载统计数据...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    @ViewBuilder
    private var overviewStatsContent: some View {
        let totalMessages = allStats.values.reduce(0) { $0 + $1.messageCount }
        let totalMyMessages = allStats.values.reduce(0) { $0 + $1.myMessageCount }
        let totalChats = allStats.count
        let activeChats = allStats.values.filter { $0.messageCount > 0 }.count
        let totalParticipants = Set(allStats.values.flatMap { s in
            s.topSenders.map { $0.name }
        }).count

        // Header
        VStack(alignment: .leading, spacing: 4) {
            Text("全局概览")
                .font(.system(size: 18, weight: .bold))
            Text("白名单聊天的即时统计")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }

        // Stats row
        HStack(spacing: 12) {
            overviewStatCard("消息总数", "\(totalMessages)", "bubble.left.and.bubble.right", .blue)
            overviewStatCard("活跃聊天", "\(activeChats)/\(totalChats)", "message", .purple)
            overviewStatCard("参与者", "\(totalParticipants)", "person.2", .cyan)
            overviewStatCard("我的消息", "\(totalMyMessages)", "pencil.line", .orange)
        }

        // Aggregated hourly chart
        let aggregatedHourly = aggregateHourlyData()
        moduleCardFull("消息时段分布", icon: "clock") {
            hourlyBarChart(aggregatedHourly)
                .frame(height: 100)
        }

        // Message type donut
        HStack(spacing: 12) {
            moduleCard("我的消息占比", icon: "chart.pie") {
                HStack(spacing: 16) {
                    messageDonut(my: totalMyMessages, total: totalMessages)
                    VStack(alignment: .leading, spacing: 4) {
                        legendRow(color: .blue, label: "我的消息", count: totalMyMessages)
                        legendRow(color: .blue.opacity(0.15), label: "其他人", count: totalMessages - totalMyMessages)
                    }
                }
            }

            moduleCard("分类分布", icon: "folder") {
                let workCount = allStats.values.filter { $0.category == .work }.reduce(0) { $0 + $1.messageCount }
                let lifeCount = allStats.values.filter { $0.category == .life }.reduce(0) { $0 + $1.messageCount }
                let otherCount = allStats.values.filter { $0.category == .other }.reduce(0) { $0 + $1.messageCount }
                VStack(alignment: .leading, spacing: 6) {
                    categoryBar("工作", count: workCount, total: totalMessages, color: .blue)
                    categoryBar("生活", count: lifeCount, total: totalMessages, color: .green)
                    categoryBar("其他", count: otherCount, total: totalMessages, color: .orange)
                }
            }
        }

        // Top chats
        moduleCardFull("最活跃聊天", icon: "flame") {
            let sorted = allStats.values.sorted { $0.messageCount > $1.messageCount }
            ForEach(Array(sorted.prefix(5).enumerated()), id: \.offset) { idx, s in
                topChatRow(rank: idx + 1, stats: s)
            }
        }

        // Hint for AI analysis
        if monitor.globalBriefing == nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                Text("点击左下方「全局分析」可生成 AI 全景简报")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.05))
            .cornerRadius(8)
        }
    }

    private func aggregateHourlyData() -> [Int] {
        var result = Array(repeating: 0, count: 24)
        for stats in allStats.values {
            for i in 0..<24 {
                result[i] += stats.messagesByHour[i]
            }
        }
        return result
    }

    // MARK: - Chart components

    private func hourlyBarChart(_ messagesByHour: [Int]) -> some View {
        let maxVal = messagesByHour.max() ?? 1
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                VStack(spacing: 2) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(hour >= 9 && hour <= 18 ? 0.7 : 0.4))
                        .frame(width: 14, height: maxVal > 0 ? CGFloat(messagesByHour[hour]) / CGFloat(maxVal) * 80 : 0)
                    if hour % 3 == 0 {
                        Text("\(hour)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    } else {
                        Text("")
                            .font(.system(size: 8))
                    }
                }
            }
        }
    }

    private func messageDonut(my: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(my) / Double(total) : 0
        return ZStack {
            Circle().stroke(Color.blue.opacity(0.15), lineWidth: 12)
            Circle().trim(from: 0, to: fraction)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 14, weight: .bold))
                Text("我的消息")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 80, height: 80)
    }

    private func legendRow(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    private func categoryBar(_ label: String, count: Int, total: Int, color: Color) -> some View {
        let fraction = total > 0 ? CGFloat(count) / CGFloat(total) : 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.6))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func topChatRow(rank: Int, stats: ChatStatsData) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 16)

            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(categoryColor(stats.category).opacity(0.15))
                    .frame(width: 24, height: 24)
                Text(String(stats.chatName.prefix(1)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(categoryColor(stats.category))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(stats.chatName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(stats.participantCount)人参与 · 平均回复 \(formatResponseTime(stats.avgResponseTimeSeconds))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(stats.messageCount)条")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.blue)
        }
        .padding(.vertical, 4)
    }

    private func formatResponseTime(_ seconds: Double) -> String {
        if seconds <= 0 { return "--" }
        if seconds < 60 { return "\(Int(seconds))秒" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟" }
        return "\(String(format: "%.1f", seconds / 3600))小时"
    }

    // MARK: - Overview components

    private func overviewStatCard(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
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
    private func moduleCard(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func moduleCardFull(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Global briefing (from AI)

    @ViewBuilder
    private func globalBriefingContent(_ briefing: GlobalBriefing) -> some View {
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
            overviewStatCard("消息总数", "\(briefing.stats.totalMessages)", "bubble.left.and.bubble.right.fill", .blue)
            overviewStatCard("活跃群聊", "\(briefing.stats.activeGroups)/\(briefing.stats.totalGroups)", "person.3.fill", .purple)
            overviewStatCard("活跃私聊", "\(briefing.stats.activePrivateChats)", "person.fill", .cyan)
            overviewStatCard("工作占比", "\(Int(briefing.stats.workRatio * 100))%", "briefcase.fill", .orange)
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
            moduleCardFull("需要你行动", icon: "exclamationmark.circle.fill") {
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
        moduleCardFull("建议", icon: "lightbulb.fill") {
            Text(briefing.topSuggestion)
                .font(.system(size: 12))
        }
    }
}
