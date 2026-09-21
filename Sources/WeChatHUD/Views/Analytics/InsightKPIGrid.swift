import SwiftUI

struct InsightKPIGrid: View {
    let overview: ChatInsightEngine.GlobalOverview

    var body: some View {
        let rowA = [
            KPI(label: "消息总量", value: "\(overview.totalMessages)", hint: densityHint(overview.recentDensityRatio), status: densityStatus(overview.recentDensityRatio)),
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
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(kpi.status.color)
                    .frame(width: 6, height: 6)
            }
            Text(kpi.value)
                .font(.system(size: WorkspaceType.title, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.primary)
            Text(kpi.hint)
                .font(.system(size: 10))
                .foregroundColor(kpi.status.color.opacity(0.8))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionPanelFace()
    }

    /// Direction only. The number this used to print was a ratio of two
    /// averages (`近 7 天日均 / 全窗口日均`) dressed as a percentage delta, so
    /// 「-100% 近期偏闲」 was both unreadable and — the numerator counted a
    /// chat's whole window history whenever its latest message was recent —
    /// not a count of the last seven days at all. Words carry the same guidance
    /// without implying a precision the computation does not have.
    ///
    /// `nil` means the two spans are the same span: a 7-day-or-shorter window
    /// cannot compare "recent" against "overall", and printing 节奏正常 for that
    /// would be a verdict on no evidence.
    private func densityHint(_ ratio: Double?) -> String {
        guard let ratio else { return "时间范围不足 7 天，无法比较近期与整体" }
        if ratio > 1.3 { return "近期更活跃" }
        if ratio < 0.7 { return "近期更安静" }
        return "节奏正常"
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
