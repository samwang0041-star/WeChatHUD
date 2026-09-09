import SwiftUI
import AppKit

struct DailyReportCommandCenterView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    private let isWorkspace: Bool
    @State private var showCompleted = false
    @State private var showHighlights = false
    @State private var historicalHighlightsCollapsed = false
    @State private var showRisks = false
    @State private var showDraft = false
    @State private var hoveredActionID: String?
    @State private var hoveredRiskID: String?

    init(isWorkspace: Bool = true) {
        self.isWorkspace = isWorkspace
    }

    /// Daily-report actions cache the name they were generated with, so a
    /// rename or a newly recovered group name has to be resolved on display.
    private func resolvedChatName(_ stored: String, username: String?) -> String {
        guard let username, !username.isEmpty else { return stored }
        let resolved = monitor.displayName(for: username)
        return resolved.isEmpty ? stored : resolved
    }

    var body: some View {
        return VStack(alignment: .leading, spacing: 0) {
            if let report = monitor.dailyReport {
                let states = monitor.store.loadDailyReportCommandStates(
                    dateKey: report.date.dailyReportDateKey
                )
                let vm = DailyReportPresentationPolicy.buildViewModel(
                    from: report,
                    commandStates: states,
                    insights: monitor.dailyReportActionInsights,
                    sourceVerified: monitor.stats.lastSyncAt != nil
                )
                if vm.isSourceUnavailable {
                    sourceUnavailableView
                } else {
                    content(vm: vm, report: report)
                }
            } else if monitor.dailyReportIsLoading {
                loadingView
            } else if let error = monitor.dailyReportError {
                emptyStateWithRetry("日报加载失败: \(error)")
            } else {
                emptyStateWithRetry("暂无日报数据")
            }
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func content(vm: DailyReportPresentationPolicy.CommandCenterViewModel, report: DailyReport) -> some View {
        let isHistorical = !Calendar.current.isDateInToday(report.date)
        return VStack(alignment: .leading, spacing: 0) {
            if isHistorical {
                historicalHeader(report.date)
            } else {
                progressCard(vm.progress)
            }
            divider

            if !vm.urgentActions.isEmpty {
                sectionHeader(icon: "exclamationmark.circle.fill", tint: .red, text: "紧急待处理", count: vm.urgentActions.count)
                ForEach(vm.urgentActions) { action in
                    actionCard(action, isUrgent: true, insight: vm.actionInsights[action.id])
                }
                divider
            }

            if !vm.activeToday.isEmpty {
                sectionHeader(icon: "list.bullet", text: "还需要跟进", count: vm.activeToday.count)
                ForEach(vm.activeToday) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }

            if !vm.activeThisWeek.isEmpty {
                sectionHeader(icon: "list.bullet", text: "待处理 · 本周到期", count: vm.activeThisWeek.count)
                ForEach(vm.activeThisWeek) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }

            if !vm.activeLater.isEmpty {
                sectionHeader(icon: "list.bullet", text: "待处理 · 之后 / 无期限", count: vm.activeLater.count)
                ForEach(vm.activeLater) { action in
                    actionCard(action, isUrgent: false)
                }
                divider
            }

            if !vm.completedActions.isEmpty {
                completedSection(vm.completedActions)
                divider
            }

            if !vm.highlights.isEmpty {
                highlightsSection(vm.highlights, expandedByDefault: isHistorical)
                divider
            }

            if !vm.activeRisks.isEmpty {
                risksSection(vm.activeRisks)
                divider
            }

            if let narrative = vm.narrative, !narrative.isEmpty {
                insightCard(narrative: narrative, tomorrow: vm.tomorrowFocus)
                divider
            }

            if let draft = vm.wechatDraft, !draft.isEmpty {
                draftCard(draft: draft)
            }
        }
        .padding(.bottom, 8)
        .onChange(of: report.date) { _, _ in
            historicalHighlightsCollapsed = false
            showHighlights = false
        }
    }

    private func historicalHeader(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: isWorkspace ? 13 : 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("当日记录")
                    .font(.system(size: isWorkspace ? 15 : 11, weight: .semibold))
                    .foregroundColor(.primary)
                Text(date.formatted(.dateTime.year().month().day()))
                    .font(.system(size: isWorkspace ? 14 : 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text("回顾这一天记录的消息与承诺。处理当前事项请回到今天。")
                .font(.system(size: isWorkspace ? 13 : 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(.circular)
            Text("正在生成日报…")
                .font(.system(size: isWorkspace ? 14 : 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var sourceUnavailableView: some View {
        let isHistorical = monitor.dailyReport.map { !Calendar.current.isDateInToday($0.date) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Label(isHistorical ? "这一天暂无可用记录" : "今日来源未验证", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
            Text(isHistorical
                 ? "没有找到这一天可用于整理的消息或事项。可以查看其他日期，或在连接微信后重新整理。"
                 : "尚无成功同步记录，当前没有足够的今日微信来源，暂不能判断是否有待处理事项。")
                .font(.system(size: isWorkspace ? 14 : 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !isHistorical {
                Text("请连接微信并完成一次成功同步后，再刷新日报。")
                    .font(.system(size: isWorkspace ? 14 : 11))
                    .foregroundColor(.secondary)
            }
            Button(action: {
                guard !monitor.dailyReportIsLoading else { return }
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                Text("重新生成")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color.primary.opacity(0.4))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }

    private func emptyStateWithRetry(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Color.primary.opacity(0.4))
            Button(action: {
                guard !monitor.dailyReportIsLoading else { return }
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("重新生成")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(monitor.dailyReportIsLoading)
            .accessibilityLabel("重新生成日报")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func progressCard(_ progress: DailyReportProgressMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green.opacity(0.85))
                Text("AI 小结")
                    .font(.system(size: isWorkspace ? 15 : 11, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("截至刚才")
                    .font(.system(size: isWorkspace ? 12 : 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                statLabel("今日处理", value: progress.completedCount, color: CompanionPalette.jade)
                statLabel("待跟进", value: progress.activeCount, color: .primary)
                if progress.overdueCount > 0 {
                    statLabel("超期", value: progress.overdueCount, color: .red)
                }
            }
        }
        .padding(isWorkspace ? 14 : 10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func progressColor(_ ratio: Double) -> Color {
        if ratio >= 1.0 { return .green }
        if ratio >= 0.6 { return .cyan }
        if ratio >= 0.3 { return .orange }
        return .red
    }

    private func statLabel(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func sectionHeader(icon: String? = nil, tint: Color = .secondary, text: String, count: Int) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint)
            }
            Text(text)
                .font(.system(size: isWorkspace ? 14 : 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.system(size: isWorkspace ? 12 : 9))
                .foregroundColor(Color.primary.opacity(0.4))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func actionCard(_ action: DailyReportAction, isUrgent: Bool, insight: DailyReportActionInsight? = nil) -> some View {
        let isHovered = hoveredActionID == action.id
        return HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(urgencyColor(action.urgency))
                .frame(width: 3)
                .cornerRadius(1.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.content)
                        .font(.system(size: isWorkspace ? 14 : 11, weight: isUrgent ? .semibold : .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }

                HStack(spacing: 6) {
                    urgencyChip(action.urgency)
                    Text(resolvedChatName(action.sourceChatName, username: action.sourceChatUsername))
                        .font(.system(size: isWorkspace ? 12 : 9))
                        .foregroundColor(.secondary)
                    if let deadline = action.deadline {
                        Text(deadlineText(deadline))
                            .font(.system(size: 9))
                            .foregroundColor(deadlineColor(deadline))
                    }
                    Spacer()
                }

                if let insight {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundColor(.cyan.opacity(0.85))
                            Text(insight.reason)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundColor(.orange.opacity(0.85))
                            Text(insight.nextStep)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            HStack(spacing: 4) {
                Button(action: { monitor.markDailyReportActionDone(action) }) {
                    actionButtonLabel(
                        icon: "checkmark",
                        title: "标记完成",
                        tint: .green,
                        background: Color.green.opacity(0.12)
                    )
                }
                .buttonStyle(.plain)
                .help("标记完成")
                .accessibilityLabel("将日报事项标记为完成：\(action.content)")

                Button(action: {
                    panelState.pendingDiscussionChatUsername = action.sourceChatUsername
                    NotificationCenter.default.post(name: .hudSwitchTab, object: "tasks")
                }) {
                    actionButtonLabel(
                        icon: "checklist",
                        title: "查看待办",
                        tint: CompanionPalette.jade,
                        background: CompanionPalette.selectedFill
                    )
                }
                .buttonStyle(.plain)
                .help("查看待办")
                .accessibilityLabel("查看待办：\(action.content)")
            }
            .opacity(isHovered ? 1.0 : 0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isActive in
            hoveredActionID = isActive ? action.id : nil
        }
    }

    private func highlightsSection(_ highlights: [DailyReportHighlight], expandedByDefault: Bool = false) -> some View {
        let isExpanded = expandedByDefault || showHighlights
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if expandedByDefault {
                    historicalHighlightsCollapsed.toggle()
                } else {
                    showHighlights.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .companionAnimation(CompanionMotion.ease(0.2), value: isExpanded)
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow.opacity(0.85))
                    Text("今日高亮")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(highlights.count)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起今日高亮" : "展开今日高亮")
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if isExpanded {
                ForEach(highlights) { highlight in
                    highlightCard(highlight)
                }
            }
        }
    }

    private func risksSection(_ risks: [DailyReportRisk]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { showRisks.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showRisks ? 90 : 0))
                        .companionAnimation(CompanionMotion.ease(0.2), value: showRisks)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.85))
                    Text("风险与异常")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(risks.count)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showRisks ? "收起风险与异常" : "展开风险与异常")
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if showRisks {
                ForEach(risks) { risk in
                    riskCard(risk)
                }
            }
        }
    }

    private func completedSection(_ actions: [DailyReportAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { showCompleted.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showCompleted ? 90 : 0))
                        .companionAnimation(CompanionMotion.ease(0.2), value: showCompleted)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green.opacity(0.8))
                    Text("已完成")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(actions.count)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showCompleted ? "收起已完成事项" : "展开已完成事项")
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if showCompleted {
                ForEach(actions) { action in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green.opacity(0.7))
                        Text(action.content)
                            .font(.system(size: isWorkspace ? 14 : 11))
                            .foregroundColor(.secondary)
                            .strikethrough()
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func highlightCard(_ highlight: DailyReportHighlight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(highlight.category.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(categoryColor(highlight.category))
                Text(highlight.sourceChatName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                if highlight.confidence < 0.8 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange.opacity(0.7))
                }
            }
            Text(highlight.summary)
                .font(.system(size: isWorkspace ? 14 : 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = highlight.quotedSnippet {
                Text("「\(snippet)」")
                    .font(.system(size: isWorkspace ? 13 : 10))
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(5)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func riskCard(_ risk: DailyReportRisk) -> some View {
        let isHovered = hoveredRiskID == risk.id
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(severityColor(risk.severity))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(risk.description)
                    .font(.system(size: isWorkspace ? 14 : 11))
                    .foregroundColor(.primary)
                if let name = risk.sourceChatName {
                    Text(name)
                        .font(.system(size: isWorkspace ? 12 : 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                Button(action: { monitor.dismissDailyReportRisk(risk) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 20)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("忽略此风险")
                .accessibilityLabel("忽略风险：\(risk.description)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isActive in
            hoveredRiskID = isActive ? risk.id : nil
        }
    }

    private func insightCard(narrative: String, tomorrow: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.cyan.opacity(0.8))
                Text(monitor.dailyReport?.status == .aiEnhanced ? "AI 小结" : "规则整理")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.cyan.opacity(0.8))
                Spacer()
            }
            Text(narrative)
                .font(.system(size: isWorkspace ? 14 : 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            if let tomorrow = tomorrow, !tomorrow.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.85))
                        .padding(.top, 1)
                    Text(tomorrow)
                        .font(.system(size: isWorkspace ? 14 : 11))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.06))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func draftCard(draft: String) -> some View {
        DisclosureGroup(isExpanded: $showDraft) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft)
                    .font(.system(size: isWorkspace ? 14 : 10))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(5)
                Button(action: { WeChatLauncher.copyText(draft) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: isWorkspace ? 12 : 9))
                        Text("复制小结")
                            .font(.system(size: isWorkspace ? 13 : 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制微信日报草稿")
            }
            .padding(.top, 6)
        } label: {
            Label("查看可复制的小结", systemImage: "doc.on.doc")
                .font(.system(size: isWorkspace ? 14 : 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func actionButtonLabel(icon: String, title: String, tint: Color, background: Color) -> some View {
        HStack(spacing: isWorkspace ? 5 : 0) {
            Image(systemName: icon)
                .font(.system(size: isWorkspace ? 11 : 10, weight: .semibold))
            if isWorkspace {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundColor(tint)
        .frame(minWidth: isWorkspace ? nil : 22, minHeight: 20)
        .padding(.horizontal, isWorkspace ? 8 : 0)
        .background(background)
        .cornerRadius(4)
    }

    private var divider: some View {
        Divider()
            .background(Color.primary.opacity(0.08))
            .padding(.horizontal, 10)
    }

    private func urgencyChip(_ urgency: ActionUrgency) -> some View {
        let (text, color) = urgencyStyle(urgency)
        return Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func urgencyStyle(_ urgency: ActionUrgency) -> (String, Color) {
        switch urgency {
        case .critical: return ("紧急", .red)
        case .high:     return ("高", .orange)
        case .medium:   return ("中", .yellow)
        case .low:      return ("低", .secondary)
        }
    }

    private func urgencyColor(_ urgency: ActionUrgency) -> Color {
        switch urgency {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .yellow
        case .low:      return Color.primary.opacity(0.4)
        }
    }

    private func severityColor(_ severity: RiskSeverity) -> Color {
        switch severity {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow.opacity(0.6)
        }
    }

    private func categoryColor(_ category: HighlightCategory) -> Color {
        switch category {
        case .decision:   return .cyan.opacity(0.85)
        case .progress:   return .green.opacity(0.8)
        case .discussion: return .secondary
        case .risk:       return .orange.opacity(0.85)
        }
    }

    private func deadlineText(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff < 0 {
            let past = Int(-diff)
            if past < 3600  { return "已超期 \(past / 60)分" }
            if past < 86400 { return "已超期 \(past / 3600)时" }
            return "已超期 \(past / 86400)天"
        }
        if diff < 3600  { return "\(Int(diff) / 60)分后" }
        if diff < 86400 { return "\(Int(diff) / 3600)时后" }
        return "\(Int(diff) / 86400)天后"
    }

    private func deadlineColor(_ date: Date) -> Color {
        let diff = date.timeIntervalSince(Date())
        if diff < 0       { return .red.opacity(0.85) }
        if diff < 3600    { return .orange.opacity(0.9) }
        return Color.primary.opacity(0.4)
    }
}
