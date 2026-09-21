import SwiftUI

struct InsightOverviewDashboard: View {
    @ObservedObject var insightStore: InsightStore
    @ObservedObject var insightCoordinator: InsightCoordinator
    @ObservedObject var store: HUDStore
    @EnvironmentObject var panelState: PanelState
    let onRefresh: () -> Void
    let onSelectChat: (String) -> Void
    let onExpandModule: (String) -> Void
    @Binding var selectedDate: Date
    @Binding var expandedRadarFindingID: String?
    @Binding var expandedModules: Set<String>
    @State private var copyFeedback: CopyFeedback = .idle
    @State private var copyGeneration = UUID()

    private enum CopyFeedback: Equatable {
        case idle, copied, failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let overview = insightStore.overview, insightStore.statsLoaded {
                    overviewHeader
                    if insightCoordinator.insightLoading {
                        inlineLoadingBanner
                    }
                    if overview.totalMessages == 0 {
                        // Telling someone to connect WeChat when they have
                        // watched chats and just picked an empty range is a
                        // wrong instruction. The whitelist is the signal.
                       let followRead = store.whitelistAllRead()
                       let followListUnreadable = {
                           if case .unreadable = followRead { return true }
                           return false
                       }()
                       let hasWatchedChats: Bool = {
                           if case .value(let entries) = followRead { return !entries.isEmpty }
                           return false
                       }()
                       VStack(spacing: 12) {
                           ContentUnavailableView("这里还没有可以回顾的聊天", systemImage: "bubble.left.and.text.bubble.right",
                                description: Text(followListUnreadable
                                    ? "暂时读不到关注名单，这一页的范围先不要采信。"
                                    : hasWatchedChats
                                   ? "换一个时间范围或日期再看看。这里空着，不代表你没有该回或该做的事。"
                                   : "先连上微信，再选要关注的对话。空着不代表你没有该回或该做的事。"))
                            if followListUnreadable {
                                Button("再试一次") { onRefresh() }
                                    .buttonStyle(CompanionPressStyle())
                                    .foregroundStyle(CompanionPalette.jadeInk)
                            } else if !hasWatchedChats {
                                Button("关注谁") {
                                    panelState.pendingSettingsTab = SettingsView.Tab.contacts.rawValue
                                }
                                .buttonStyle(CompanionPressStyle())
                                .foregroundStyle(CompanionPalette.jadeInk)
                                .accessibilityLabel("去选要关注的对话")
                            }
                            else {
                                HStack(spacing: 12) {
                                    if insightStore.selectedWindow != .today || !Calendar.current.isDateInToday(selectedDate) {
                                        Button("看今天") {
                                            withMotion(CompanionMotion.pageChange()) {
                                                insightStore.selectedWindow = .today
                                                selectedDate = Date()
                                            }
                                        }
                                        .buttonStyle(CompanionPressStyle())
                                        .foregroundStyle(CompanionPalette.jadeInk)
                                        .accessibilityLabel("看今天的聊天回顾")
                                    } else {
                                        Button("近 7 天") {
                                            withMotion(CompanionMotion.pageChange()) {
                                                insightStore.selectedWindow = .week
                                            }
                                        }
                                        .buttonStyle(CompanionPressStyle())
                                        .foregroundStyle(CompanionPalette.jadeInk)
                                        .accessibilityLabel("看近 7 天的聊天回顾")
                                    }
                                    if insightStore.selectedScope != .all {
                                        Button("所有人") {
                                            withMotion(CompanionMotion.pageChange()) {
                                                insightStore.selectedScope = .all
                                            }
                                        }
                                        .buttonStyle(CompanionPressStyle())
                                        .foregroundStyle(CompanionPalette.jadeInk)
                                        .accessibilityLabel("看所有人的聊天回顾")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 48)
                    } else {
                   InsightRadarSection(
                       chatInsights: insightCoordinator.chatInsights,
                        chatNames: insightStore.chatNameMap(whitelist: {
                            switch store.whitelistAllRead() {
                            case .value(let entries): return entries
                            case .unreadable: return []
                            }
                        }()),
                        overview: overview,
                        briefing: insightCoordinator.globalBriefing,
                        expandedFindingID: $expandedRadarFindingID,
                        onOpenChat: onSelectChat,
                        onExpandModule: onExpandModule
                    )
                    RelationshipRadarCard(snapshots: store.loadAllRelationshipRadarSnapshots(limit: 6))
                    InsightAttentionBar(
                        overview: overview,
                        briefing: insightCoordinator.globalBriefing,
                        onJumpToChat: onSelectChat
                    )
                    InsightHeroSection(
                        briefing: insightCoordinator.globalBriefing,
                        generatedAt: insightCoordinator.briefingGeneratedAt,
                        isLoading: insightCoordinator.insightLoading,
                        onGenerate: onRefresh
                    )
                    todayFocusSection(overview: overview)
                    quietNoiseSection(overview: overview)
                    collapsibleMetrics(overview)
                    collapsibleTimePattern(overview)
                    collapsibleRelationships(overview)
                    collapsibleWorkLife(overview)
                    collapsibleTopChats()
                    collapsiblePressure(overview)
                    }
                } else {
                    initialLoadingState
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    private var insightRefreshHoldReason: String? {
        if insightCoordinator.insightLoading { return "正在分析…" }
        if (insightStore.overview?.totalMessages ?? 0) == 0 { return "还没有消息可以分析" }
        return nil
    }

    private var insightCopyHoldReason: String? {
        if (insightStore.overview?.totalMessages ?? 0) == 0 { return "还没有消息可以复制" }
        return nil
    }

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(insightStore.selectedWindow.overviewHeading)
                    .workspaceTitle()
                // The scope and the window are what the two segmented pickers
                // to the right of this line *are* — restating them here said
                // 「所有人 · 今天」 twice within 200pt. Only the counts are new.
                // 「还没算」 and 「算出来是 0」 are different answers, and `?? 0`
                // prints the second one for both. A user who opens this page before
                // the first overview lands reads 「0 个活跃对话 · 0 条消息」 as a
                // measurement of an empty week and closes it — instead of pressing
                // the 刷新 that would have produced the numbers.
                Text(InsightOverviewCounts.text(for: insightStore.overview))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            // Yield space instead of demanding it. Without this the leading
            // block hugged its ideal width and pushed the 280pt range picker
            // past the window's right edge — 「全部」 was cut mid-glyph at the
            // 900pt minimum width the app itself declares as its floor.
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("", selection: $insightStore.selectedScope) {
                        ForEach(InsightScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    Button(action: onRefresh) {
                        Image(systemName: insightCoordinator.insightLoading ? "stop.circle" : "arrow.clockwise")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CompanionIconButtonStyle())
                    .disabled(insightRefreshHoldReason != nil)
                    .help(insightRefreshHoldReason ?? "重新生成今日 AI 态势")
                    .accessibilityHint(insightRefreshHoldReason ?? "")
                    Button(action: copyOverviewReport) {
                        overviewCopyIcon
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CompanionIconButtonStyle())
                    .disabled(insightCopyHoldReason != nil)
                    .help(overviewCopyHelp)
                    .accessibilityLabel("复制为 Markdown 总结")
                    .accessibilityHint(overviewCopyHelp)
                    .accessibilityValue(overviewCopyValue)
                    .companionAnimation(CompanionMotion.ease(), value: copyFeedback)
                }
                Picker("", selection: $insightStore.selectedWindow) {
                    ForEach(InsightTimeWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .fixedSize()
        }
        // The row is inside a vertical ScrollView, so a horizontal overflow is
        // clipped rather than scrolled, and the row's own ideal width (title +
        // 280pt picker) is wider than the window at its 900pt floor. Accepting
        // the proposed width is what makes the leading block yield instead of
        // pushing 「全部」 off the edge.
        .frame(maxWidth: .infinity)
    }

    private var inlineLoadingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 正在分析…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(insightCoordinator.insightProgress)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            ProgressView(value: insightCoordinator.insightProgressFraction)
                .frame(width: 120)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
    }

    private var initialLoadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("正在加载统计数据…")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private func todayFocusSection(overview: ChatInsightEngine.GlobalOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "今天先处理", subtitle: "按风险、等待和重要度排序，不按消息量堆列表", icon: "scope")

            let aiItems = (insightCoordinator.globalBriefing?.actionRequired ?? [])
                .filter { isConcreteFocusSource($0.source) }
            if !aiItems.isEmpty {
                ForEach(Array(aiItems.prefix(3).enumerated()), id: \.offset) { _, item in
                    decisionCard(title: item.source, subtitle: item.what, meta: item.urgency, color: item.urgency == "高" ? .red : item.urgency == "中" ? .orange : .blue, icon: "arrowshape.turn.up.right.fill", action: { onSelectChat(item.chatUsername ?? item.source) })
                }
            }

            if !overview.neglectedHighValue.isEmpty {
                ForEach(Array(overview.neglectedHighValue.prefix(aiItems.isEmpty ? 3 : 2).enumerated()), id: \.offset) { _, item in
                    decisionCard(title: item.name, subtitle: "重要联系人近期互动偏少", meta: item.role, color: .orange, icon: "person.crop.circle.badge.exclamationmark", action: { onSelectChat(item.chatUsername) })
                }
            }

            if aiItems.isEmpty && overview.neglectedHighValue.isEmpty {
                ForEach(Array(overview.topTimeBlackHoles.prefix(3).enumerated()), id: \.offset) { _, item in
                    decisionCard(title: item.name, subtitle: "今天占用注意力较多，适合快速确认是否需要跟进", meta: "\(item.count) 条消息", color: .blue, icon: "bubble.left.and.text.bubble.right", action: { onSelectChat(item.chatUsername) })
                }
            }
        }
        .padding(14)
        .companionPanelFace(radius: 12)
    }

    private func quietNoiseSection(overview: ChatInsightEngine.GlobalOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "可以先放一放", subtitle: "把低风险活跃对话显式降噪，减少你反复扫列表", icon: "moon.zzz")

            let actionSources = Set((insightCoordinator.globalBriefing?.actionRequired ?? []).map(\.source))
            let candidates = insightStore.allStats.values
                .filter { stats in
                    stats.messageCount > 0
                    && !actionSources.contains(stats.chatName)
                    && !overview.neglectedHighValue.contains(where: { $0.name == stats.chatName })
                }
                .sorted { $0.messageCount > $1.messageCount }
                .prefix(3)

            if candidates.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("暂时没有明确可忽略的活跃对话。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ForEach(Array(candidates), id: \.chatUsername) { stats in
                    Button(action: { onSelectChat(stats.chatUsername) }) {
                        HStack(spacing: 8) {
                            Image(systemName: stats.isGroup ? "person.3" : "person")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stats.chatName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text("\(stats.messageCount) 条消息 · 没有强行动信号")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.55))
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CompanionRowPressStyle())
                    .accessibilityLabel("查看 \(stats.chatName)")
                }
            }
        }
        .padding(14)
        .companionPanelFace(radius: 12)
    }

    private func collapsibleMetrics(_ overview: ChatInsightEngine.GlobalOverview) -> some View {
        collapsibleSection(id: "metrics", title: "趋势指标", icon: "chart.bar.xaxis", summary: "消息 \(overview.totalMessages) · 回复率 \(Int(overview.responseRate * 100))% · \(overview.boundarySummary)") {
            InsightKPIGrid(overview: overview)
        }
    }

    private func collapsibleTimePattern(_ o: ChatInsightEngine.GlobalOverview) -> some View {
        collapsibleSection(id: "time", title: "时间节奏", icon: "clock", summary: "最忙 \(weekdayNames[o.busiestWeekday]) \(o.busiestHour) 点 · 工作日 \(o.weekdayTotal) / 周末 \(o.weekendTotal)") {
            VStack(alignment: .leading, spacing: 12) {
                hourlyBarChart(o.messagesByHour).frame(height: 90)
                HStack(spacing: 12) {
                    timeSlotChip("早 6-9", count: o.morningMessages, color: .orange)
                    timeSlotChip("工作 9-18", count: o.workHourMessages, color: .blue)
                    timeSlotChip("晚 18-23", count: o.eveningMessages, color: .purple)
                    timeSlotChip("夜 23-6", count: o.nightMessages, color: .red)
                }
                if o.messagesByWeekday.contains(where: { $0 > 0 }) {
                    Divider()
                    weekdayBars(o.messagesByWeekday).frame(height: 70)
                }
            }
        }
    }

    private func collapsibleRelationships(_ o: ChatInsightEngine.GlobalOverview) -> some View {
        let topTier = o.tierDistribution.first?.tier
        let topRole = o.roleDistribution.first?.role
        // Both fields fell back to an em dash, so the collapsed row read
        // 「主要对象 — · 最多 —」: two labels, two placeholders, no information.
        // Say what is missing instead of drawing a dash under a label.
        let summary = (topTier == nil && topRole == nil)
            ? "消息还不够分出主次"
            : "主要对象 \(topTier ?? "—") · 最多 \(topRole ?? "—")"
        return collapsibleSection(id: "relationships", title: "关系分布", icon: "person.3", summary: summary) {
            VStack(alignment: .leading, spacing: 10) {
                // Both tables render their column header before their rows, so
                // with no distribution data the expanded panel was just
                // 「层级」 and 「角色」 floating over blank space — the header is
                // the one part of an empty table that still takes the screen.
                if !o.tierDistribution.isEmpty || !o.roleDistribution.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        if !o.tierDistribution.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("层级").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                ForEach(o.tierDistribution, id: \.tier) { row in
                                    tinyRow(label: row.tier, count: row.count)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !o.roleDistribution.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("角色").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                ForEach(o.roleDistribution.prefix(6), id: \.role) { row in
                                    tinyRow(label: row.role, count: row.count)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let sym = o.mostSymmetric, let asym = o.leastSymmetric {
                    Divider()
                    HStack(spacing: 10) {
                        relRow(label: "最均衡", name: sym.name, ratio: sym.ratio, good: true, chatUsername: sym.chatUsername)
                        relRow(label: "最失衡", name: asym.name, ratio: asym.ratio, good: false, chatUsername: asym.chatUsername)
                    }
                }
                if !o.oneWayChats.isEmpty {
                    Divider()
                    Text("单向沟通 (对方远多于你)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(o.oneWayChats.prefix(3), id: \.name) { c in
                        Button(action: { onSelectChat(c.chatUsername) }) {
                            HStack {
                                Text(c.name).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("对方 \(c.theirCount) / 你 \(c.myCount)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.55))
                            }
                            .padding(.vertical, 1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CompanionRowPressStyle())
                        .accessibilityLabel("查看 \(c.name)")
                    }
                }
            }
        }
    }

    private func collapsibleWorkLife(_ o: ChatInsightEngine.GlobalOverview) -> some View {
        let workPct = o.totalMessages > 0 ? Int(Double(o.workMessages) / Double(o.totalMessages) * 100) : 0
        let lifePct = o.totalMessages > 0 ? Int(Double(o.lifeMessages) / Double(o.totalMessages) * 100) : 0
        // Same rule as the bars below: a category with nothing in it is not a
        // percentage worth a slot in the headline.
        let categorySummary = [
            o.workMessages > 0 ? "工作 \(workPct)%" : nil,
            o.lifeMessages > 0 ? "生活 \(lifePct)%" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return collapsibleSection(id: "work-life", title: "工作 / 生活", icon: "briefcase", summary: "\(categorySummary) · \(o.boundarySummary)") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    // A zero row is an empty track and a 「0」: it costs the same
                    // height as the row that carries all the data and says less.
                    if o.workMessages > 0 {
                        categoryBar("工作", count: o.workMessages, total: o.totalMessages, color: .blue)
                    }
                    if o.lifeMessages > 0 {
                        categoryBar("生活", count: o.lifeMessages, total: o.totalMessages, color: .green)
                    }
                    if o.otherMessages > 0 {
                        categoryBar("其他", count: o.otherMessages, total: o.totalMessages, color: .orange)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    // The ring filled with `boundaryScore` (= 100 − after-hours
                    // share) while the line under it counted after-hours
                    // messages: a fuller ring meant *better* next to a number
                    // where bigger is worse, and the bare "70" in the middle
                    // could not be checked against anything. Gauge, centre and
                    // caption now describe one quantity, and the colour
                    // thresholds keep the same verdicts as before (≤30% green,
                    // ≤60% orange).
                    let share = o.workMessages > 0
                        ? Double(o.workAfterHoursCount) / Double(o.workMessages) : 0
                    ZStack {
                        Circle().stroke(Color.gray.opacity(0.15), lineWidth: 7)
                        Circle().trim(from: 0, to: share)
                            .stroke(
                                share <= 0.3 ? Color.green : share <= 0.6 ? Color.orange : Color.red,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .frame(width: 56, height: 56)
                    Text("\(o.workAfterHoursCount) / \(o.workMessages) 条在下班后")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func collapsibleTopChats() -> some View {
        collapsibleSection(id: "top", title: "最活跃聊天", icon: "flame", summary: "按消息量 TOP 5") {
            let sorted = insightStore.allStats.values.sorted { $0.messageCount > $1.messageCount }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(sorted.prefix(5).enumerated()), id: \.offset) { idx, s in
                    Button(action: { onSelectChat(s.chatUsername) }) {
                        topChatRow(rank: idx + 1, stats: s)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CompanionRowPressStyle())
                }
            }
        }
    }

    private func collapsiblePressure(_ o: ChatInsightEngine.GlobalOverview) -> some View {
        collapsibleSection(id: "pressure", title: "压力信号", icon: "waveform.path.ecg", summary: "待处理请求 \(o.pendingAsks) · 紧急请求 \(o.urgentAsks) · 撤回消息 \(o.recalledMessages)") {
            HStack(spacing: 16) {
                pressurePill("待处理请求", count: o.pendingAsks, threshold: 5)
                pressurePill("紧急请求", count: o.urgentAsks, threshold: 1)
                pressurePill("撤回消息", count: o.recalledMessages, threshold: 3)
                Spacer()
            }
        }
    }

    private func collapsibleSection<Content: View>(id: String, title: String, icon: String, summary: String, @ViewBuilder content: () -> Content) -> some View {
        // `--preview-expand-modules` opens every section from here rather than
        // seeding a list of ids: a coverage list goes stale the moment someone
        // adds a section, and the stale list would quietly leave the new module
        // — and whatever copy it carries — unphotographed.
        let expanded = PreviewRuntime.expandsAllOverviewModules || expandedModules.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withMotion(CompanionMotion.ease()) {
                    if expanded { expandedModules.remove(id) }
                    else { expandedModules.insert(id) }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(CompanionRowPressStyle())
            if expanded {
                Divider().background(Color.primary.opacity(0.05))
                content()
                    .padding(14)
                    .transition(.companionStatusReveal)
            }
        }
        .companionPanelFace()
        .companionAnimation(CompanionMotion.ease(), value: expanded)
    }

    private func isConcreteFocusSource(_ source: String) -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        let nonConcreteSources: Set<String> = ["全局", "系统", "简报", "总结", "未知", "无", "n/a", "null"]
        return !nonConcreteSources.contains(text)
    }

    private func sectionHeader(title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func decisionCard(title: String, subtitle: String, meta: String, color: Color, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(meta)
                            .font(.system(size: 10))
                            .foregroundColor(color)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.55))
                    .padding(.top, 7)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
            .cornerRadius(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompanionPressStyle())
    }

    private func tinyRow(label: String, count: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    private func relRow(label: String, name: String, ratio: Double, good: Bool, chatUsername: String) -> some View {
        Button(action: { onSelectChat(chatUsername) }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("对等度 \(Int(ratio * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(good ? .green : .orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompanionRowPressStyle())
        .accessibilityLabel("查看 \(name)")
    }

    private func weekdayBars(_ messagesByWeekday: [Int]) -> some View {
        let messagesByWeekday = MessageHelpers.buckets(messagesByWeekday, count: 7)
        let maxVal = max(messagesByWeekday.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let val = messagesByWeekday[i]
                VStack(spacing: 3) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill((i == 0 || i == 6) ? Color.orange.opacity(0.6) : Color.blue.opacity(0.6))
                        .frame(width: 26, height: CGFloat(val) / CGFloat(maxVal) * 48)
                    Text(weekdayNames[i])
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func hourlyBarChart(_ messagesByHour: [Int]) -> some View {
        let messagesByHour = MessageHelpers.buckets(messagesByHour, count: 24)
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
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("")
                            .font(.system(size: 10))
                    }
                }
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
                if let monogram = ContactIdentityIndex.avatarMonogram(from: stats.chatName) {
                    Text(monogram)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(categoryColor(stats.category))
                } else {
                    Image(systemName: stats.isGroup ? "person.3" : "person")
                        .font(.system(size: 10))
                        .foregroundColor(categoryColor(stats.category))
                }
           }

            VStack(alignment: .leading, spacing: 1) {
                Text(stats.chatName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(stats.participantCount) 人参与 · 平均回复 \(RelativeTimeFormatter.durationLabel(stats.avgResponseTimeSeconds))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(stats.messageCount) 条")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.blue)
        }
        .padding(.vertical, 4)
    }

    private func pressurePill(_ label: String, count: Int, threshold: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(count >= threshold ? .red : .secondary)
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func categoryColor(_ cat: WhitelistCategory) -> Color {
        switch cat {
        case .work: return .blue
        case .life: return .green
        case .other: return .orange
        }
    }

    @ViewBuilder
    private var overviewCopyIcon: some View {
        switch copyFeedback {
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(CompanionPalette.jadeInk)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .idle:
            Image(systemName: "doc.on.doc")
        }
    }

    private var overviewCopyHelp: String {
        if let hold = insightCopyHoldReason { return hold }
        switch copyFeedback {
        case .copied: return CompanionInteractionCopy.copied
        case .failed: return CompanionInteractionCopy.copyFailed
        case .idle: return "复制为 Markdown 总结"
        }
    }

    private var overviewCopyValue: String {
        switch copyFeedback {
        case .copied: return CompanionInteractionCopy.copied
        case .failed: return CompanionInteractionCopy.copyFailed
        case .idle: return ""
        }
    }

    private func copyOverviewReport() {
        let markdown = InsightOverviewReport.markdown(
            overview: insightStore.overview,
            briefing: insightCoordinator.globalBriefing
        )
        let token = UUID()
        copyGeneration = token
        if CompanionClipboard.write(markdown) {
            copyFeedback = .copied
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copyGeneration == token { copyFeedback = .idle }
            }
        } else {
            copyFeedback = .failed
        }
    }

    private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
}

/// 「还没算」 and 「算出来是 0」 are different answers, and `?? 0` prints the second
/// one for both. A user who opens the overview before the first computation lands
/// reads 「0 个活跃对话 · 0 条消息」 as a measurement of an empty week and closes the
/// page — instead of pressing the 刷新 that would have produced the numbers.
enum InsightOverviewCounts {
    static let pending = "统计还没算好 · 点右侧刷新生成"

    static func text(activeChats: Int, totalMessages: Int) -> String {
        "\(activeChats) 个活跃对话 · \(totalMessages) 条消息"
    }

    static func text(for overview: ChatInsightEngine.GlobalOverview?) -> String {
        guard let overview else { return pending }
        return text(activeChats: overview.activeChats, totalMessages: overview.totalMessages)
    }
}
