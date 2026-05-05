import SwiftUI
import AppKit

struct DailyReportCommandCenterView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @State private var showCompleted = false
    @State private var hoveredActionID: String?
    @State private var hoveredRiskID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report = monitor.dailyReport {
                let states = monitor.store.loadDailyReportCommandStates(
                    dateKey: report.date.dailyReportDateKey
                )
                let vm = DailyReportPresentationPolicy.buildViewModel(
                    from: report, commandStates: states
                )
                content(vm: vm, report: report)
            } else if monitor.dailyReportIsLoading {
                loadingView
            } else if let error = monitor.dailyReportError {
                emptyState("日报加载失败: \(error)")
            } else {
                emptyState("暂无日报数据，点击刷新重新生成。")
            }
        }
    }

    private func content(vm: DailyReportPresentationPolicy.CommandCenterViewModel, report: DailyReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                progressCard(vm.progress)
                divider

                if !vm.urgentActions.isEmpty {
                    sectionHeader("🔴 紧急待处理", count: vm.urgentActions.count)
                    ForEach(vm.urgentActions) { action in
                        actionCard(action, isUrgent: true)
                    }
                    divider
                }

                if !vm.activeActions.isEmpty {
                    sectionHeader("📋 待处理", count: vm.activeActions.count)
                    ForEach(vm.activeActions) { action in
                        actionCard(action, isUrgent: false)
                    }
                    divider
                }

                if !vm.completedActions.isEmpty {
                    completedSection(vm.completedActions)
                    divider
                }

                if !vm.highlights.isEmpty {
                    sectionHeader("📌 今日高亮", count: vm.highlights.count)
                    ForEach(vm.highlights) { highlight in
                        highlightCard(highlight)
                    }
                    divider
                }

                if !vm.activeRisks.isEmpty {
                    sectionHeader("⚠️ 风险与异常", count: vm.activeRisks.count)
                    ForEach(vm.activeRisks) { risk in
                        riskCard(risk)
                    }
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
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(.circular)
            Text("正在生成日报…")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color.primary.opacity(0.4))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }

    private func progressCard(_ progress: DailyReportProgressMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🎯 今日进度")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(progress.completedCount)/\(progress.totalCount) 完成")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(progressColor(progress.completionRatio))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress.completionRatio))), height: 6)
                }
            }
            .frame(height: 6)

            HStack(spacing: 12) {
                statLabel("待处理", value: progress.activeCount, color: .white)
                statLabel("已处理", value: progress.completedCount, color: .green)
                if progress.overdueCount > 0 {
                    statLabel("超期", value: progress.overdueCount, color: .red)
                }
            }
        }
        .padding(10)
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

    private func sectionHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundColor(Color.primary.opacity(0.4))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func actionCard(_ action: DailyReportAction, isUrgent: Bool) -> some View {
        let isHovered = hoveredActionID == action.id
        return HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(urgencyColor(action.urgency))
                .frame(width: 3)
                .cornerRadius(1.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.content)
                        .font(.system(size: 11, weight: isUrgent ? .semibold : .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }

                HStack(spacing: 6) {
                    urgencyChip(action.urgency)
                    Text(action.sourceChatName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if let deadline = action.deadline {
                        Text(deadlineText(deadline))
                            .font(.system(size: 9))
                            .foregroundColor(deadlineColor(deadline))
                    }
                    Spacer()
                }
            }

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: { monitor.markDailyReportActionDone(action) }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                            .frame(width: 22, height: 20)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("标记完成")

                    Button(action: { WeChatLauncher.openChat(named: action.sourceChatName) }) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 20)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("在微信中打开")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isActive in
            hoveredActionID = isActive ? action.id : nil
        }
    }

    private func completedSection(_ actions: [DailyReportAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { showCompleted.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("✅ 已完成")
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
                            .font(.system(size: 11))
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
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = highlight.quotedSnippet {
                Text("「\(snippet)」")
                    .font(.system(size: 10))
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
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                if let name = risk.sourceChatName {
                    Text(name)
                        .font(.system(size: 9))
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
                Text("AI 洞察")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.cyan.opacity(0.8))
                Spacer()
            }
            Text(narrative)
                .font(.system(size: 11))
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
                        .font(.system(size: 11))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("📋 微信日报草稿")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { WeChatLauncher.copyText(draft) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("复制")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            Text(draft)
                .font(.system(size: 10))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
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
