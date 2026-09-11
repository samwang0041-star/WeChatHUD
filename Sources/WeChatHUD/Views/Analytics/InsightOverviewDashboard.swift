import SwiftUI

struct InsightOverviewDashboard: View {
    @ObservedObject var insightStore: InsightStore
    @ObservedObject var insightCoordinator: InsightCoordinator
    @ObservedObject var store: HUDStore
    let onRefresh: () -> Void
    let onCopyReport: () -> Void
    let onSelectChat: (String) -> Void
    let onExpandModule: (String) -> Void
    @Binding var selectedDate: Date
    @Binding var expandedRadarFindingID: String?
    @Binding var expandedModules: Set<String>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let overview = insightStore.overview, insightStore.statsLoaded {
                    overviewHeader
                    if insightCoordinator.insightLoading {
                        inlineLoadingBanner
                    }
                    if overview.totalMessages == 0 {
                        ContentUnavailableView("这里还没有可以回顾的聊天", systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("先连上微信，再选有消息的日期和对话。空着不代表你没有该回或该做的事。"))
                            .padding(.vertical, 48)
                    } else {
                    InsightRadarSection(
                        chatInsights: insightCoordinator.chatInsights,
                        chatNames: insightChatNameMap(),
                        overview: overview,
                        briefing: insightCoordinator.globalBriefing,
                        expandedFindingID: $expandedRadarFindingID,
                        onOpenChat: onSelectChat,
                        onExpandModule: onExpandModule
                    )
                    InsightAttentionBar(
                        overview: overview,
                        briefing: insightCoordinator.globalBriefing,
                        onJumpToChat: onSelectChat
                    )
                    InsightHeroSection(
                        overview: overview,
                        briefing: insightCoordinator.globalBriefing,
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

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("今天聊了什么")
                    .font(.system(size: 20, weight: .bold))
                Text("\(insightStore.selectedScope.rawValue) · \(insightStore.selectedWindow.rawValue) · \(insightStore.overview?.activeChats ?? 0) 个活跃对话 · \(insightStore.overview?.totalMessages ?? 0) 条消息")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
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
                    }
                    .disabled(insightCoordinator.insightLoading || (insightStore.overview?.totalMessages ?? 0) == 0)
                    .help("重新生成今日 AI 态势")
                    Button(action: onCopyReport) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .disabled((insightStore.overview?.totalMessages ?? 0) == 0)
                    .help("复制为 Markdown 总结")
                }
                Picker("", selection: $insightStore.selectedWindow) {
                    ForEach(InsightTimeWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
        }
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
                    decisionCard(title: item.source, subtitle: item.what, meta: item.waitingHours > 0 ? "等待 \(formatHoursShort(item.waitingHours)) · \(item.urgency)" : item.urgency, color: item.urgency == "高" ? .red : item.urgency == "中" ? .orange : .blue, icon: "arrowshape.turn.up.right.fill", action: { onSelectChat(item.source) })
                }
            }

            if !overview.neglectedHighValue.isEmpty {
                ForEach(Array(overview.neglectedHighValue.prefix(aiItems.isEmpty ? 3 : 2).enumerated()), id: \.offset) { _, item in
                    decisionCard(title: item.name, subtitle: "重要联系人近期互动偏少", meta: item.role, color: .orange, icon: "person.crop.circle.badge.exclamationmark", action: { onSelectChat(item.name) })
                }
            }

            if aiItems.isEmpty && overview.neglectedHighValue.isEmpty {
                ForEach(Array(overview.topTimeBlackHoles.prefix(3).enumerated()), id: \.offset) { _, item in
                    decisionCard(title: item.name, subtitle: "今天占用注意力较多，适合快速确认是否需要跟进", meta: "\(item.count) 条消息", color: .blue, icon: "bubble.left.and.text.bubble.right", action: { onSelectChat(item.name) })
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
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
                    HStack(spacing: 8) {
                        Image(systemName: stats.isGroup ? "person.3" : "person")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stats.chatName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("\(stats.messageCount) 条消息 · 暂无强行动信号")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("查看") { onSelectChat(stats.chatUsername) }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func collapsibleMetrics(_ overview: ChatInsightEngine.GlobalOverview) -> some View {
        collapsibleSection(id: "metrics", title: "趋势指标", icon: "chart.bar.xaxis", summary: "消息 \(overview.totalMessages) · 回复率 \(Int(overview.responseRate * 100))% · 边界分 \(overview.boundaryScore)") {
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
        let topTier = o.tierDistribution.first?.tier ?? "—"
        let topRole = o.roleDistribution.first?.role ?? "—"
        return collapsibleSection(id: "relationships", title: "关系分布", icon: "person.3", summary: "主要对象 \(topTier) · 最多 \(topRole)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("层级").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        ForEach(o.tierDistribution, id: \.tier) { row in
                            tinyRow(label: row.tier, count: row.count)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("角色").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        ForEach(o.roleDistribution.prefix(6), id: \.role) { row in
                            tinyRow(label: row.role, count: row.count)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let sym = o.mostSymmetric, let asym = o.leastSymmetric {
                    Divider()
                    HStack(spacing: 10) {
                        relRow(label: "最均衡", name: sym.name, ratio: sym.ratio, good: true)
                        relRow(label: "最失衡", name: asym.name, ratio: asym.ratio, good: false)
                    }
                }
                if !o.oneWayChats.isEmpty {
                    Divider()
                    Text("单向沟通 (对方远多于你)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(o.oneWayChats.prefix(3), id: \.name) { c in
                        HStack {
                            Button(action: { onSelectChat(c.name) }) {
                                Text(c.name).font(.system(size: 12)).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text("对方 \(c.theirCount) / 你 \(c.myCount)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func collapsibleWorkLife(_ o: ChatInsightEngine.GlobalOverview) -> some View {
        let workPct = o.totalMessages > 0 ? Int(Double(o.workMessages) / Double(o.totalMessages) * 100) : 0
        let lifePct = o.totalMessages > 0 ? Int(Double(o.lifeMessages) / Double(o.totalMessages) * 100) : 0
        return collapsibleSection(id: "work-life", title: "工作 / 生活", icon: "briefcase", summary: "工作 \(workPct)% · 生活 \(lifePct)% · 边界分 \(o.boundaryScore)") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    categoryBar("工作", count: o.workMessages, total: o.totalMessages, color: .blue)
                    categoryBar("生活", count: o.lifeMessages, total: o.totalMessages, color: .green)
                    categoryBar("其他", count: o.otherMessages, total: o.totalMessages, color: .orange)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.gray.opacity(0.15), lineWidth: 7)
                        Circle().trim(from: 0, to: Double(o.boundaryScore) / 100)
                            .stroke(
                                o.boundaryScore >= 70 ? Color.green : o.boundaryScore >= 40 ? Color.orange : Color.red,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text("\(o.boundaryScore)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .frame(width: 56, height: 56)
                    Text("非工时工作 \(o.workAfterHoursCount)")
                        .font(.system(size: 9))
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
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func collapsiblePressure(_ o: ChatInsightEngine.GlobalOverview) -> some View {
        collapsibleSection(id: "pressure", title: "压力信号", icon: "waveform.path.ecg", summary: "待办 \(o.pendingAsks) · 紧急 \(o.urgentAsks) · 撤回 \(o.recalledMessages)") {
            HStack(spacing: 16) {
                pressurePill("待处理请求", count: o.pendingAsks, threshold: 5)
                pressurePill("紧急请求", count: o.urgentAsks, threshold: 1)
                pressurePill("撤回消息", count: o.recalledMessages, threshold: 3)
                Spacer()
            }
        }
    }

    private func collapsibleSection<Content: View>(id: String, title: String, icon: String, summary: String, @ViewBuilder content: () -> Content) -> some View {
        let expanded = expandedModules.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withMotion(CompanionMotion.ease(0.18)) {
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
            .buttonStyle(.plain)
            if expanded {
                Divider().background(Color.primary.opacity(0.05))
                content()
                    .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
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
        .buttonStyle(.plain)
    }

    private func tinyRow(label: String, count: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    private func relRow(label: String, name: String, ratio: Double, good: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text("对等度 \(Int(ratio * 100))%")
                .font(.system(size: 10))
                .foregroundColor(good ? .green : .orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weekdayBars(_ messagesByWeekday: [Int]) -> some View {
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
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

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

    private func pressurePill(_ label: String, count: Int, threshold: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(count >= threshold ? .red : .secondary)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    private func insightChatNameMap() -> [String: String] {
        var names = Dictionary(uniqueKeysWithValues: insightStore.allStats.map { ($0.key, $0.value.chatName) })
        for entry in store.getWhitelist() {
            names[entry.id] = entry.displayName
        }
        for session in insightStore.otherActiveSessions {
            names[session.id] = session.displayName
        }
        return names
    }

    /// Bounded before the `Int(_:)` conversions — `hours` is the model's
    /// `waiting_hours`, and `Int(1e30)` traps rather than returning garbage.
    private func formatHoursShort(_ rawHours: Double) -> String {
        let hours = SafeNumber.clamped(rawHours, to: 0...8_760)
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

    private func categoryColor(_ cat: WhitelistCategory) -> Color {
        switch cat {
        case .work: return .blue
        case .life: return .green
        case .other: return .orange
        }
    }

    private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
}
