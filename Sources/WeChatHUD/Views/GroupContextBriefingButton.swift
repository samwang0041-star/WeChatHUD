import SwiftUI

struct GroupContextBriefingButton: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    let notification: HUDNotification
    /// Retained for call-site compatibility. The chip used to render a
    /// tighter variant here; the island type scale is now dense enough that
    /// both hosts read the same, so the flag no longer changes the chrome.
    let compact: Bool

    init(notification: HUDNotification, compact: Bool = false) {
        self.notification = notification
        self.compact = compact
    }

    var body: some View {
        let state = monitor.groupContextState(for: notification)

        Button {
            let target = !panelState.briefingExpanded
            withMotion(CompanionMotion.spring) {
                panelState.setBriefingExpanded(target)
            }
            if target {
                monitor.loadGroupContextBriefing(for: notification)
            }
        } label: {
            HStack(spacing: 4) {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Text(state.isLoading ? "分析中…" : "看看什么事")
                    .islandButton()
                    .lineLimit(1)
            }
            .foregroundColor(IslandInk.primary)
            .padding(.horizontal, IslandMetrics.buttonInset)
            .padding(.vertical, 6)
            .background(buttonBackground(state: state))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(IslandInk.divider, lineWidth: 0.5)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(panelState.briefingExpanded ? "收起群聊上下文" : "看看什么事")
    }

    private func buttonBackground(state: GroupContextBriefingLoadState) -> Color {
        if state.isLoading { return BriefingChipInk.loading }
        if let briefing = state.briefing {
            return briefing.source == .ai ? BriefingChipInk.ai : BriefingChipInk.snippet
        }
        return BriefingChipInk.idle
    }
}

/// Fills for the 「看看什么事」 chip. A bordered control needs a touch more
/// presence than a row hover, so the neutral states come from the shared
/// chip washes in `IslandInk`; the two jade states keep the AI-vs-cached
/// distinction.
private enum BriefingChipInk {
    static let idle = IslandInk.chip
    static let snippet = IslandInk.chipStrong
    static let ai = CompanionPalette.jade.opacity(0.34)
    static let loading = CompanionPalette.jade.opacity(0.42)
}

/// The in-place context-briefing card, rendered inline by the surface
/// that hosts the trigger button (notification banner below the action
/// row, conversation detail inside the context section). Lives inside
/// the panel's AX tree, unlike the removed anchored popover.
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
        .padding(IslandMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IslandInk.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notification.chatName)
                .islandMeta()
                .foregroundColor(IslandInk.tertiary)
            Text("为什么 @ 你?")
                .islandDisplay()
                .foregroundColor(IslandInk.primary)
            Text("AI 解读 · 根据最近消息")
                .islandMeta()
                .foregroundColor(IslandInk.quaternary)
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
                .islandSection()
                .foregroundColor(IslandInk.tertiary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(notification.senderName) · \(CompanionProductCopy.clockLabel(notification.timestamp))")
                        .islandMeta()
                        .foregroundColor(IslandInk.secondary)
                    Text(notification.snippet)
                        .islandRowBody()
                        .foregroundColor(IslandInk.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("查看完整上下文 >") {
                    panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
                }
                .buttonStyle(.plain)
                .islandMeta()
                .foregroundStyle(CompanionPalette.islandMint)
            }
            .padding(9)
            .background(IslandInk.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在整理群聊上下文…")
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
        }
        .padding(.vertical, 12)
    }

    private func errorBody(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text(message)
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
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
                    .islandButton()
                    .foregroundStyle(IslandInk.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(CompanionPalette.jade, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showSnooze.toggle()
                panelState.setSnoozeMenuExpanded(showSnooze)
            } label: {
                Label("稍后提醒", systemImage: "clock")
                    .islandButton()
                    .foregroundStyle(IslandInk.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(showSnooze ? CompanionPalette.jade : IslandInk.chip, in: Capsule())
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
                    .islandSection()
                    .foregroundColor(IslandInk.tertiary)
                Text(text)
                    .islandRowBody()
                    .foregroundColor(IslandInk.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IslandInk.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
