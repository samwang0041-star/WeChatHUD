import SwiftUI

/// The in-place context-briefing card.
///
/// This file is named after the standalone 「看看什么事」 trigger button that
/// used to live in it; that button had no host anywhere in the app (the banner
/// opens the card from its whole-card tap, and inbox rows render the briefing
/// line inline), so the orphan view is gone and only the card remains.
///
/// The card is rendered inline by the surfaces that own the briefing state —
/// the notification banner (below the identity line) and conversation detail
/// (inside the context section). It lives inside the panel's AX tree, unlike
/// the removed anchored popover.
struct GroupContextBriefingCard: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    let notification: HUDNotification
    @State private var showSnooze = false
    @State private var isSnoozing = false

    var body: some View {
        let state = monitor.groupContextState(for: notification)

        VStack(alignment: .leading, spacing: 12) {
            header

            if let briefing = state.briefing {
                if let errorMessage = state.errorMessage {
                    errorBody(errorMessage)
                        .transition(.companionStatusReveal)
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
        .companionAnimation(CompanionMotion.ease(), value: state.errorMessage)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notification.chatName)
                .islandMeta()
                .foregroundColor(IslandInk.tertiary)
            Text("为什么 @ 你？")
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
                Button {
                    panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
                } label: {
                    HStack(spacing: 3) {
                        Text("查看完整上下文")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(IslandRowButtonStyle())
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
            // Names what is being worked out and what will appear. "正在整理
            // 群聊上下文…" left the user watching an indeterminate spinner
            // with no idea what they were waiting for.
            Text("正在理出大家在聊什么、为什么找你")
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
        }
        .padding(.vertical, 12)
    }

    private func errorBody(_ message: String) -> some View {
        let retrying = monitor.groupContextState(for: notification).isLoading
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text(message)
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            // Retry keeps the message's own line, so a failed load does not
            // grow the card (or the panel ceiling) the way a new row would.
            Button {
                BriefingRetryAction.perform(monitor, notification: notification)
            } label: {
                Text(retrying ? "正在重试…" : BriefingRetryAction.label)
            }
            .buttonStyle(IslandRowButtonStyle())
            .islandButton()
            .foregroundStyle(CompanionPalette.islandMint)
            .disabled(retrying)
            .help(retrying ? "正在重新整理这段群聊" : "")
            .accessibilityHint(retrying ? "正在重新整理这段群聊" : "重新向 AI 要一次这段群聊上下文")
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Button {
                monitor.openWeChatChat(notification.chatUsername)
            } label: {
                Label("去微信回复", systemImage: "bubble.left.and.bubble.right.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IslandPillButtonStyle(emphasized: true))

            Button {
                // onChange below is the single place that syncs panelState —
                // calling setSnoozeMenuExpanded here too would double-fire it.
                withMotion(CompanionMotion.islandRowExpand()) { showSnooze.toggle() }
            } label: {
                Label(isSnoozing ? "正在保存稍后提醒" : "稍后提醒", systemImage: "clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IslandPillButtonStyle(emphasized: showSnooze))
            .disabled(isSnoozing)
            .help(isSnoozing ? "正在保存稍后提醒" : "")
            .accessibilityHint(isSnoozing ? "正在保存稍后提醒" : "打开稍后提醒时间")
            .onChange(of: showSnooze) { _, isOpen in
                panelState.setSnoozeMenuExpanded(isOpen)
            }
        }
        if showSnooze {
            IslandSnoozeMenu { date in
                let item = monitor.inboxItems.first(where: { $0.chatUsername == notification.chatUsername })
                    ?? notification.actionInboxItem()
                // A failed write keeps the card and its menu exactly where they
                // are: the card is the receipt surface (the reason arrives as a
                // toast) and the open menu is the retry entry.
                guard !isSnoozing else { return }
                isSnoozing = true
                Task { @MainActor in
                    defer { isSnoozing = false }
                    guard IslandSnoozeOutcome.apply(
                        item,
                        until: date,
                        monitor: monitor,
                        panelState: panelState
                    ) else { return }
                    showSnooze = false
                    panelState.setSnoozeMenuExpanded(false)
                    panelState.setBriefingExpanded(false)
                    panelState.islandSurface = .inbox
                    panelState.goExtended()
                }
            }
            .transition(.islandDetailReveal)
        }
        }
        .companionAnimation(CompanionMotion.islandRowExpand(), value: showSnooze)
    }

    private func card(_ title: String, text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // A tinted glyph well rather than a bare icon: the three cards
            // are a reading sequence (what is happening → why you → what
            // next), and giving each a lit marker makes the sequence
            // followable down the column instead of three identical grey
            // blocks.
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CompanionPalette.islandMint)
                .frame(width: 20, height: 20)
                .background(
                    CompanionPalette.islandMint.opacity(CompanionMotion.reduceTransparency ? 0.22 : 0.14),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
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
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape.fill(IslandInk.hover)
            if !CompanionMotion.reduceTransparency {
                // Same top-lit edge as the workspace cards, one step down:
                // the island is dark, so the highlight has to be dimmer
                // here or the cards glow.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.075), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
    }
}

/// The action behind the briefing card's 「重试」 button.
///
/// Kept out of the view body so the wiring is assertable without hosting
/// SwiftUI: the forced refresh is the point — a plain
/// `loadGroupContextBriefing` no-ops while a briefing is already cached, which
/// is exactly the stale-briefing-plus-error state the button renders in.
@MainActor
enum BriefingRetryAction {
    static let label = "重试"

    static func perform(_ monitor: ChatMonitor, notification: HUDNotification) {
        monitor.loadGroupContextBriefing(for: notification, forceRefresh: true)
    }
}
