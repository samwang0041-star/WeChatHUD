import SwiftUI

struct InsightKPIGrid: View {
    let overview: ChatInsightEngine.GlobalOverview

    var body: some View {
        let rowA = [
            KPI(label: "消息总量", value: "\(overview.totalMessages)", hint: Self.densityHint(overview), status: densityStatus(overview.recentDensityRatio)),
            KPI(label: "非工时占比", value: "\(Int(overview.afterHoursRatio * 100))%", hint: overview.afterHoursRatio > 0.4 ? "偏多" : "健康", status: overview.afterHoursRatio > 0.4 ? .red : overview.afterHoursRatio > 0.2 ? .orange : .green),
           KPI(label: "平均响应", value: RelativeTimeFormatter.durationLabel(overview.avgResponseSeconds), hint: responseHint(overview.avgResponseSeconds), status: responseStatus(overview.avgResponseSeconds)),
        ]
        let rowB = [
            KPI(label: "回复率", value: "\(Int(overview.responseRate * 100))%", hint: overview.responseRate >= 0.8 ? "稳定" : overview.responseRate >= 0.6 ? "一般" : "偏低", status: overview.responseRate >= 0.8 ? .green : overview.responseRate >= 0.6 ? .orange : .red),
            // 0 完成 / 0 到期 used to render as 「100%」 with a green dot: an
            // empty denominator praised someone for perfect follow-through on
            // commitments they never made. The rate is undefined here, so say
            // there is nothing to grade instead of grading it.
            commitmentKPI(overview),
            // This card used to print a verdict — 「注意力偏离」 below 10%.
            // The ratio's denominator is the user's own VIP marking, so anyone
            // who follows one colleague in a hundred chats was told their
            // attention is off-track no matter what they do: the judgement
            // could not be acted on, only endured. It now states the dimension
            // the number is measured over.
            KPI(label: "VIP 占比", value: "\(Int(overview.vipMessageRatio * 100))%", hint: "\(Int((overview.vipMessageRatio * Double(overview.totalMessages)).rounded())) 条 / 共 \(overview.totalMessages) 条", status: .neutral),
        ]
        return VStack(spacing: 10) {
            HStack(spacing: 10) { ForEach(rowA, id: \.label) { kpiCard($0) } }
            HStack(spacing: 10) { ForEach(rowB, id: \.label) { kpiCard($0) } }
        }
    }

    private struct KPI: Hashable {
        let label: String
        let value: String
        let hint: String
        let status: KPIStatus
    }

    private enum KPIStatus {
        case green, orange, red, neutral
        var color: Color {
            switch self {
            case .green: return .green
            case .orange: return .orange
            case .red: return .red
            case .neutral: return .secondary
            }
        }
    }

    private func kpiCard(_ kpi: KPI) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(kpi.label)
                    .companionFont(size: 10)
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(kpi.status.color)
                    .frame(width: 6, height: 6)
            }
            Text(kpi.value)
                .companionFont(size: WorkspaceType.title, weight: .semibold, design: .rounded).monospacedDigit()
                .foregroundColor(.primary)
            Text(kpi.hint)
                .companionFont(size: 10)
                .foregroundColor(kpi.status.color.opacity(0.8))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionPanelFace()
    }

    /// The measured pair, not a fabricated delta. This used to print a
    /// percentage of two daily averages as 「-100% 近期偏闲」 — a broken
    /// numerator (a chat's whole history counted whenever its latest message
    /// was recent) dressed in the most dramatic number the format has. Now the
    /// numerator is the seven day-buckets themselves (`InsightRecentWindow`),
    /// so the honest move is to state both averages — the §78 statement form —
    /// and let the status dot grade them. There is no percentage left to hit
    /// a floor when the week is quiet.
    ///
    /// `nil` means the two spans are the same span: a 7-day-or-shorter window
    /// cannot compare "recent" against "overall", and printing 节奏正常 for that
    /// would be a verdict on no evidence.
    static func densityHint(_ overview: ChatInsightEngine.GlobalOverview) -> String {
        guard let recent = overview.recentDailyAvg, let overall = overview.overallDailyAvg else {
            return "时间范围不足 7 天，无法比较近期与整体"
        }
        return "近期日均 \(daily(recent)) · 窗口日均 \(daily(overall))"
    }

    /// One decimal where it carries information, none where it does not.
    private static func daily(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    private func densityStatus(_ ratio: Double?) -> KPIStatus {
        guard let ratio else { return .neutral }
        if ratio > 1.5 { return .red }
        if ratio > 1.3 || ratio < 0.7 { return .orange }
        return .green
    }

    private func commitmentKPI(_ overview: ChatInsightEngine.GlobalOverview) -> KPI {
        guard overview.fulfilledCommitments + overview.overdueCommitments > 0 else {
            return KPI(label: "承诺履约", value: "—", hint: "还没有承诺记录", status: .neutral)
        }
        return KPI(
            label: "承诺履约",
            value: "\(Int(overview.commitmentCompletionRate * 100))%",
            hint: "\(overview.fulfilledCommitments) 已完成 / \(overview.overdueCommitments) 已到期",
            status: overview.commitmentCompletionRate >= 0.8 ? .green
                : overview.commitmentCompletionRate >= 0.6 ? .orange : .red
        )
    }

    private func responseHint(_ seconds: Double) -> String {
        if seconds <= 0 { return "—" }
        if seconds < 1800 { return "快" }
        if seconds < 7200 { return "一般" }
        return "慢"
    }

    private func responseStatus(_ seconds: Double) -> KPIStatus {
        if seconds <= 0 { return .neutral }
        if seconds < 1800 { return .green }
        if seconds < 7200 { return .orange }
        return .red
    }
}
