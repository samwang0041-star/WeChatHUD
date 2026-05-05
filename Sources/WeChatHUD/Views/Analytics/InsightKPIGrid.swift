import SwiftUI

struct InsightKPIGrid: View {
    let overview: ChatInsightEngine.GlobalOverview

    var body: some View {
        let rowA = [
            KPI(label: "消息总量", value: "\(overview.totalMessages)", hint: densityHint(overview.recentDensityRatio), status: densityStatus(overview.recentDensityRatio)),
            KPI(label: "非工时占比", value: "\(Int(overview.afterHoursRatio * 100))%", hint: overview.afterHoursRatio > 0.4 ? "偏多" : "健康", status: overview.afterHoursRatio > 0.4 ? .red : overview.afterHoursRatio > 0.2 ? .orange : .green),
            KPI(label: "平均响应", value: formatResponseTime(overview.avgResponseSeconds), hint: responseHint(overview.avgResponseSeconds), status: responseStatus(overview.avgResponseSeconds)),
        ]
        let rowB = [
            KPI(label: "回复率", value: "\(Int(overview.responseRate * 100))%", hint: overview.responseRate >= 0.8 ? "稳定" : overview.responseRate >= 0.6 ? "一般" : "偏低", status: overview.responseRate >= 0.8 ? .green : overview.responseRate >= 0.6 ? .orange : .red),
            KPI(label: "承诺履约", value: "\(Int(overview.commitmentCompletionRate * 100))%", hint: "\(overview.fulfilledCommitments) 已完成 / \(overview.overdueCommitments) 超期", status: overview.commitmentCompletionRate >= 0.8 ? .green : overview.commitmentCompletionRate >= 0.6 ? .orange : .red),
            KPI(label: "VIP 占比", value: "\(Int(overview.vipMessageRatio * 100))%", hint: overview.vipMessageRatio < 0.1 ? "注意力偏离" : "合理", status: overview.vipMessageRatio < 0.1 ? .orange : .green),
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
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(.primary)
            Text(kpi.hint)
                .font(.system(size: 10))
                .foregroundColor(kpi.status.color.opacity(0.8))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func densityHint(_ ratio: Double) -> String {
        if ratio > 1.3 { return "+\(Int((ratio - 1) * 100))% 近期偏忙" }
        if ratio < 0.7 { return "-\(Int((1 - ratio) * 100))% 近期偏闲" }
        return "节奏正常"
    }

    private func densityStatus(_ ratio: Double) -> KPIStatus {
        if ratio > 1.5 { return .red }
        if ratio > 1.3 || ratio < 0.7 { return .orange }
        return .green
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

    private func formatResponseTime(_ seconds: Double) -> String {
        if seconds <= 0 { return "--" }
        if seconds < 60 { return "\(Int(seconds))秒" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟" }
        return "\(String(format: "%.1f", seconds / 3600))小时"
    }
}
