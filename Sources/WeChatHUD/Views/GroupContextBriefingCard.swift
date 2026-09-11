import SwiftUI

/// The in-place context-briefing card, rendered inline by the surface
/// that hosts the trigger (notification banner below the action row).
/// Lives inside the panel's AX tree, unlike the removed anchored popover.
struct GroupContextBriefingCard: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    let notification: HUDNotification
    @State private var showSnooze = false

    var body: some View {
        let state = monitor.groupContextState(for: notification)

        VStack(alignment: .leading, spacing: 12) {
            header

            if let briefing = state.briefing {
                if let errorMessage = state.errorMessage {
                    errorBody(errorMessage)
                }
                briefingBody(briefing)
                originalSection
            } else if state.isLoading {
                loadingBody
            } else {
                errorBody(state.errorMessage ?? "还没有拿到这段群聊上下文")
            }

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notification.chatName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            Text("为什么 @ 你？")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text("AI 解读 · 根据最近消息")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func briefingBody(_ briefing: GroupContextBriefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            card("在聊什么", text: briefing.situation, systemImage: "bubble.left")
            card("为什么找你", text: briefing.whyMentioned, systemImage: "person")
            card("下一步", text: briefing.nextStep, systemImage: "checkmark.circle")
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原文")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(notification.senderName) · \(CompanionProductCopy.clockLabel(notification.timestamp))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(notification.snippet)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
                } label: {
                    HStack(spacing: 3) {
                        Text("查看完整上下文")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CompanionPalette.islandMint)
            }
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Button {
                WeChatLauncher.openChat(named: notification.chatName)
            } label: {
                Label("去微信回复", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(CompanionPalette.jade, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                // onChange below is the single place that syncs panelState —
                // calling setSnoozeMenuExpanded here too would double-fire it.
                showSnooze.toggle()
            } label: {
                Label("稍后提醒", systemImage: "clock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(showSnooze ? CompanionPalette.jade : Color.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开稍后提醒时间")
            .onChange(of: showSnooze) { _, isOpen in
                panelState.setSnoozeMenuExpanded(isOpen)
            }
        }
        if showSnooze {
            IslandSnoozeMenu { date in
                showSnooze = false
                panelState.setSnoozeMenuExpanded(false)
                let item = monitor.inboxItems.first(where: { $0.chatUsername == notification.chatUsername })
                    ?? notification.actionInboxItem()
                if monitor.snoozeInboxItem(item, until: date) {
                    panelState.islandSnoozeUndo = (item, date)
                    panelState.showToast(CompanionProductCopy.snoozeReceipt(until: date))
                }
                panelState.setBriefingExpanded(false)
                panelState.islandSurface = .inbox
                panelState.goExtended()
            }
        }
        }
    }

    private func card(_ title: String, text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(CompanionPalette.islandMint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(title):")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
