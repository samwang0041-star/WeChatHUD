import SwiftUI
import AppKit

/// 日报 tab — unified daily report with metrics, highlights, actions,
/// risks, tomorrow focus, and copyable WeChat draft.
struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.07))
            content
        }
        .task {
            await monitor.loadDailyReport()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("日报")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(.leading, 4)
            Spacer()
            Button(action: {
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if monitor.dailyReport == nil && monitor.dailyReportGeneratedAt == nil {
            loadingState
        } else if let report = monitor.dailyReport {
            reportContent(report: report)
        } else {
            emptyState("日报生成失败，请稍后重试")
        }
    }

    private func reportContent(report: DailyReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                metricsSection(report: report)
                divider
                if let narrative = report.narrative {
                    narrativeSection(narrative: narrative)
                    divider
                }
                if !report.highlights.isEmpty {
                    highlightsSection(highlights: report.highlights)
                    divider
                }
                if !report.actions.isEmpty {
                    actionsSection(actions: report.actions)
                    divider
                }
                if !report.risks.isEmpty {
                    risksSection(risks: report.risks)
                    divider
                }
                if let tomorrowFocus = report.tomorrowFocus {
                    tomorrowSection(focus: tomorrowFocus)
                    divider
                }
                if let draft = report.wechatDraft {
                    wechatDraftSection(draft: draft)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text("正在生成日报…")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    // MARK: - Metrics

    private func metricsSection(report: DailyReport) -> some View {
        let m = report.metrics
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("今日概览")
            HStack(spacing: 6) {
                statPill(label: "消息", value: "\(m.unreadMessageCount)", color: .blue)
                statPill(label: "待办", value: "\(m.pendingTodoCount + m.pendingAskCount)", color: m.pendingTodoCount + m.pendingAskCount > 0 ? .orange : .white)
                if m.overdueCommitmentCount > 0 {
                    statPill(label: "超期", value: "\(m.overdueCommitmentCount)", color: .red)
                }
                statPill(label: "回复", value: "\(m.replyDebtCount)", color: m.replyDebtCount > 0 ? .cyan : .white)
                if m.highlightCount > 0 {
                    statPill(label: "高亮", value: "\(m.highlightCount)", color: .green)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Narrative

    private func narrativeSection(narrative: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("今日回顾")
            Text(narrative)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Highlights

    private func highlightsSection(highlights: [DailyReportHighlight]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("今日高亮", count: highlights.count)
            ForEach(highlights.prefix(6)) { h in
                highlightRow(h)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func highlightRow(_ h: DailyReportHighlight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(categoryLabel(h.category))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(categoryColor(h.category))
                Text(h.sourceChatName)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.42))
                Spacer()
                if h.confidence < 0.8 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange.opacity(0.7))
                }
            }
            Text(h.summary)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            if let snippet = h.quotedSnippet {
                Text("「\(snippet)」")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(panelBackground)
    }

    // MARK: - Actions

    private func actionsSection(actions: [DailyReportAction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("需要处理", count: actions.count)
            ForEach(actions.prefix(8)) { a in
                actionRow(a)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func actionRow(_ a: DailyReportAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            urgencyBadge(a.urgency)

            VStack(alignment: .leading, spacing: 3) {
                Text(a.content)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(typeLabel(a.type))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                    Text(a.sourceChatName)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                    if let deadline = a.deadline {
                        Text(deadlineText(deadline))
                            .font(.system(size: 9))
                            .foregroundColor(deadlineColor(deadline))
                    }
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Risks

    private func risksSection(risks: [DailyReportRisk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("风险与异常", count: risks.count)
            ForEach(risks.prefix(5)) { r in
                riskRow(r)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func riskRow(_ r: DailyReportRisk) -> some View {
        HStack(alignment: .top, spacing: 8) {
            severityDot(r.severity)

            VStack(alignment: .leading, spacing: 2) {
                Text(r.description)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                if let name = r.sourceChatName {
                    Text(name)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Tomorrow

    private func tomorrowSection(focus: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("明天重点")
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.85))
                    .padding(.top, 1)
                Text(focus)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - WeChat Draft

    private func wechatDraftSection(draft: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("微信日报草稿")
                Spacer()
                Button(action: {
                    WeChatLauncher.copyText(draft)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("复制")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 14)

            Text(draft)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Shared

    private var divider: some View {
        Divider()
            .background(Color.white.opacity(0.07))
            .padding(.horizontal, 10)
    }

    private func sectionLabel(_ label: String, count: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            if let count = count {
                Text("\(count)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private func statPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color == .white ? .white : color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color == .white ? Color.white.opacity(0.07) : color.opacity(0.12))
        .cornerRadius(5)
    }

    private func urgencyBadge(_ urgency: ActionUrgency) -> some View {
        let (text, color) = urgencyStyle(urgency)
        return Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func urgencyStyle(_ urgency: ActionUrgency) -> (String, Color) {
        switch urgency {
        case .critical: return ("紧急", .red)
        case .high:     return ("高", .orange)
        case .medium:   return ("中", .yellow)
        case .low:      return ("低", .white.opacity(0.5))
        }
    }

    private func severityDot(_ severity: RiskSeverity) -> some View {
        Circle()
            .fill(severityColor(severity))
            .frame(width: 6, height: 6)
            .padding(.top, 4)
    }

    private func severityColor(_ severity: RiskSeverity) -> Color {
        switch severity {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow.opacity(0.6)
        }
    }

    private func categoryLabel(_ category: HighlightCategory) -> String {
        switch category {
        case .decision:    return "决策"
        case .progress:    return "进展"
        case .discussion:  return "讨论"
        case .risk:        return "风险"
        }
    }

    private func categoryColor(_ category: HighlightCategory) -> Color {
        switch category {
        case .decision:   return .cyan.opacity(0.85)
        case .progress:   return .green.opacity(0.8)
        case .discussion: return .white.opacity(0.5)
        case .risk:       return .orange.opacity(0.85)
        }
    }

    private func typeLabel(_ type: DailyReportActionType) -> String {
        switch type {
        case .todo:        return "待办"
        case .commitment:  return "承诺"
        case .replyDebt:   return "回复"
        case .ask:         return "请求"
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
        return .white.opacity(0.4)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.045))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }
}

// MARK: - ForEach conformance

extension DailyReportHighlight: Identifiable {
    var id: String { "\(sourceChatUsername)-\(summary.hashValue)" }
}

extension DailyReportAction: Identifiable {
    var id: String { "\(type.rawValue)-\(relatedID)" }
}

extension DailyReportRisk: Identifiable {
    var id: String { "\(type.rawValue)-\(description.hashValue)" }
}
