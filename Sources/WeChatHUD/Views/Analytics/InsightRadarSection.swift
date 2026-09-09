import SwiftUI

struct InsightRadarSection: View {
    let chatInsights: [String: ChatInsightResult]
    let chatNames: [String: String]
    let overview: ChatInsightEngine.GlobalOverview
    let briefing: GlobalBriefing?
    @Binding var expandedFindingID: String?
    let onOpenChat: (String) -> Void
    let onExpandModule: (String) -> Void

    var body: some View {
        let findings = InsightRadar.buildFindings(
            chatInsights: chatInsights,
            chatNames: chatNames,
            briefing: briefing,
            overview: overview,
            limit: 6
        )

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "radar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("洞察雷达")
                        .font(.system(size: 14, weight: .semibold))
                    Text("先看谁需要回应、哪段关系要补一句、哪些信号值得确认")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !findings.isEmpty {
                    Text("\(findings.count) 条提醒")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(5)
                }
            }

            if findings.isEmpty {
                radarEmptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(findings) { finding in
                        radarFindingRow(finding)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var radarEmptyState: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("今天没有强异常")
                    .font(.system(size: 12, weight: .semibold))
                Text("下面仍保留统计概览；如果有新消息、等待或语气变化，会自动浮到这里。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        .cornerRadius(9)
    }

    private func radarFindingRow(_ finding: InsightRadarFinding) -> some View {
        let color = radarColor(finding)
        let isExpanded = expandedFindingID == finding.id
        return Button(action: { openRadarFinding(finding) }) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(color.opacity(0.13))
                            .frame(width: 32, height: 32)
                        Image(systemName: radarIcon(finding))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(color)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(finding.source)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(color)
                                .lineLimit(1)
                            Text(radarSeverityLabel(finding.severity))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.12))
                                .cornerRadius(4)
                            Spacer(minLength: 0)
                        }

                        radarInfoLine(label: "要知道", icon: "scope", text: finding.title, primary: true)

                        if let evidence = finding.evidence, !evidence.isEmpty {
                            radarInfoLine(label: "依据", icon: "quote.bubble", text: evidence)
                        } else {
                            radarInfoLine(label: "依据", icon: "lightbulb", text: radarInterpretationOnlyText(finding))
                        }
                        if isExpanded, let reason = finding.reason, !reason.isEmpty {
                            radarInfoLine(label: "意义", icon: "lightbulb", text: reason)
                        }
                        if isExpanded {
                            radarInfoLine(label: "建议", icon: "arrowshape.turn.up.right", text: radarNextStepText(finding))
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        Text(radarActionText(finding, isExpanded: isExpanded))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(color)
                        Image(systemName: radarDisclosureIcon(finding.route))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(color.opacity(0.75))
                            .rotationEffect(.degrees(!finding.route.isChatNavigation && isExpanded ? 180 : 0))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(11)
            .background(isExpanded ? color.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func radarInfoLine(label: String, icon: String, text: String, primary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: primary ? 10 : 9, weight: .medium))
                .foregroundColor(primary ? .primary.opacity(0.75) : .secondary.opacity(0.75))
                .frame(width: 12)
                .padding(.top, 2)
            Text(label)
                .font(.system(size: primary ? 10 : 9, weight: .semibold))
                .foregroundColor(primary ? .primary.opacity(0.82) : .secondary)
                .frame(width: 34, alignment: .leading)
            Text(text)
                .font(.system(size: primary ? 12 : 10, weight: primary ? .semibold : .regular))
                .foregroundColor(primary ? .primary : .secondary)
                .lineLimit(primary ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openRadarFinding(_ finding: InsightRadarFinding) {
        switch finding.route {
        case .openChat(let chatUsername):
            onOpenChat(chatUsername)
        case .expandExplanation, .expandPressure, .expandRelationships, .expandMetrics:
            withMotion(CompanionMotion.ease(0.18)) {
                expandedFindingID = expandedFindingID == finding.id ? nil : finding.id
                switch finding.route {
                case .expandPressure:
                    onExpandModule("pressure")
                case .expandRelationships:
                    onExpandModule("relationships")
                case .expandMetrics:
                    onExpandModule("metrics")
                case .expandExplanation:
                    onExpandModule("metrics")
                case .openChat:
                    break
                }
            }
        }
    }

    private func radarActionText(_ finding: InsightRadarFinding, isExpanded: Bool) -> String {
        if finding.route.isChatNavigation { return finding.actionLabel }
        return isExpanded ? "收起" : finding.actionLabel
    }

    private func radarInterpretationOnlyText(_ finding: InsightRadarFinding) -> String {
        if let reason = finding.reason, !reason.isEmpty {
            return "按多条消息或近期互动推断：\(reason)"
        }
        switch finding.kind {
        case .pressure:
            return "来自待回、待办或承诺统计，不是单句原话。"
        case .relationship:
            return "来自互动频率或关系分布，不是单句原话。"
        case .blindSpot:
            return "来自简报检查项，点击可看概览。"
        default:
            return "来自多条消息里的弱信号，建议先确认上下文。"
        }
    }

    private func radarNextStepText(_ finding: InsightRadarFinding) -> String {
        switch finding.route {
        case .openChat:
            return finding.actionLabel
        case .expandPressure:
            return "已打开下方「压力信号」模块；优先看待处理和紧急数量。"
        case .expandRelationships:
            return "已打开下方「关系分布」模块；优先补一句轻量确认或关心。"
        case .expandMetrics:
            return "把它作为今天扫消息时的检查项；如果涉及具体对话，后续会直接定位到聊天。"
        case .expandExplanation:
            if finding.kind == .recall {
                return "先看撤回前后的上下文，避免把已改口的信息当成最终结论。"
            }
            return "我已在本卡片展开来龙去脉；下面的概览模块可继续交叉确认。"
        }
    }

    private func radarDisclosureIcon(_ route: InsightRadarFinding.Route) -> String {
        route.isChatNavigation ? "chevron.right" : "chevron.down"
    }

    private func radarColor(_ finding: InsightRadarFinding) -> Color {
        switch finding.severity {
        case .high: return .red
        case .medium:
            switch finding.kind {
            case .relationship, .blindSpot: return .orange
            case .attitude, .tone, .mood: return .purple
            default: return .accentColor
            }
        case .low: return .secondary
        }
    }

    private func radarIcon(_ finding: InsightRadarFinding) -> String {
        switch finding.kind {
        case .waiting: return "hourglass"
        case .action: return "arrowshape.turn.up.right.fill"
        case .attitude: return "person.crop.circle.badge.exclamationmark"
        case .mood: return "waveform.path.ecg"
        case .tone: return "quote.bubble.fill"
        case .recall: return "arrow.uturn.backward.circle.fill"
        case .ignored: return "bubble.left.and.exclamationmark.bubble.right"
        case .blindSpot: return "eye.trianglebadge.exclamationmark"
        case .relationship: return "person.2.wave.2"
        case .pressure: return "exclamationmark.triangle.fill"
        }
    }

    private func radarSeverityLabel(_ severity: InsightRadarFinding.Severity) -> String {
        switch severity {
        case .high: return "现在处理"
        case .medium: return "今天看一眼"
        case .low: return "可观察"
        }
    }
}
