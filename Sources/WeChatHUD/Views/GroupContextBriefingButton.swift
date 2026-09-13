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

    var body: some View {
        let state = monitor.groupContextState(for: notification)

        VStack(alignment: .leading, spacing: 8) {
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
                errorBody(state.errorMessage ?? IslandBriefingCopy.missing)
            }

            footer
        }
        .padding(IslandMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IslandInk.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        Text(IslandBriefingCopy.title)
            .islandDisplay()
            .foregroundStyle(IslandInk.primary)
    }

    private func briefingBody(_ briefing: GroupContextBriefing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hero = briefingHero(briefing) {
                Text(hero)
                    .islandRowTitle()
                    .foregroundStyle(IslandInk.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let situation = trimmed(briefing.situation), situation != briefingHero(briefing) {
                quietLine(label: IslandBriefingCopy.situation, text: situation)
            }
            if let next = trimmed(briefing.nextStep) {
                quietLine(label: IslandBriefingCopy.next, text: next)
            }
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(notification.senderName) · \(CompanionProductCopy.clockLabel(notification.timestamp))")
                .islandMeta()
                .foregroundStyle(IslandInk.meta)
            Text(notification.snippet)
                .islandRowBody()
                .foregroundStyle(IslandInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
            } label: {
                Text(IslandBriefingCopy.openConversation)
            }
            .buttonStyle(CompanionPressStyle())
            .islandMeta()
            .foregroundStyle(CompanionPalette.islandMint)
        }
    }

    private func briefingHero(_ briefing: GroupContextBriefing) -> String? {
        trimmed(briefing.whyMentioned) ?? trimmed(briefing.situation)
    }

    private func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func quietLine(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .islandMicro()
                .foregroundStyle(IslandInk.tertiary)
                .frame(width: 36, alignment: .leading)
            Text(text)
                .islandRowBody()
                .foregroundStyle(IslandInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(IslandBriefingCopy.loading)
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
        }
        .padding(.vertical, 12)
    }

    private func errorBody(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .islandMicro()
                .foregroundStyle(IslandChrome.glowAmber)
            Text(message)
                .islandRowBody()
                .foregroundColor(IslandInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            // Retry keeps the message's own line, so a failed load does not
            // grow the card (or the panel ceiling) the way a new row would.
            Button(BriefingRetryAction.label) {
                BriefingRetryAction.perform(monitor, notification: notification)
            }
            .buttonStyle(CompanionPressStyle())
            .islandButton()
            .foregroundStyle(CompanionPalette.islandMint)
            .accessibilityHint(IslandBriefingCopy.retryHint)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Button {
                monitor.openWeChatChat(notification.chatUsername)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text(IslandBriefingCopy.openWeChat)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(IslandPillButtonStyle(emphasized: true))
            .accessibilityLabel(IslandBriefingCopy.openWeChat)

            Button {
                // onChange below is the single place that syncs panelState —
                // calling setSnoozeMenuExpanded here too would double-fire it.
                showSnooze.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(IslandBriefingCopy.snooze)
                }
            }
            .buttonStyle(IslandPillButtonStyle())
            .accessibilityLabel(IslandBriefingCopy.snooze)
            .accessibilityHint("打开稍后提醒时间")
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
        }
    }
}

/// The action behind the briefing card's retry button.
///
/// Kept out of the view body so the wiring is assertable without hosting
/// SwiftUI: the forced refresh is the point — a plain
/// `loadGroupContextBriefing` no-ops while a briefing is already cached, which
/// is exactly the stale-briefing-plus-error state the button renders in.
@MainActor
enum BriefingRetryAction {
    static var label: String { IslandBriefingCopy.retry }

    static func perform(_ monitor: ChatMonitor, notification: HUDNotification) {
        monitor.loadGroupContextBriefing(for: notification, forceRefresh: true)
    }
}

enum IslandBriefingCopy {
    static let title = "为什么找你"
    static let openWeChat = "去微信回复"
    static let snooze = "稍后提醒"
    static let situation = "在聊"
    static let next = "下一步"
    static let openConversation = "打开对话"
    static let retry = "再试一次"
    static let retryHint = "再整理一次这段群聊"
    static let loading = "正在看群里刚说了什么…"
    static let missing = "暂时看不到这段前后文"
}
