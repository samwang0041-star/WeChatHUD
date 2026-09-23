import SwiftUI

/// Compact teaser used on the insight overview. The dedicated pane is
/// `RelationshipRadarView` — keep this free of EnvironmentObject so a
/// parent can pass snapshots without a ChatMonitor.
struct RelationshipRadarCard: View {
    let snapshots: [RelationshipRadarSnapshot]
    var displayName: (String) -> String = { $0 }

    var body: some View {
        let ranked = RelationshipRadarService.ranked(snapshots)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("关系雷达", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Text("跨天趋势")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if ranked.isEmpty {
                Text("分析至少两天后，这里会出现态度和沉默变化。单天分析不会填态度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ranked.prefix(6), id: \.chatUsername) { snap in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(RelationshipRadarView.trendColor(snap))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(snap.chatUsername))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(RelationshipRadarService.trendLabel(snap.relationshipTrend)
                                 + " · "
                                 + RelationshipRadarService.attitudeLabel(snap.attitudeTrend)
                                 + RelationshipRadarView.silenceSuffix(snap))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("关系雷达")
    }
}

/// Dedicated 关系雷达 workspace: cross-day attitude, tone, silence, and
/// relationship trend. Independent of single-day ChatInsightResult — this
/// page never asks the model for attitudes / tone_changes / mood_shift.
struct RelationshipRadarView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    @State private var loaded: [RelationshipRadarSnapshot] = []
    @State private var selectedUsername: String?
    @State private var filter: RadarFilter = .all
    @State private var refreshing = false
    @State private var refreshError: String?

    private enum RadarFilter: String, CaseIterable {
        case all = "全部"
        case cooling = "转淡"
        case silence = "沉默"
        case warming = "回暖"
    }

    var body: some View {
        workspaceBody
            .task { reload() }
            .onChange(of: monitor.stats.lastSyncAt) { _, _ in reload() }
    }

    private var visibleSnapshots: [RelationshipRadarSnapshot] {
        let ranked = RelationshipRadarService.ranked(loaded)
        switch filter {
        case .all: return ranked
        case .cooling:
            return ranked.filter {
                $0.relationshipTrend == RelationshipRadarKind.trendDeteriorating
                    || $0.attitudeTrend == RelationshipRadarKind.attitudeCooling
            }
        case .silence:
            return ranked.filter { $0.silenceDays >= 7 }
        case .warming:
            return ranked.filter {
                $0.relationshipTrend == RelationshipRadarKind.trendImproving
                    || $0.attitudeTrend == RelationshipRadarKind.attitudeWarming
            }
        }
    }

    private var selected: RelationshipRadarSnapshot? {
        let rows = visibleSnapshots
        if let selectedUsername, let match = rows.first(where: { $0.chatUsername == selectedUsername }) {
            return match
        }
        return rows.first
    }

    // MARK: - Workspace pane

    private var workspaceBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if let refreshError {
                Label(refreshError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.companionStatusReveal)
                    .accessibilityLabel(refreshError)
            }
            Divider().background(Color.secondary.opacity(0.2))
            if loaded.isEmpty {
                emptyState
            } else if visibleSnapshots.isEmpty {
                filterEmptyState
            } else {
                HSplitView {
                    snapshotList
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    snapshotDetail
                        .frame(minWidth: 320)
                }
            }
        }
        .workspaceGround()
        .companionAnimation(CompanionMotion.ease(), value: refreshError)
        .accessibilityIdentifier("workspace.relationshipRadar.pane")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(RadarFilter.allCases, id: \.self) { value in
                CompanionFilterPill(title: value.rawValue, selected: filter == value, tint: SettingsView.Tab.relationshipRadar.accentColor) {
                    filter = value
                    if selectedUsername == nil || !visibleSnapshots.contains(where: { $0.chatUsername == selectedUsername }) {
                        selectedUsername = visibleSnapshots.first?.chatUsername
                    }
                }
            }
            Spacer()
            Text("本机计算 · 不自动发消息")
                .companionFont(size: 11)
                .foregroundStyle(.secondary)
            Button {
                Task { await refreshNow() }
            } label: {
                if refreshing {
                    Label("正在刷新…", systemImage: "arrow.clockwise")
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(refreshing)
            .help(refreshing ? "正在刷新关系雷达" : "")
            .accessibilityLabel(refreshing ? "正在刷新关系雷达" : "刷新关系雷达")
            .accessibilityHint(refreshing ? "正在刷新关系雷达" : "")
        }
        .padding(.vertical, 12)
    }

    private var snapshotList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visibleSnapshots, id: \.chatUsername) { snap in
                    Button {
                        selectedUsername = snap.chatUsername
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Self.trendColor(snap))
                                .frame(width: 9, height: 9)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName(snap))
                                    .companionFont(size: 13, weight: .semibold)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(listSubtitle(snap))
                                    .companionFont(size: 11)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedUsername == snap.chatUsername
                                      ? CompanionPalette.sidebarSelectedFill
                                      : Color.clear)
                        )
                    }
                    .buttonStyle(CompanionRowPressStyle())
                    .accessibilityLabel(displayName(snap))
                    .accessibilityValue(listSubtitle(snap))
                }
            }
            .padding(12)
        }
        .background(CompanionPalette.mist.opacity(0.4))
    }

    @ViewBuilder
    private var snapshotDetail: some View {
        if let snap = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName(snap))
                            .workspaceTitle()
                        Text(snap.summary)
                            .companionFont(size: 14)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        metricCard(
                            title: "关系",
                            value: RelationshipRadarService.trendLabel(snap.relationshipTrend),
                            detail: "\(snap.windowDays) 天窗口"
                        )
                        metricCard(
                            title: "态度",
                            value: RelationshipRadarService.attitudeLabel(snap.attitudeTrend),
                            detail: snap.moodShift ?? "语气未转向"
                        )
                        metricCard(
                            title: "沉默",
                            value: snap.silenceDays == 0 ? "今天还有往来" : "\(snap.silenceDays) 天",
                            detail: "相对最近一条可分析事实"
                        )
                        metricCard(
                            title: "语气变化",
                            value: "\(snap.toneChanges.count) 次",
                            detail: snap.toneChanges.last.map { "\($0.from) → \($0.to)" } ?? "没有转向"
                        )
                    }

                    if !snap.darkSignals.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("需要留意")
                                .companionFont(size: 13, weight: .semibold)
                            ForEach(snap.darkSignals, id: \.self) { signal in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.orange)
                                    Text(signal)
                                        .companionFont(size: 13)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !snap.toneChanges.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("语气轨迹")
                                .companionFont(size: 13, weight: .semibold)
                            ForEach(Array(snap.toneChanges.enumerated()), id: \.offset) { _, change in
                                Text("\(change.aroundDay)  \(change.from) → \(change.to)")
                                    .companionFont(size: 12, design: .monospaced)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text("单天分析仍然没有态度、语气变化或心情转向。这里只根据已经存下的跨天事实计算，证据以哈希保存。")
                        .companionFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .accessibilityIdentifier("workspace.relationshipRadar.detail")
        } else {
            ContentUnavailableView(
                "选一个对话",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("看跨天态度、沉默和关系趋势。")
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
            "还没有跨天关系信号",
            systemImage: "point.3.connected.trianglepath.dotted",
            // The toolbar on this very page already says 本机计算 · 不自动发消息;
            // repeating the reassurance in the empty state spends the one line
            // that could tell the user what to do next.
            //
            // Broken by hand into two lines: `ContentUnavailableView` gives its
            // description a narrow column, so the prose wrapped to three with
            // 「态度。」 stranded alone under two full lines.
            description: Text("先在「聊天回顾」里分析两天以上\n单天分析不会填态度")
        )
            Button("打开聊天回顾") {
                panelState.pendingSettingsTab = SettingsView.Tab.insight.rawValue
            }
            .buttonStyle(CompanionPressStyle())
            .foregroundStyle(CompanionPalette.jadeInk)
            .accessibilityLabel("打开聊天回顾，分析两天以上才会出现态度")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterEmptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "这个筛选下没有对话",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("「\(filter.rawValue)」目前没有匹配的跨天信号。")
            )
            Button("看全部") {
                withMotion(CompanionMotion.pageChange()) { filter = .all }
            }
            .buttonStyle(CompanionPressStyle())
            .foregroundStyle(CompanionPalette.jadeInk)
            .accessibilityLabel("看全部关系信号")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .companionFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .companionFont(size: 16, weight: .semibold)
            Text(detail)
                .companionFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reload() {
        loaded = store.loadAllRelationshipRadarSnapshots(limit: 200)
        if selectedUsername == nil {
            selectedUsername = visibleSnapshots.first?.chatUsername
        }
    }

    private func refreshNow() async {
        refreshing = true
        defer { refreshing = false }
        let storeRef = store
        let succeeded = await ChatMonitor.runOffMain {
            do {
                _ = try RelationshipRadarService.refreshAll(store: storeRef, force: true)
                return true
            } catch {
                return false
            }
        }
        refreshError = succeeded ? nil : "刷新没有完成，现在还是上次的关系信号。请再试一次。"
        reload()
    }

    private func displayName(_ snap: RelationshipRadarSnapshot) -> String {
        RelationshipRadarService.displayName(for: snap.chatUsername, store: store)
    }

    private func listSubtitle(_ snap: RelationshipRadarSnapshot) -> String {
        RelationshipRadarService.trendLabel(snap.relationshipTrend)
            + " · "
            + RelationshipRadarService.attitudeLabel(snap.attitudeTrend)
            + silenceSuffix(snap)
    }

    static func silenceSuffix(_ snap: RelationshipRadarSnapshot) -> String {
            snap.silenceDays >= 3 ? " · 沉默 \(snap.silenceDays) 天" : ""
    }

    private func silenceSuffix(_ snap: RelationshipRadarSnapshot) -> String {
        Self.silenceSuffix(snap)
    }

    static func trendColor(_ snap: RelationshipRadarSnapshot) -> Color {
        switch RelationshipRadarService.attentionRank(snap) {
        case 0: return .orange
        case 1: return .yellow
        case 3: return CompanionPalette.jadeInk
        default: return .secondary.opacity(0.5)
        }
    }
}
