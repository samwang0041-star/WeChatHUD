import SwiftUI

struct GroupContextBriefingButton: View {
    @EnvironmentObject var monitor: ChatMonitor

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
                    WeChatLauncher.copyText(copyText(for: briefing))
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

    private func copyText(for briefing: GroupContextBriefing) -> String {
        [
            "发生了什么：\(briefing.situation)",
            "为什么@你：\(briefing.whyMentioned)",
            "当前状态：\(briefing.currentStatus)",
            "下一步：\(briefing.nextStep)"
        ].joined(separator: "\n")
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
