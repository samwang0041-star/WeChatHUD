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
    @State private var overview: ChatInsightEngine.GlobalOverview?
    @State private var statsLoaded = false
    @State private var selectedScope: Scope = .all
    @State private var selectedWindow: TimeWindow = .month
    /// All active sessions (including non-whitelisted), sorted by last message time
    @State private var otherActiveSessions: [SessionEntry] = []

    enum Scope: String, CaseIterable {
        case whitelist = "白名单"
        case all = "所有人"
    }

    enum TimeWindow: String, CaseIterable {
        case week = "近 7 天"
        case month = "近 30 天"
        case quarter = "近 90 天"
        case all = "全部"

        var seconds: Int? {
            switch self {
            case .week: return 7 * 86400
            case .month: return 30 * 86400
            case .quarter: return 90 * 86400
            case .all: return nil
            }
        }

        var fetchLimit: Int {
            switch self {
            case .week: return 200
            case .month: return 500
            case .quarter: return 1000
            case .all: return 2000
            }
        }
    }

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
            fixStaleDisplayNames()
            computeAllStats()
        }
        .onChange(of: selectedWindow) { _, _ in
            statsLoaded = false
            overview = nil
            computeAllStats()
        }
        .onChange(of: selectedScope) { _, _ in
            statsLoaded = false
            overview = nil
            computeAllStats()
        }
    }

    // MARK: - Compute stats (pure algorithm, instant)

    private func computeAllStats() {
        let whitelist = store.getWhitelist()
        let whitelistIds = Set(whitelist.map { $0.id })
        let whitelistMap = Dictionary(uniqueKeysWithValues: whitelist.map { ($0.id, $0) })
        let selfNames = reader.mySelfNames
        let nowTs = Int(Date().timeIntervalSince1970)
        let cutoff = selectedWindow.seconds.map { nowTs - $0 } ?? 0

        guard let sessions = try? reader.getSessions() else {
            statsLoaded = true
            return
        }

        // Filter sessions
        let filteredSessions = sessions.filter { s in
            guard !s.username.hasPrefix("gh_"),
                  !s.username.contains("@app"),
                  s.username != "filehelper",
                  s.username != "floatbottle",
                  !s.username.hasPrefix("fake_"),
                  !selfNames.contains(s.username) else { return false }
            if selectedScope == .whitelist && !whitelistIds.contains(s.username) { return false }
            if cutoff > 0 && s.lastTimestamp < cutoff { return false }
            return true
        }

        // Bulk scan — one SQL pass per DB file, no per-chat overhead
        let bulkStats = reader.bulkMessageStats(
            chatUsernames: filteredSessions.map(\.username),
            selfNames: selfNames,
            sinceTsEpoch: cutoff
        )

        var stats: [String: ChatStatsData] = [:]
        var others: [SessionEntry] = []
        let sessionMap = Dictionary(uniqueKeysWithValues: filteredSessions.map { ($0.username, $0) })

        for (chatUsername, bulk) in bulkStats {
            let session = sessionMap[chatUsername]
            let isGroup = session?.isGroup ?? chatUsername.contains("@chatroom")
            let isWhitelisted = whitelistIds.contains(chatUsername)
            let entry = whitelistMap[chatUsername]
            let name = entry?.displayName ?? reader.displayName(for: chatUsername)
            let category = entry?.category ?? .other

            let topSenders = bulk.senderCounts
                .sorted { $0.value > $1.value }
                .map { (name: reader.displayName(for: $0.key), count: $0.value) }

            let myCount = bulk.selfCount
            let othersCount = bulk.totalCount - myCount
            let symRatio: Double
            if bulk.totalCount == 0 { symRatio = 1.0 }
            else {
                let minC = Double(min(myCount, othersCount))
                let maxC = Double(max(myCount, othersCount))
                symRatio = maxC > 0 ? minC / maxC : 1.0
            }

            let st = ChatStatsData(
                chatUsername: chatUsername,
                chatName: name,
                isGroup: isGroup,
                category: category,
                messageCount: bulk.totalCount,
                myMessageCount: myCount,
                participantCount: bulk.senderCounts.count,
                messagesByHour: bulk.hourlyBuckets,
                messagesByWeekday: bulk.weekdayBuckets,
                typeCounts: bulk.typeCounts,
                avgResponseTimeSeconds: 0,
                symmetryRatio: symRatio,
                trend7d: 0,
                topSenders: topSenders,
                silentMembers: [],
                ignoredMessages: [],
                selfInitiated: bulk.selfInitiated,
                earliestTs: bulk.earliestTs,
                latestTs: bulk.latestTs
            )
            stats[chatUsername] = st

            if !isWhitelisted {
                others.append(SessionEntry(
                    id: chatUsername,
                    displayName: name,
                    isGroup: isGroup,
                    lastTimestamp: session?.lastTimestamp ?? 0,
                    messageCount: bulk.totalCount
                ))
            }
        }

        allStats = stats
        otherActiveSessions = others.sorted { $0.messageCount > $1.messageCount }

        let contacts = store.loadContacts()
        let commitments = store.loadCommitments(status: nil)
        let vipSet = Set(store.loadVIPUsernames())
        let pendingAsks = store.loadPendingAsks(bucket: nil, status: .pending).count
        let urgentAsks = store.loadPendingAsks(bucket: nil, status: .pending).filter { $0.urgency == .urgent }.count
        let recalledMsgs = store.loadRecalledMessages(since: cutoff, limit: 1000).count
        let days = selectedWindow.seconds.map { $0 / 86400 } ?? 365
        overview = ChatInsightEngine.computeGlobalOverview(
            allStats: stats,
            contacts: contacts,
            commitments: commitments,
            replyDebtItems: monitor.replyDebtItems,
            vipUsernames: vipSet,
            selfUsernames: selfNames,
            pendingAskCount: pendingAsks,
            urgentAskCount: urgentAsks,
            recalledMessageCount: recalledMsgs,
            windowDays: days
        )
        statsLoaded = true
    }

    /// Fix whitelist entries whose displayName is a raw chatroom ID or wxid.
    private func fixStaleDisplayNames() {
        let whitelist = store.getWhitelist()
        for entry in whitelist {
            let name = entry.displayName
            if name.contains("@chatroom") || name.hasPrefix("wxid_") {
                let resolved = reader.displayName(for: entry.id)
                if resolved != entry.id && resolved != name {
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
        let me = reader.myUsername()
        return ChatInsightEngine.computeStats(
            messages: messages,
            selfUsername: me,
            selfDisplayName: reader.displayName(for: me),
            selfNames: reader.mySelfNames,
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

    private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    @ViewBuilder
    private var overviewStatsContent: some View {
        if let o = overview {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("全局概览")
                        .font(.system(size: 18, weight: .bold))
                    Text("\(selectedScope.rawValue) · \(selectedWindow.rawValue)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("", selection: $selectedScope) {
                        ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 160)
                    Picker("", selection: $selectedWindow) {
                        ForEach(TimeWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 280)
                }
            }

            // ===== D1: Communication Profile =====
            HStack(spacing: 12) {
                overviewStatCard("消息总数", "\(o.totalMessages)", "bubble.left.and.bubble.right", .blue)
                overviewStatCard("活跃聊天", "\(o.activeChats)/\(o.totalChats)", "message", .purple)
                overviewStatCard("参与者", "\(o.participants)", "person.2", .cyan)
                overviewStatCard("我的消息", "\(o.myMessages)", "pencil.line", .orange)
            }

            HStack(spacing: 12) {
                overviewStatCard("发起率", "\(Int(o.initiationRate * 100))%", "arrow.up.right", .teal)
                overviewStatCard("群聊", "\(o.groupChats)个/\(o.groupMessages)条", "person.3", .indigo)
                overviewStatCard("私聊", "\(o.privateChats)个/\(o.privateMessages)条", "person", .mint)
                overviewStatCard("我的占比", "\(Int(o.myRatio * 100))%", "chart.pie", .blue)
            }

            // Message type distribution
            if !o.typeDistribution.isEmpty {
                moduleCardFull("消息类型", icon: "doc.text") {
                    HStack(spacing: 12) {
                        ForEach(o.typeDistribution.prefix(5), id: \.type) { item in
                            VStack(spacing: 2) {
                                Text("\(item.count)").font(.system(size: 12, weight: .bold).monospacedDigit())
                                Text(item.type).font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            // ===== D2: Time Patterns =====
            moduleCardFull("时段分布", icon: "clock") {
                hourlyBarChart(o.messagesByHour).frame(height: 100)
                HStack(spacing: 16) {
                    timeSlotChip("早间 6-9", count: o.morningMessages, color: .orange)
                    timeSlotChip("工作 9-18", count: o.workHourMessages, color: .blue)
                    timeSlotChip("晚间 18-23", count: o.eveningMessages, color: .purple)
                    timeSlotChip("深夜 23-6", count: o.nightMessages, color: .red)
                    Spacer()
                    Text("非工时 \(Int(o.afterHoursRatio * 100))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(o.afterHoursRatio > 0.4 ? .red : .secondary)
                }
            }

            // Weekday distribution
            if o.messagesByWeekday.contains(where: { $0 > 0 }) {
                moduleCardFull("星期分布", icon: "calendar") {
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            let val = o.messagesByWeekday[i]
                            let maxVal = max(o.messagesByWeekday.max() ?? 1, 1)
                            VStack(spacing: 4) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill((i == 0 || i == 6) ? Color.orange.opacity(0.6) : Color.blue.opacity(0.6))
                                    .frame(width: 30, height: CGFloat(val) / CGFloat(maxVal) * 60)
                                Text(weekdayNames[i]).font(.system(size: 9)).foregroundColor(.secondary)
                            }
                        }
                    }.frame(height: 80)
                    HStack {
                        Text("工作日 \(o.weekdayTotal)条").font(.system(size: 10)).foregroundColor(.blue)
                        Spacer()
                        Text("周末 \(o.weekendTotal)条").font(.system(size: 10)).foregroundColor(.orange)
                        Spacer()
                        Text("最忙 \(weekdayNames[o.busiestWeekday])").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }

            // ===== D3: Response Health =====
            HStack(spacing: 12) {
                overviewStatCard("平均响应", formatResponseTime(o.avgResponseSeconds), "timer", .green)
                overviewStatCard("回复率", "\(Int(o.responseRate * 100))%", "arrowshape.turn.up.left", .teal)
                overviewStatCard("待回超时", "\(o.overdueChats)", "exclamationmark.circle", o.overdueChats > 0 ? .red : .gray)
                overviewStatCard("待办承诺", "\(o.pendingCommitments)", "checkmark.circle", o.overdueCommitments > 0 ? .red : .green)
            }

            // ===== D4: Relationship Network =====
            HStack(spacing: 12) {
                moduleCard("联系人层级", icon: "person.3") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(o.tierDistribution, id: \.tier) { item in
                            HStack { Text(item.tier).font(.system(size: 11)).foregroundColor(.secondary); Spacer(); Text("\(item.count)").font(.system(size: 11, weight: .medium).monospacedDigit()) }
                        }
                    }
                }
                moduleCard("角色分布", icon: "person.text.rectangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(o.roleDistribution.prefix(6), id: \.role) { item in
                            HStack { Text(item.role).font(.system(size: 11)).foregroundColor(.secondary); Spacer(); Text("\(item.count)").font(.system(size: 11, weight: .medium).monospacedDigit()) }
                        }
                    }
                }
            }

            if let sym = o.mostSymmetric, let asym = o.leastSymmetric {
                HStack(spacing: 12) {
                    moduleCard("沟通最均衡", icon: "equal.circle") {
                        VStack(alignment: .leading, spacing: 2) { Text(sym.name).font(.system(size: 12, weight: .medium)); Text("对等度 \(Int(sym.ratio * 100))%").font(.system(size: 10)).foregroundColor(.green) }
                    }
                    moduleCard("沟通最失衡", icon: "arrow.left.arrow.right") {
                        VStack(alignment: .leading, spacing: 2) { Text(asym.name).font(.system(size: 12, weight: .medium)); Text("对等度 \(Int(asym.ratio * 100))%").font(.system(size: 10)).foregroundColor(.orange) }
                    }
                }
            }

            // ===== D5: Work/Life Balance =====
            HStack(spacing: 12) {
                moduleCard("工作/生活", icon: "briefcase") {
                    VStack(alignment: .leading, spacing: 6) {
                        categoryBar("工作", count: o.workMessages, total: o.totalMessages, color: .blue)
                        categoryBar("生活", count: o.lifeMessages, total: o.totalMessages, color: .green)
                        categoryBar("其他", count: o.otherMessages, total: o.totalMessages, color: .orange)
                    }
                }
                moduleCard("边界健康", icon: "shield.checkered") {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(Color.gray.opacity(0.2), lineWidth: 8)
                            Circle().trim(from: 0, to: Double(o.boundaryScore) / 100)
                                .stroke(o.boundaryScore >= 70 ? Color.green : o.boundaryScore >= 40 ? Color.orange : Color.red, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(o.boundaryScore)").font(.system(size: 16, weight: .bold))
                        }.frame(width: 60, height: 60)
                        Text("非工时工作 \(o.workAfterHoursCount)条")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }

            // ===== D6: Influence =====
            moduleCardFull("影响力分布", icon: "chart.bar") {
                HStack(spacing: 12) {
                    influencePill("上级", count: o.superiorMessages, color: .red)
                    influencePill("同级", count: o.peerMessages, color: .blue)
                    influencePill("外部", count: o.externalMessages, color: .orange)
                    influencePill("私人", count: o.personalMessages, color: .green)
                    Spacer()
                    Text("活跃群 \(o.activeGroupCount)个 · @我 \(o.atMentionChats)次")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            // ===== D7: Commitment Reliability =====
            if o.pendingCommitments + o.overdueCommitments + o.fulfilledCommitments > 0 {
                moduleCardFull("承诺可靠性", icon: "checkmark.shield") {
                    HStack(spacing: 16) {
                        commitmentPill("待办", count: o.pendingCommitments, color: .blue)
                        commitmentPill("超期", count: o.overdueCommitments, color: .red)
                        commitmentPill("已完成", count: o.fulfilledCommitments, color: .green)
                        Spacer()
                        Text("完成率 \(Int(o.commitmentCompletionRate * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(o.commitmentCompletionRate >= 0.8 ? .green : .orange)
                    }
                }
            }

            // ===== D8: Attention Distribution =====
            moduleCardFull("注意力分配", icon: "eye") {
                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text("\(Int(o.vipMessageRatio * 100))%").font(.system(size: 14, weight: .bold))
                        Text("VIP 占比").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(o.topTimeBlackHoles.prefix(3), id: \.name) { item in
                            HStack {
                                Text(item.name).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Text("\(item.count)条").font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if !o.neglectedHighValue.isEmpty {
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.orange)
                        Text("被忽略的重要联系人：\(o.neglectedHighValue.map(\.name).prefix(3).joined(separator: "、"))")
                            .font(.system(size: 10)).foregroundColor(.orange)
                    }
                }
            }

            // ===== D9: One-way + Top chats =====
            if !o.oneWayChats.isEmpty {
                moduleCardFull("单向沟通 (对方远多于你)", icon: "arrow.down.circle") {
                    ForEach(o.oneWayChats.prefix(3), id: \.name) { chat in
                        HStack {
                            Text(chat.name).font(.system(size: 12)).lineLimit(1); Spacer()
                            Text("对方 \(chat.theirCount) / 你 \(chat.myCount)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }.padding(.vertical, 2)
                    }
                }
            }

            moduleCardFull("最活跃聊天", icon: "flame") {
                let sorted = allStats.values.sorted { $0.messageCount > $1.messageCount }
                ForEach(Array(sorted.prefix(5).enumerated()), id: \.offset) { idx, s in
                    topChatRow(rank: idx + 1, stats: s)
                }
            }

            // ===== D10: Pressure Signals =====
            moduleCardFull("压力信号", icon: "waveform.path.ecg") {
                HStack(spacing: 16) {
                    pressurePill("待处理请求", count: o.pendingAsks, threshold: 5)
                    pressurePill("紧急请求", count: o.urgentAsks, threshold: 1)
                    pressurePill("撤回消息", count: o.recalledMessages, threshold: 3)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        let density = o.recentDensityRatio
                        Text(density > 1.3 ? "近期偏忙" : density < 0.7 ? "近期偏闲" : "节奏正常")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(density > 1.3 ? .red : density < 0.7 ? .green : .secondary)
                        Text("7日/均值 \(String(format: "%.0f%%", density * 100))")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }

            // Hint for AI analysis
            if monitor.globalBriefing == nil {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.orange)
                    Text("点击左下方「全局分析」可生成 AI 全景简报").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.05)).cornerRadius(8)
            }
        }
    }

    private func timeSlotChip(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func influencePill(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundColor(color)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    private func pressurePill(_ label: String, count: Int, threshold: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(count >= threshold ? .red : .secondary)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    private func commitmentPill(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(color)
        }
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
