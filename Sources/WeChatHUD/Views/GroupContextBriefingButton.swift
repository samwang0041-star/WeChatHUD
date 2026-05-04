import SwiftUI

struct GroupContextBriefingButton: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    let notification: HUDNotification
    let compact: Bool

    @State private var showingPopover = false

    init(notification: HUDNotification, compact: Bool = false) {
        self.notification = notification
        self.compact = compact
    }

    var body: some View {
        let state = monitor.groupContextState(for: notification)

        Button {
            showingPopover = true
            monitor.loadGroupContextBriefing(for: notification)
        } label: {
            HStack(spacing: 4) {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Text(state.isLoading ? "分析中…" : "什么情况")
                    .font(.system(size: compact ? 10 : 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.86))
            .padding(.horizontal, compact ? 8 : 7)
            .padding(.vertical, compact ? 4 : 3)
            .background(buttonBackground(state: state))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 7 : 6, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .cornerRadius(compact ? 7 : 6)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            GroupContextBriefingPopover(notification: notification)
                .environmentObject(monitor)
                .environmentObject(panelState)
        }
        .onChange(of: showingPopover) { _, isOpen in
            panelState.popoverOpen = isOpen
        }
    }

    private func buttonBackground(state: GroupContextBriefingLoadState) -> Color {
        if state.isLoading {
            return Color.orange.opacity(0.22)
        }
        if let briefing = state.briefing {
            return briefing.source == .ai
                ? Color.accentColor.opacity(0.22)
                : Color.white.opacity(0.12)
        }
        return Color.white.opacity(0.08)
    }
}

private struct GroupContextBriefingPopover: View {
    @EnvironmentObject var monitor: ChatMonitor

    let notification: HUDNotification

    private var allowsDeepActionContext: Bool {
        notification.supportsDeepActionContext
    }

    var body: some View {
        let state = monitor.groupContextState(for: notification)

        VStack(alignment: .leading, spacing: 12) {
            header(state: state)

            if let briefing = state.briefing {
                briefingBody(briefing)
            } else if state.isLoading {
                loadingBody
            } else {
                errorBody(state.errorMessage ?? "还没有拿到上下文简报")
            }

            footer(state: state)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(state: GroupContextBriefingLoadState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("什么情况")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(notification.chatName) · \(notification.senderName)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let briefing = state.briefing {
                HStack(spacing: 6) {
                    Text(briefing.source.label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(briefing.source == .ai ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15))
                        .cornerRadius(4)
                    Text("置信 \(Int(briefing.confidence * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func briefingBody(_ briefing: GroupContextBriefing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            section("发生了什么", text: briefing.situation)
            section("为什么@你", text: briefing.whyMentioned)
            section("当前状态", text: briefing.currentStatus)
            section("下一步", text: briefing.nextStep)
            if !briefing.participants.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("关键参与人")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    FlowChips(items: briefing.participants)
                }
            }

            if allowsDeepActionContext, let bg = briefing.deepBackground {
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("深度分析")
                        .font(.system(size: 11, weight: .bold))
                    section("背景", text: bg)
                    if let want = briefing.deepWhatTheyWant {
                        section("为什么提到你", text: want)
                    }
                    if let stakeholders = briefing.deepStakeholders, !stakeholders.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("利益相关方")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                            FlowChips(items: stakeholders)
                        }
                    }
                    if let position = briefing.deepYourPosition {
                        section("你的立场", text: position)
                    }
                    if let action = briefing.deepSuggestedAction {
                        section("下一步参考", text: action)
                    }
                    if let timing = briefing.deepSuggestedTiming {
                        section("建议时机", text: timing)
                    }
                    if let risk = briefing.deepRiskIfIgnore {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text("风险：\(risk)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在整理群聊上下文…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
    }

    private func errorBody(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .padding(.vertical, 12)
    }

    private func footer(state: GroupContextBriefingLoadState) -> some View {
        HStack(spacing: 8) {
            Button("重新分析") {
                monitor.loadGroupContextBriefing(for: notification, forceRefresh: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let briefing = state.briefing {
                Button("复制结果") {
                    WeChatLauncher.copyText(copyText(for: briefing, includeDeepAction: allowsDeepActionContext))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button("打开群聊") {
                WeChatLauncher.openChat(named: notification.chatName)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyText(for briefing: GroupContextBriefing, includeDeepAction: Bool) -> String {
        var lines = [
            "发生了什么：\(briefing.situation)",
            "为什么@你：\(briefing.whyMentioned)",
            "当前状态：\(briefing.currentStatus)",
            "下一步：\(briefing.nextStep)"
        ]
        guard includeDeepAction else { return lines.joined(separator: "\n") }
        if let bg = briefing.deepBackground {
            lines.append("")
            lines.append("【深度分析】")
            lines.append("背景：\(bg)")
        }
        if let want = briefing.deepWhatTheyWant {
            lines.append("为什么提到你：\(want)")
        }
        if let stakeholders = briefing.deepStakeholders, !stakeholders.isEmpty {
            lines.append("利益相关方：\(stakeholders.joined(separator: "、"))")
        }
        if let position = briefing.deepYourPosition {
            lines.append("你的立场：\(position)")
        }
        if let action = briefing.deepSuggestedAction {
            lines.append("下一步参考：\(action)")
        }
        if let timing = briefing.deepSuggestedTiming {
            lines.append("建议时机：\(timing)")
        }
        if let risk = briefing.deepRiskIfIgnore {
            lines.append("风险：\(risk)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(5)
            }
            Spacer(minLength: 0)
        }
    }
}
