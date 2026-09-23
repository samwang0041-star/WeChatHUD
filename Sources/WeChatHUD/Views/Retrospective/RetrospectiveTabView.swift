import SwiftUI

/// Standalone retrospective surface. It always renders a visible state:
/// empty, running, failed, or the latest completed/partial run.
struct RetrospectiveTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var latestRun: ReviewRun?
    /// The newest `failed` row, if one is newer than any successful run. Only
    /// the live job carried failure info, so after a relaunch a dead run left
    /// the page showing an older period under 「已完成」.
    @State private var abandonedRun: ReviewRun?
    @State private var highlights: [ReviewHighlight] = []
    @State private var todos: [ReviewTodo] = []
    @State private var currentState: RetrospectiveJob.State = .idle
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var commandError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isRunning {
                runningPanel
            }

           if let errorText {
                messagePanel(
                    icon: "exclamationmark.triangle.fill",
                    title: "回顾没有完成",
                    detail: errorText,
                    tint: .orange,
                    actionTitle: isRunning ? "正在生成…" : (latestRun == nil ? "生成本次回顾" : "重新生成"),
                    actionEnabled: !isRunning,
                    action: { runJob() }
                )
                .transition(.companionStatusReveal)
           }

           if let run = latestRun {
               resultView(run: run)
            } else if !isRunning, errorText == nil {
               emptyState
           }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.94))
        .companionAnimation(CompanionMotion.ease(), value: errorText)
        .companionAnimation(CompanionMotion.ease(), value: commandError)
        .onAppear {
            currentState = monitor.retrospectiveJob.state
            apply(state: currentState)
            refreshLatestRun()
        }
        .onReceive(monitor.retrospectiveJob.$state) { apply(state: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .retrospectiveLiveUpdate)) { _ in
            refreshLatestRun()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("回顾结果")
                    .workspaceTitle()
                    .companionDimmedForeground(0.94)
                Text(statusLine)
                    .companionFont(size: 12)
                    .companionDimmedForeground(0.52)
            }

            Spacer()

           // Only once a run exists. Before that the empty-state card owns the
           // single "generate" action, and a second prominent button in the
           // header was both a duplicate control and a false label — there is
           // nothing to re-generate.
            if latestRun != nil, errorText == nil {
                Button {
                    runJob()
                } label: {
                    Label(isRunning ? "正在生成…" : "重新生成", systemImage: isRunning ? "hourglass" : "arrow.clockwise")
               }
               .tint(.cyan)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRunning)
                .help(isRunning ? "正在生成回顾" : "")
                .accessibilityHint(isRunning ? "正在生成回顾" : "")
            }
        }
    }

    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(runningText)
                    .companionFont(size: 13, weight: .medium)
                    .companionDimmedForeground(0.82)
            }

            if case .analyzingChats(let progress, let total) = currentState {
                ProgressView(value: Double(progress), total: Double(max(total, 1)))
                    .tint(.cyan)
                Text("\(progress) / \(total) 个对话")
                    .companionFont(size: 11)
                    .companionDimmedForeground(0.5)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(stroke: .cyan.opacity(0.22)))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A rising trend line promised analytics that don't exist yet; this
            // state is about looking back, not about a chart.
            Image(systemName: "clock.arrow.circlepath")
                .companionFont(size: WorkspaceType.display, weight: .medium)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.cyan.opacity(0.9))

            VStack(alignment: .leading, spacing: 6) {
                Text("还没有回顾结果")
                    .workspaceTitle()
                    .companionDimmedForeground(0.9)
                Text("从上次回顾到现在、你关注的对话里，提取重点、待办和风险。第一次使用默认回顾本周。")
                    .companionFont(size: 12)
                    .companionDimmedForeground(0.56)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                runJob()
            } label: {
                Label("生成本次回顾", systemImage: "sparkles")
            }
            .tint(.cyan)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(18)
        // Sizes to its content: with `maxHeight: .infinity` the card filled the
        // whole window, so ~150pt of copy sat in the top of a 900pt panel and
        // the rest was an empty bordered box.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(panelBackground(stroke: .white.opacity(0.12)))
    }

    private func resultView(run: ReviewRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                metricsRow(run: run)
                summarySection(run: run)
                todosSection
                highlightsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
    }

    private func metricsRow(run: ReviewRun) -> some View {
        HStack(spacing: 10) {
            metric("对话", "\(run.progressChatCount)/\(run.chatCount)", "bubble.left.and.bubble.right.fill")
            metric("条目", "\(run.msgCount)", "list.bullet.rectangle.fill")
            metric("待办", "\(todos.filter { $0.status == .pending }.count)", "checklist")
            metric("生成", run.generatedAt.formatted(date: .abbreviated, time: .shortened), "clock.fill")
        }
    }

    private func metric(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .companionFont(size: 10, weight: .medium)
                Text(label)
                    .companionFont(size: 10, weight: .medium)
            }
            .companionDimmedForeground(0.5)

            Text(value)
                .companionFont(size: 13, weight: .semibold)
                .companionDimmedForeground(0.9)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(stroke: .white.opacity(0.08)))
    }

    private func summarySection(run: ReviewRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("摘要", icon: "text.alignleft")

            let summaryItems = run.summaryTop3.enumerated().map { ("重点 \($0.offset + 1)", $0.element) }
            if summaryItems.isEmpty, run.summaryRisk == nil, run.summaryMissed == nil {
                placeholderLine("这次回顾没有提取到摘要。")
            } else {
                ForEach(summaryItems, id: \.0) { label, item in
                    summaryRow(label: label, text: item.text)
                }
                if let risk = run.summaryRisk {
                    summaryRow(label: "风险", text: risk.text)
                }
                if let missed = run.summaryMissed {
                    summaryRow(label: "遗漏", text: missed.text)
                }
            }
        }
        .sectionPanel()
    }

    private var todosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("待办", icon: "checklist")

            if let commandError {
                Text(commandError)
                    .companionFont(size: 12)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.companionStatusReveal)
            }

            let pending = todos.filter { $0.status == .pending }
            if pending.isEmpty {
                placeholderLine("这次回顾没有待办。")
            } else {
                ForEach(pending.prefix(8)) { todo in
                    todoRow(todo)
                }
            }
        }
        .sectionPanel()
    }

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("高亮信息", icon: "highlighter")

            if highlights.isEmpty {
                placeholderLine("这次回顾没有高亮。")
            } else {
                ForEach(highlights.prefix(10)) { highlight in
                    highlightRow(highlight)
                }
            }
        }
        .sectionPanel()
    }

    private func todoRow(_ todo: ReviewTodo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: todo.direction == .mine ? "person.fill.checkmark" : "questionmark.circle.fill")
                .companionFont(size: 12, weight: .medium)
                .foregroundColor(todo.direction == .mine ? .cyan.opacity(0.9) : .orange.opacity(0.9))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(todo.content)
                    .companionFont(size: 12, weight: .medium)
                    .companionDimmedForeground(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                Text(todoMeta(todo))
                    .companionFont(size: 10)
                    .companionDimmedForeground(0.42)
            }

            Spacer(minLength: 8)

            Button("完成") {
                completeTodo(todo)
            }
            .buttonStyle(CompanionPressStyle())
            .controlSize(.small)
            .foregroundColor(.cyan.opacity(0.9))
        }
        .padding(.vertical, 3)
    }

    private func highlightRow(_ highlight: ReviewHighlight) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(categoryLabel(highlight.category))
                    .companionFont(size: 10, weight: .semibold)
                    .foregroundColor(.cyan.opacity(0.85))
                Text(highlight.sourceChatName)
                    .companionFont(size: 10)
                    .companionDimmedForeground(0.5)
                Spacer()
                Text(highlight.date.formatted(date: .abbreviated, time: .shortened))
                    .companionFont(size: 10)
                    .companionDimmedForeground(0.42)
            }

            Text(highlight.summary)
                .companionFont(size: 12)
                .companionDimmedForeground(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .companionFont(size: 12, weight: .semibold)
            Text(text)
                .companionFont(size: 13, weight: .semibold)
        }
        .companionDimmedForeground(0.82)
    }

    private func summaryRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .companionFont(size: 10, weight: .semibold)
                .foregroundColor(.cyan.opacity(0.78))
            Text(text)
                .companionFont(size: 12)
                .companionDimmedForeground(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholderLine(_ text: String) -> some View {
        Text(text)
            .companionFont(size: 12)
            .companionDimmedForeground(0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func messagePanel(
        icon: String,
        title: String,
        detail: String,
        tint: Color,
        actionTitle: String? = nil,
        actionEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .companionFont(size: 14, weight: .semibold)
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .companionFont(size: 13, weight: .semibold)
                    .companionDimmedForeground(0.9)
                Text(detail)
                    .companionFont(size: 12)
                    .companionDimmedForeground(0.56)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(tint)
                    .disabled(!actionEnabled)
                    .help(actionEnabled ? "" : "正在生成回顾")
                    .accessibilityHint(actionEnabled ? "" : "正在生成回顾")
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(stroke: tint.opacity(0.24)))
    }

    private func panelBackground(stroke: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }

    private var statusLine: String {
        Self.statusLine(
            isRunning: isRunning, runningText: runningText, errorText: errorText,
            abandoned: abandonedRun, latest: latestRun
        )
    }

    /// A run that died leaves a `failed` row and no live job to report it, so
    /// without this the page labels an older period 已完成 after a relaunch and
    /// the user reads today's review as already done.
    static func statusLine(
        isRunning: Bool, runningText: String, errorText: String?,
        abandoned: ReviewRun?, latest: ReviewRun?
    ) -> String {
        func stamp(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: .shortened)
        }
        if isRunning { return runningText }
        if let abandoned, errorText == nil {
            return latest == nil
                ? "最近一次回顾（\(stamp(abandoned.generatedAt))）没有完成"
                : "最近一次回顾（\(stamp(abandoned.generatedAt))）没有完成 · 下面是上次成功的结果"
        }
        if let latest {
            let status = latest.status == .partial ? "部分完成" : "已完成"
            return "\(status) · \(stamp(latest.generatedAt))"
        }
        return "从你关注的对话生成回顾"
    }

    private var runningText: String {
        switch currentState {
        case .resolvingScope:
            return "正在确定回顾范围"
        case .screeningGroups:
            return "正在筛选相关群聊"
        case .analyzingChats(let progress, let total):
            return "正在分析对话 \(progress)/\(total)"
        case .synthesizingSummary:
            return "正在生成摘要"
        case .detectingRedBanner:
            return "正在检查高风险待办"
        default:
            return "正在生成回顾"
        }
    }

    private func todoMeta(_ todo: ReviewTodo) -> String {
        var parts = [todo.sourceChatName]
        if let deadline = todo.deadline {
            parts.append("截止 \(deadline.formatted(date: .abbreviated, time: .shortened))")
        }
        if todo.carryCount > 0 {
            parts.append("延续 \(todo.carryCount) 次")
        }
        return parts.joined(separator: " · ")
    }

    private func categoryLabel(_ category: HighlightCategory) -> String {
        switch category {
        case .decision: return "决策"
        case .progress: return "进展"
        case .discussion: return "讨论"
        case .risk: return "风险"
        }
    }

    private func completeTodo(_ todo: ReviewTodo) {
        let changes = monitor.hudStore.updateTodoStatus(
            todoID: todo.id,
            status: .completed,
            completedAt: Date()
        )
        guard changes > 0 else {
            commandError = CompanionInteractionCopy.retrospectiveTodoCompleteFailed
            return
        }
        commandError = nil
        refreshLatestRun()
    }

    private func runJob() {
        errorText = nil
        isRunning = true
        currentState = .resolvingScope
        monitor.retrospectiveJob.run(
            mode: .sinceLastRetrospective(lastRunEnd: monitor.hudStore.latestCompletedRun()?.rangeEnd),
            myUsername: monitor.myUsername,
            myDisplayName: monitor.myDisplayName
        )
    }

    private func apply(state: RetrospectiveJob.State) {
        currentState = state
        switch state {
        case .completed:
            isRunning = false
            errorText = nil
            // The job's own run id is not threaded through on purpose: the row
            // the page shows and the abandonment flag must come from one read.
            refreshLatestRun()
       case .partial(_, let failedChats):
           isRunning = false
            errorText = failedChats.isEmpty ? nil : CompanionInteractionCopy.retrospectivePartial(failedChats)
            refreshLatestRun()
        case .failed(let message):
           isRunning = false
            errorText = CompanionInteractionCopy.displayableRetrospectiveFailure(message)
            refreshLatestRun()
        case .idle:
            isRunning = false
            refreshLatestRun()
        default:
            isRunning = true
        }
    }

    private func refreshLatestRun() {
        let state = Self.runState(from: monitor.hudStore)
        abandonedRun = state.abandoned
        guard let run = state.displayed else {
            latestRun = nil
            highlights = []
            todos = []
            return
        }
        latestRun = run
        highlights = monitor.hudStore.highlights(for: run.id)
        todos = monitor.hudStore.todos(for: run.id)
    }

    /// One function decides both fields on purpose: the flag used to be set
    /// here and cleared again by `load()` one line later, which made the
    /// honest status line unreachable whenever any successful run existed.
    ///
    /// The row the page can display is always a successful one, so "was the
    /// current period reviewed?" has to be answered from the newest row of ANY
    /// status: a `failed` run, or a `running` row whose job died with the app
    /// (it is only reaped into `failed` after 35 minutes), means the newest
    /// attempt never produced anything to show.
    static func runState(from store: HUDStore) -> (displayed: ReviewRun?, abandoned: ReviewRun?) {
        let displayed = store.latestCompletedRun()
        guard let newest = store.latestReviewRunAnyStatus(),
              newest.status == .failed || newest.status == .running else {
            return (displayed, nil)
        }
        return (displayed, newest)
    }
}

private extension View {
    func sectionPanel() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}
