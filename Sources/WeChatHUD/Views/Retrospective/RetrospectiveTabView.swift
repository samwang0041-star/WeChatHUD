import SwiftUI

/// Standalone retrospective surface. It always renders a visible state:
/// empty, running, failed, or the latest completed/partial run.
struct RetrospectiveTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var latestRun: ReviewRun?
    @State private var highlights: [ReviewHighlight] = []
    @State private var todos: [ReviewTodo] = []
    @State private var currentState: RetrospectiveJob.State = .idle
    @State private var isRunning = false
    @State private var errorText: String?

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
                    tint: .orange
                )
            }

            if let run = latestRun {
                resultView(run: run)
            } else if !isRunning {
                emptyState
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.94))
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.94))
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.52))
            }

            Spacer()

            Button {
                runJob()
            } label: {
                Label(isRunning ? "生成中" : "重新生成", systemImage: isRunning ? "hourglass" : "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isRunning)
            .tint(.cyan)
        }
    }

    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(runningText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
            }

            if case .analyzingChats(let progress, let total) = currentState {
                ProgressView(value: Double(progress), total: Double(max(total, 1)))
                    .tint(.cyan)
                Text("\(progress) / \(total) 个对话")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground(stroke: .cyan.opacity(0.22)))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.cyan.opacity(0.9))

            VStack(alignment: .leading, spacing: 6) {
                Text("还没有回顾结果")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("点“重新生成”后，会从上次回顾到现在、你关注的对话里提取重点、待办和风险。第一次使用默认回顾本周。")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                runJob()
            } label: {
                Label("生成本次回顾", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.cyan)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.45))

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
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

            let pending = todos.filter { $0.status == .pending }
            if pending.isEmpty {
                placeholderLine("暂无待办。")
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
                placeholderLine("暂无高亮信息。")
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(todo.direction == .mine ? .cyan.opacity(0.9) : .orange.opacity(0.9))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(todo.content)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                Text(todoMeta(todo))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.42))
            }

            Spacer(minLength: 8)

            Button("完成") {
                monitor.hudStore.updateTodoStatus(todoID: todo.id, status: .completed, completedAt: Date())
                refreshLatestRun()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundColor(.cyan.opacity(0.9))
        }
        .padding(.vertical, 3)
    }

    private func highlightRow(_ highlight: ReviewHighlight) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(categoryLabel(highlight.category))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.cyan.opacity(0.85))
                Text(highlight.sourceChatName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.42))
                Spacer()
                Text(highlight.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            Text(highlight.summary)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.82))
    }

    private func summaryRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.cyan.opacity(0.78))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholderLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func messagePanel(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
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
        if isRunning { return runningText }
        if let run = latestRun {
            let status = run.status == .partial ? "部分完成" : "已完成"
            return "\(status) · \(run.generatedAt.formatted(date: .abbreviated, time: .shortened))"
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
        case .completed(let runID):
            isRunning = false
            errorText = nil
            load(runID: runID)
        case .partial(let runID, let failedChats):
            isRunning = false
            errorText = failedChats.isEmpty ? nil : "部分对话分析失败：\(failedChats.prefix(3).joined(separator: "、"))"
            load(runID: runID)
        case .failed(let message):
            isRunning = false
            errorText = message
            refreshLatestRun()
        case .idle:
            isRunning = false
            refreshLatestRun()
        default:
            isRunning = true
        }
    }

    private func refreshLatestRun() {
        guard let run = monitor.hudStore.latestCompletedRun() else {
            latestRun = nil
            highlights = []
            todos = []
            return
        }
        load(runID: run.id)
    }

    private func load(runID: Int) {
        guard let run = monitor.hudStore.runByID(runID) else { return }
        latestRun = run
        highlights = monitor.hudStore.highlights(for: runID)
        todos = monitor.hudStore.todos(for: runID)
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
