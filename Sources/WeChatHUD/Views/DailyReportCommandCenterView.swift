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
    @State private var commandStates: [DailyReportCommandState] = []
    @State private var loadedDateKey: String?
    @State private var copyFeedback: CopyFeedback = .idle
    @State private var copyGeneration = UUID()
    @State private var commandError: String?

    init(isWorkspace: Bool = true) {
        self.isWorkspace = isWorkspace
    }

    private enum CopyFeedback: Equatable {
        case idle, copied, failed
    }

    /// Leading/trailing inset for this page's own blocks.
    ///
    /// The workspace page already supplies the standard page inset, so in
    /// workspace mode these must be zero or the report's cards would sit 12–14
    /// points inside every other page's content edge. The compact (in-island)
    /// rendering keeps the original numbers.
    private var cardInset: CGFloat { isWorkspace ? 0 : 12 }
    private var headerInset: CGFloat { isWorkspace ? 0 : 14 }

    /// Daily-report actions cache the name they were generated with, so a
    /// rename or a newly recovered group name has to be resolved on display.
    ///
    /// A resolution that comes back as the very identifier it was asked about
    /// is not a name. Preferring it hid "林晓 · 产品同事" behind
    /// "preview-colleague" on rows that already carried the right name.
    private func resolvedChatName(_ stored: String, username: String?) -> String {
        guard let username, !username.isEmpty else { return stored }
        let resolved = monitor.displayName(for: username)
        guard !resolved.isEmpty, resolved != username,
              !ContactIdentityIndex.isUninformativeChatName(resolved)
        else { return stored }
        return resolved
    }

    var body: some View {
        return VStack(alignment: .leading, spacing: 0) {
            if let commandError {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(commandError)
                        .companionFont(size: isWorkspace ? 13 : 11)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("知道了") { self.commandError = nil }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                }
                .padding(.horizontal, cardInset)
                .padding(.vertical, 8)
                .transition(.companionStatusReveal)
            }
            if let report = monitor.dailyReport {
                let key = report.date.dailyReportDateKey
                if loadedDateKey != key {
                    Color.clear.frame(height: 1)
                } else {
                    let vm = DailyReportPresentationPolicy.buildViewModel(
                        from: report,
                        commandStates: commandStates,
                        insights: monitor.dailyReportActionInsights,
                        sourceVerified: monitor.stats.lastSyncAt != nil
                    )
                    if vm.isSourceUnavailable {
                        sourceUnavailableView
                    } else {
                        content(vm: vm, report: report)
                    }
                }
            } else if monitor.dailyReportIsLoading {
                loadingView
            } else if let error = monitor.dailyReportError {
                emptyStateWithRetry("小结没写出来：\(error)")
                    .transition(.companionStatusReveal)
           } else {
                emptyStateWithRetry(todayEmptyCopy)
           }
        }
        .foregroundStyle(.primary)
        .companionAnimation(CompanionMotion.ease(), value: commandError)
        .background(isWorkspace ? WorkspacePage.ground : Color(nsColor: .windowBackgroundColor))
        .companionAnimation(CompanionMotion.ease(), value: monitor.dailyReportError)
        .onAppear { reloadCommandStates() }
        .onChange(of: monitor.dailyReport?.date) { _, _ in reloadCommandStates() }
        .onChange(of: monitor.dailyReportGeneratedAt) { _, _ in reloadCommandStates() }
    }

    private func reloadCommandStates() {
        guard let report = monitor.dailyReport else {
            commandStates = []
            loadedDateKey = nil
            return
        }
        let key = report.date.dailyReportDateKey
        commandStates = monitor.store.loadDailyReportCommandStates(dateKey: key)
        loadedDateKey = key
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
                // The bucket is critical *and* high urgency, so a header that
                // says 紧急 contradicts the 高 chip on the rows under it.
                sectionHeader(icon: "exclamationmark.circle.fill", tint: .red, text: "优先处理", count: vm.urgentActions.count)
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
                    .companionFont(size: isWorkspace ? 13 : 10, weight: .semibold)
                    .foregroundColor(.secondary)
                Text("当日记录")
                    .companionFont(size: isWorkspace ? 15 : 11, weight: .semibold)
                    .foregroundColor(.primary)
                Text(date.formatted(.dateTime.year().month().day()))
                    .companionFont(size: isWorkspace ? 14 : 10)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text("回顾这一天记录的消息与承诺。处理当前事项请回到今天。")
                .companionFont(size: isWorkspace ? 13 : 10)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, headerInset)
        .padding(.vertical, 12)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(.circular)
            Text("正在生成日报…")
                .companionFont(size: isWorkspace ? 14 : 11)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var sourceUnavailableView: some View {
        let isHistorical = monitor.dailyReport.map { !Calendar.current.isDateInToday($0.date) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Label(isHistorical ? "没有这一天的可用记录" : "今日来源未验证", systemImage: "exclamationmark.triangle")
                .companionFont(size: 12, weight: .semibold)
                .foregroundColor(.orange)
            Text(isHistorical
                 ? "没有找到这一天可用于整理的消息或事项。可以查看其他日期，或在连接微信后重新整理。"
                 : "还没有成功读到今天的微信，当前没有足够来源，不能判断有没有待处理事项。")
                .companionFont(size: isWorkspace ? 14 : 11)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !isHistorical {
                Text("请先连上微信并完成一次读取，再刷新日报。")
                    .companionFont(size: isWorkspace ? 14 : 11)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
               Button(action: {
                   guard !monitor.dailyReportIsLoading else { return }
                   Task { await monitor.loadDailyReport(force: true) }
               }) {
                    Text(monitor.dailyReportIsLoading ? "正在生成…" : "重新生成")
                        .companionFont(size: 11, weight: .medium)
                        .foregroundColor(.accentColor)
              }
              .buttonStyle(CompanionPressStyle())
                .disabled(monitor.dailyReportIsLoading)
                .help(monitor.dailyReportIsLoading ? "正在整理今日小结" : "")
                .accessibilityHint(monitor.dailyReportIsLoading ? "正在整理今日小结" : "")
                .accessibilityLabel(monitor.dailyReportIsLoading ? "正在生成日报" : "重新生成日报")
               if !isHistorical {
                    Button("检查连接") {
                        panelState.pendingSettingsTab = "system"
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .accessibilityLabel("检查微信连接")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, headerInset)
       .padding(.vertical, 18)
   }

    private var todayEmptyCopy: String {
        if monitor.stats.lastSyncAt == nil { return "还没有今日小结。连上微信后再整理。" }
        if !monitor.store.hasWhitelistEntries() { return "还没有今日小结。先选要关注的对话。" }
        return "还没有今日小结。点重新生成即可整理。"
    }

   private func emptyStateWithRetry(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .companionFont(size: 11)
                .foregroundColor(Color.primary.opacity(0.4))
            Button(action: {
                guard !monitor.dailyReportIsLoading else { return }
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .companionFont(size: 10, weight: .semibold)
                    Text(monitor.dailyReportIsLoading ? "正在生成…" : "重新生成")
                        .companionFont(size: 11, weight: .medium)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(CompanionPressStyle())
            .disabled(monitor.dailyReportIsLoading)
            .help(monitor.dailyReportIsLoading ? "正在整理今日小结" : "")
            .accessibilityHint(monitor.dailyReportIsLoading ? "正在整理今日小结" : "")
            .accessibilityLabel(monitor.dailyReportIsLoading ? "正在生成日报" : "重新生成日报")
            if monitor.stats.lastSyncAt == nil {
                Button("检查连接") { panelState.pendingSettingsTab = "system" }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                   .accessibilityLabel("检查微信连接后再生成日报")
           }
            else if !monitor.store.hasWhitelistEntries() {
                Button("关注谁") { panelState.pendingSettingsTab = "contacts" }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .accessibilityLabel("去选要关注的对话后再生成日报")
            }
       }
       .frame(maxWidth: .infinity)
        .padding(.horizontal, headerInset)
        .padding(.vertical, 14)
    }

    private func progressCard(_ progress: DailyReportProgressMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "target")
                    .companionFont(size: 11, weight: .semibold)
                    .foregroundColor(.green.opacity(0.85))
                Text(monitor.dailyReport?.status == .aiEnhanced ? "AI 小结" : "今日进度")
                    .companionFont(size: isWorkspace ? 15 : 11, weight: .semibold)
                    .foregroundColor(.primary)
                Spacer()
                Text("截至刚才")
                    .companionFont(size: isWorkspace ? 12 : 10)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                statLabel("今日处理", value: progress.completedCount, color: CompanionPalette.jadeInk)
                statLabel("待跟进", value: progress.activeCount, color: .primary)
                if progress.overdueCount > 0 {
                    statLabel("已到期", value: progress.overdueCount, color: .red)
                }
            }
            Text(DailyReportPresentationPolicy.followUpCaption)
                .companionFont(size: isWorkspace ? 12 : 10)
                .foregroundStyle(.secondary)
        }
        .padding(isWorkspace ? 14 : 10)
        .companionPanelFace(radius: 6)
        .padding(.horizontal, cardInset)
        .padding(.vertical, 8)
    }

    private func statLabel(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .companionFont(size: 10, weight: .semibold)
                .foregroundColor(color)
                .monospacedDigit()
            Text(label)
                .companionFont(size: 10)
                .foregroundColor(.secondary)
        }
    }

    private func sectionHeader(icon: String? = nil, tint: Color = .secondary, text: String, count: Int) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundColor(tint)
            }
            Text(text)
                .companionFont(size: isWorkspace ? 14 : 10, weight: .semibold)
                .foregroundColor(.secondary)
            Text("\(count)")
                .companionFont(size: isWorkspace ? 12 : 9)
                .foregroundColor(Color.primary.opacity(0.4))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, headerInset)
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
                Text(action.content)
                    .companionFont(size: isWorkspace ? 14 : 11, weight: isUrgent ? .semibold : .medium)
                    .foregroundColor(.primary)
                    .lineLimit(isWorkspace ? nil : 2)
                    .fixedSize(horizontal: false, vertical: isWorkspace)

                HStack(spacing: 6) {
                    urgencyChip(action.urgency)
                    Text(resolvedChatName(action.sourceChatName, username: action.sourceChatUsername))
                        .companionFont(size: isWorkspace ? 12 : 9)
                        .foregroundColor(.secondary)
                    if let deadline = action.deadline {
                        Text(Self.deadlineText(deadline))
                            .companionFont(size: 10)
                            .foregroundColor(deadlineColor(deadline))
                    }
                    Spacer()
                }

                if let insight {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "sparkles")
                                .companionFont(size: 10)
                                .foregroundColor(.cyan.opacity(0.85))
                            Text(insight.reason)
                                .companionFont(size: 11)
                                .italic()
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "arrow.right")
                                .companionFont(size: 10)
                                .foregroundColor(.orange.opacity(0.85))
                            Text(insight.nextStep)
                                .companionFont(size: 11)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            HStack(spacing: 4) {
                Button(action: {
                    if monitor.markDailyReportActionDone(action) {
                        commandError = nil
                    } else {
                        commandError = CompanionInteractionCopy.dailyReportCompleteFailed
                    }
                }) {
                    actionButtonLabel(
                        icon: "checkmark",
                        title: "标记完成",
                        tint: .green,
                        background: Color.green.opacity(0.12)
                    )
                }
                .buttonStyle(CompanionPressStyle())
                .help("标记完成")
                .accessibilityLabel("将日报事项标记为完成：\(action.content)")

                Button(action: {
                    panelState.pendingDiscussionChatUsername = action.sourceChatUsername
                    NotificationCenter.default.post(name: .hudSwitchTab, object: "tasks")
                }) {
                    // A quiet text link, not a second chip. Every row in this
                    // section carried two same-shaped chips, so the one action
                    // the row is for (完成) had no more weight than a jump.
                    HStack(spacing: 3) {
                        Image(systemName: "checklist")
                        Text("待办")
                    }
                    .companionFont(size: isWorkspace ? 11 : 9)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CompanionPressStyle())
                .help("到「待办」页看这个对话的事项")
                .accessibilityLabel("查看待办：\(action.content)")
            }
            .opacity(isHovered ? 1.0 : 0.85)
        }
        .padding(.horizontal, cardInset)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isActive in
            hoveredActionID = isActive ? action.id : nil
        }
    }

    private func highlightsSection(_ highlights: [DailyReportHighlight], expandedByDefault: Bool = false) -> some View {
        // Historical reports start expanded but stay collapsible — the
        // collapsed flag must gate `expandedByDefault`, not be ignored by it.
        let isExpanded = expandedByDefault ? !historicalHighlightsCollapsed : showHighlights
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withMotion(CompanionMotion.ease()) {
                    if expandedByDefault {
                        historicalHighlightsCollapsed.toggle()
                    } else {
                        showHighlights.toggle()
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .companionFont(size: 10)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .companionAnimation(CompanionMotion.ease(), value: isExpanded)
                    Image(systemName: "star.fill")
                        .companionFont(size: 10)
                        .foregroundColor(.yellow.opacity(0.85))
                    Text(expandedByDefault ? "当日高亮" : "今日高亮")
                        .companionFont(size: 10, weight: .semibold)
                        .foregroundColor(.secondary)
                    Text("\(highlights.count)")
                        .companionFont(size: 10)
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起今日高亮" : "展开今日高亮")
            .padding(.horizontal, headerInset)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if isExpanded {
                ForEach(highlights) { highlight in
                    highlightCard(highlight)
                }
                .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: isExpanded)
    }

    private func risksSection(_ risks: [DailyReportRisk]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withMotion(CompanionMotion.ease()) { showRisks.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .companionFont(size: 10)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showRisks ? 90 : 0))
                        .companionAnimation(CompanionMotion.ease(), value: showRisks)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .companionFont(size: 10)
                        .foregroundColor(.orange.opacity(0.85))
                    Text("风险与异常")
                        .companionFont(size: 10, weight: .semibold)
                        .foregroundColor(.secondary)
                    Text("\(risks.count)")
                        .companionFont(size: 10)
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showRisks ? "收起风险与异常" : "展开风险与异常")
            .padding(.horizontal, headerInset)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if showRisks {
                ForEach(risks) { risk in
                    riskCard(risk)
                }
                .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: showRisks)
    }

    private func completedSection(_ actions: [DailyReportAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withMotion(CompanionMotion.ease()) { showCompleted.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .companionFont(size: 10)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showCompleted ? 90 : 0))
                        .companionAnimation(CompanionMotion.ease(), value: showCompleted)
                    Image(systemName: "checkmark.circle.fill")
                        .companionFont(size: 10)
                        .foregroundColor(.green.opacity(0.8))
                    Text("已完成")
                        .companionFont(size: 10, weight: .semibold)
                        .foregroundColor(.secondary)
                    Text("\(actions.count)")
                        .companionFont(size: 10)
                        .foregroundColor(Color.primary.opacity(0.4))
                        .monospacedDigit()
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showCompleted ? "收起已完成事项" : "展开已完成事项")
            .padding(.horizontal, headerInset)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if showCompleted {
                ForEach(actions) { action in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .companionFont(size: 10)
                            .foregroundColor(.green.opacity(0.7))
                        Text(action.content)
                            .companionFont(size: isWorkspace ? 14 : 11)
                            .foregroundColor(.secondary)
                            .strikethrough()
                        Spacer()
                    }
                    .padding(.horizontal, cardInset)
                    .padding(.vertical, 3)
                }
                .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: showCompleted)
    }

    private func highlightCard(_ highlight: DailyReportHighlight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(highlight.category.label)
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundColor(categoryColor(highlight.category))
                Text(resolvedChatName(highlight.sourceChatName, username: highlight.sourceChatUsername))
                    .companionFont(size: 10)
                    .foregroundColor(.secondary)
                Spacer()
                if highlight.confidence < 0.8 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .companionFont(size: 10)
                        .foregroundColor(.orange.opacity(0.7))
                }
            }
            Text(highlight.summary)
                .companionFont(size: isWorkspace ? 14 : 11)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = highlight.quotedSnippet {
                Text("「\(snippet)」")
                    .companionFont(size: isWorkspace ? 13 : 10)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(8)
        .companionPanelFace(radius: 5)
        .padding(.horizontal, cardInset)
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
                    .companionFont(size: isWorkspace ? 14 : 11)
                    .foregroundColor(.primary)
                if let name = risk.sourceChatName {
                    Text(resolvedChatName(name, username: risk.sourceChatUsername))
                        .companionFont(size: isWorkspace ? 12 : 9)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 4)

            Button(action: {
                if monitor.dismissDailyReportRisk(risk) {
                    commandError = nil
                } else {
                    commandError = CompanionInteractionCopy.dailyReportDismissFailed
                }
            }) {
                Image(systemName: "xmark")
                    .companionFont(size: 10)
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(isHovered ? 0.08 : 0.04))
                    .cornerRadius(4)
            }
            .buttonStyle(CompanionPressStyle())
            .opacity(isHovered ? 1 : 0.55)
            .help("忽略此风险")
            .accessibilityLabel("忽略风险：\(risk.description)")
        }
        .padding(.horizontal, cardInset)
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
                    .companionFont(size: 10)
                    .foregroundColor(.cyan.opacity(0.8))
                Text(monitor.dailyReport?.status == .aiEnhanced ? "AI 小结" : "本地统计")
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundColor(.cyan.opacity(0.8))
                Spacer()
            }
            Text(narrative)
                .companionFont(size: isWorkspace ? 14 : 11)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            if let tomorrow = tomorrow, !tomorrow.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "alarm.fill")
                        .companionFont(size: 10)
                        .foregroundColor(.orange.opacity(0.85))
                        .padding(.top, 1)
                    Text(tomorrow)
                        .companionFont(size: isWorkspace ? 14 : 11)
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
        .padding(.horizontal, cardInset)
        .padding(.vertical, 4)
    }

    private func draftCard(draft: String) -> some View {
        DisclosureGroup(isExpanded: $showDraft) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft)
                    .companionFont(size: isWorkspace ? 14 : 10)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(8)
                    .companionPanelFace(radius: 5)
                Button(action: { copyDraft(draft) }) {
                    HStack(spacing: 3) {
                        Image(systemName: copyDraftIcon)
                            .companionFont(size: isWorkspace ? 12 : 9)
                        Text(copyDraftTitle)
                            .companionFont(size: isWorkspace ? 13 : 10, weight: .medium)
                    }
                    .foregroundColor(copyDraftTint)
                }
                .buttonStyle(CompanionPressStyle())
                .accessibilityLabel("复制微信日报草稿")
                .accessibilityValue(copyDraftValue)
                .companionAnimation(CompanionMotion.ease(), value: copyFeedback)
            }
            .padding(.top, 6)
        } label: {
            Label("查看可复制的小结", systemImage: "doc.on.doc")
                .companionFont(size: isWorkspace ? 14 : 10, weight: .semibold)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, cardInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var copyDraftIcon: String {
        switch copyFeedback {
        case .copied: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "doc.on.doc"
        }
    }

    private var copyDraftTitle: String {
        switch copyFeedback {
        case .copied: return CompanionInteractionCopy.copied
        case .failed: return CompanionInteractionCopy.copyFailed
        case .idle: return "复制小结"
        }
    }

    private var copyDraftTint: Color {
        switch copyFeedback {
        case .copied: return CompanionPalette.jadeInk
        case .failed: return .orange
        case .idle: return .secondary
        }
    }

    private var copyDraftValue: String {
        switch copyFeedback {
        case .copied: return CompanionInteractionCopy.copied
        case .failed: return CompanionInteractionCopy.copyFailed
        case .idle: return ""
        }
    }

    private func copyDraft(_ draft: String) {
        let token = UUID()
        copyGeneration = token
        if CompanionClipboard.write(draft) {
            copyFeedback = .copied
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copyGeneration == token { copyFeedback = .idle }
            }
        } else {
            copyFeedback = .failed
        }
    }

    @ViewBuilder
    private func actionButtonLabel(icon: String, title: String, tint: Color, background: Color) -> some View {
        HStack(spacing: isWorkspace ? 5 : 0) {
            Image(systemName: icon)
                .companionFont(size: isWorkspace ? 11 : 10, weight: .semibold)
            if isWorkspace {
                Text(title)
                    .companionFont(size: 13, weight: .medium)
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
            .companionFont(size: 10, weight: .semibold)
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

    /// Relative deadline, in the units the rest of the app uses.
    ///
    /// This page used to abbreviate on its own: 「6时前到期」. That is not just
    /// inconsistent with `ViewHelpers.formatRelative` ("3 小时前") — read as
    /// Chinese it parses as a clock time first (「6 时」= 6 o'clock, "before
    /// six"), so the row that meant "overdue by six hours" can be read as "due
    /// before 6:00". The compact column earns no space worth that ambiguity.
    nonisolated static func deadlineText(_ date: Date, now: Date = Date()) -> String {
        let diff = date.timeIntervalSince(now)
        if diff < 0 {
            let past = Int(-diff)
            // Under a minute reads as 「0 分钟前到期」 — a number that is not a
            // measurement, on the row whose whole job is to say how late it is.
            if past < 60    { return "刚到期" }
            if past < 3600  { return "\(past / 60) 分钟前到期" }
            if past < 86400 { return "\(past / 3600) 小时前到期" }
            return "\(past / 86400) 天前到期"
        }
        if diff < 60    { return "即将到期" }
        if diff < 3600  { return "\(Int(diff) / 60) 分钟后" }
        if diff < 86400 { return "\(Int(diff) / 3600) 小时后" }
        return "\(Int(diff) / 86400) 天后"
    }

    private func deadlineColor(_ date: Date) -> Color {
        let diff = date.timeIntervalSince(Date())
        if diff < 0       { return .red.opacity(0.85) }
        if diff < 3600    { return .orange.opacity(0.9) }
        return Color.primary.opacity(0.4)
    }
}
