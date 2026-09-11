import SwiftUI
import AppKit

/// Everything the notification banner puts on screen, derived once from the
/// notification: who, where, when, and the message.
///
/// The content is a value rather than a pile of computed properties on the view
/// so its rules can be asserted directly. A banner is a black pill full of
/// Chinese text — a test can measure it, but it can never read it back — so
/// every string the eye is supposed to see has to be testable somewhere, and
/// this is that place. The view below is then pure layout.
struct NotificationBannerContent: Equatable {
    /// The sender: the first thing the eye needs, so it outranks the
    /// conversation name when the identity line runs out of room.
    let sender: String
    /// Whether the user was @-mentioned. Drives the chip, which is the only
    /// accent colour on the surface.
    let showsMention: Bool
    /// The conversation, or `nil` when it would just repeat the sender — in a
    /// private chat `chatName == senderName`, and printing both says nothing
    /// twice.
    let conversation: String?
    /// Arrival stamp: "刚刚" / "12 分钟前" / "今天 14:32".
    let arrival: String
    /// The hero line: the message itself.
    let message: String
    /// What clicking the card does, in words — used for the tooltip and the
    /// VoiceOver action, since the action has no visible label of its own any
    /// more.
    let openLabel: String

    init(notification: HUDNotification, now: Date = Date(), calendar: Calendar = .current) {
        let rawSender = notification.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = notification.chatName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some scan paths carry no display name for the sender. A banner whose
        // identity line is blank tells the user nothing about where it came
        // from, so fall back the way the rest of the app does.
        sender = rawSender.isEmpty ? "未知发送者" : rawSender
        // `.groupAt` is by definition an @-mention, so the kind is honoured as
        // well as the flag: the chip is never dropped from a mention banner.
        showsMention = notification.isAtMention || notification.kind == .groupAt
        conversation = (chat.isEmpty || chat == sender) ? nil : chat

        arrival = CompanionProductCopy.arrivalLabel(notification.timestamp, now: now, calendar: calendar)
        message = Self.heroMessage(notification.snippet)
        openLabel = notification.canExplainContext ? "看看前后文" : "打开对话"
    }

    /// The message, laid out as one flowing block.
    ///
    /// Newlines fold into spaces: WeChat messages are routinely typed with hard
    /// breaks, and inside a three-line preview a blank line costs a whole line
    /// of the only content the banner has. The text itself is never rewritten —
    /// only whitespace runs collapse. Media-only messages have no text at all,
    /// and saying so beats an empty card.
    static func heroMessage(_ snippet: String) -> String {
        let folded = snippet
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.isEmpty ? "收到一条新消息" : folded
    }
}

/// The new-message banner that hangs below the notch.
///
/// This surface answers three questions in one glance — who, what did they say,
/// and what can I do about it. `docs/ai-butler-state-contract.md`
/// («Notification Interruption Contract») defines it as a *transient* layer, so
/// anything that does not answer one of those three is not on it:
///
///   - **The message is the page.** One hero line, full panel width, 15 pt, up
///     to three lines. It is no longer the third child of an avatar-indented
///     text column, and nothing else here is set at that size.
///   - **The identity line is a line, not a sentence.** `[avatar] 周然 @你 ·
///     群名 · 刚刚` — name, mention chip, conversation and arrival stamp as
///     separate spans, each carrying only its own emphasis. The old headline
///     glued them into "周然 在「行业合作-小程序业务交流群」@ 了你 · 今天 14:32",
///     which wrapped on long group names and made every fact equally loud.
///   - **Two decisions, both icons.** 稍后 and 关闭 sit at the trailing edge of
///     the identity line: they cost no vertical space, and the third stacked
///     row that used to hold a text action ("看看什么事") is gone. Opening the
///     conversation belongs to the whole card, which is already what the state
///     contract specifies for a body click.
///   - **The body is the tap target.** Every non-interactive element on the
///     card (text, avatar, chip) is non-hit-testable, so the full-card tap
///     surface behind them receives every click that was not on 稍后 or 关闭 —
///     one click, one effect, by construction rather than by gesture priority.
///
/// Height is the point of the redesign: every point below the notch is spent
/// on the identity line or the message, and the panel is sized from the
/// rendered result (`IslandNotificationLayout`), so a one-line message gets a
/// one-line banner instead of a 200 pt black pill with 89 pt of nothing in it.
struct NotificationBannerView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    let notification: HUDNotification
    @State private var showSnooze = false
    @State private var hovering = false

    private var content: NotificationBannerContent {
        NotificationBannerContent(notification: notification)
    }

    private var notchHeight: CGFloat {
        (NSApp.delegate as? AppDelegate)?.panel?.notch.notchHeight ?? 32
    }

    /// Width the panel gives this banner (`AppDelegate.panelSize(for:)`).
    /// The content is laid out at this width from the very first frame so
    /// the text does not re-wrap at every intermediate window width while
    /// the panel grows out of the notch — re-wrapping three lines of 19 pt
    /// text on each resize step was the stutter in the banner transition.
    private var bannerWidth: CGFloat {
        let notchWidth = (NSApp.delegate as? AppDelegate)?.panel?.notch.notchWidth ?? 200
        return IslandNotificationLayout.panelWidth(notchWidth: notchWidth)
    }

    /// The banner's own padding, applied by each surface rather than by the
    /// root: the notification surface needs its tap target and hover wash to
    /// reach the panel's edges, while the briefing card keeps the same margins.
    private var surfaceInsets: EdgeInsets {
        EdgeInsets(top: notchHeight + IslandMetrics.bannerTopGap,
                   leading: IslandMetrics.bannerInset,
                   bottom: IslandMetrics.bannerBottomGap,
                   trailing: IslandMetrics.bannerInset)
    }

    var body: some View {
        Group {
            if panelState.briefingExpanded, notification.canExplainContext {
                briefingSurface
                    .padding(surfaceInsets)
            } else {
                notificationSurface
            }
        }
        .foregroundColor(.white)
        // Fixed layout width: the panel animates its width around this
        // content, and a width-stable subtree re-renders without
        // re-running text layout.
        .frame(width: bannerWidth)
        // Report the height this content actually needs, BEFORE the
        // infinite-height frame below stretches the view to the window.
        // AppDelegate sizes the panel from this measurement, so the panel
        // hugs the banner instead of reserving a fixed budget for it.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - The banner

    private var notificationSurface: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.bannerRowGap) {
            identityLine
            Text(content.message)
                .islandMessage()
                .foregroundColor(IslandInk.primary)
                .lineSpacing(3)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
                .accessibilityLabel(content.message)
            if showSnooze {
                IslandSnoozeMenu { date in
                    showSnooze = false
                    panelState.setSnoozeMenuExpanded(false)
                    snooze(date)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(surfaceInsets)
        // Hover lives on the container, so it stays true while the cursor is
        // over the buttons too (an ancestor's hover region is not shadowed by
        // its children) — the wash is the card's "this whole thing opens"
        // signal, and it must not flicker when the cursor crosses the icons.
        .onHover { hovering = $0 }
        .background(alignment: .center) { hoverWash }
        .background { tapSurface }
        .companionAnimation(CompanionMotion.ease(0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(content.openLabel)) { openConversation() }
    }

    /// `[avatar] 周然 @你 · 群名 · 刚刚                        [稍后] [关闭]`
    ///
    /// One line of meta, three weights: the sender is the second-brightest text
    /// on the surface, the conversation and the arrival stamp are context. The
    /// group name carries `layoutPriority(-1)`, so when the line runs out of
    /// room it is the group that truncates — never the sender or the time.
    private var identityLine: some View {
        HStack(spacing: 7) {
            // The picture half of the line: no hits, so the card-wide tap
            // layer behind it receives every click that is not on an icon.
            HStack(spacing: 7) {
                // Same avatar vocabulary as the inbox rows — the first
                // character of the chat name — instead of a generic person
                // glyph that can't tell a group from a contact.
                CompanionAvatar(name: notification.chatName, size: IslandMetrics.bannerAvatar)
                Text(content.sender)
                    .islandSender()
                    .foregroundStyle(IslandInk.secondary)
                    .lineLimit(1)
                if content.showsMention {
                    mentionChip
                }
                if let conversation = content.conversation {
                    separator
                    Text(conversation)
                        .islandMeta()
                        .foregroundStyle(IslandInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                separator
                Text(content.arrival)
                    .islandMeta()
                    .foregroundStyle(IslandInk.tertiary)
                    .fixedSize()
            }
            .allowsHitTesting(false)
            Spacer(minLength: 6)
            snoozeButton
            closeButton
        }
        .frame(minHeight: IslandMetrics.bannerAvatar)
    }

    /// The banner's only accent colour. Being @-mentioned is the reason a group
    /// message is allowed to interrupt at all, so it gets the mint that every
    /// other emphasis on the island gives up.
    private var mentionChip: some View {
        Text("@你")
            .islandMicro()
            .foregroundStyle(CompanionPalette.islandMint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(CompanionPalette.islandMint.opacity(0.16), in: Capsule())
            .accessibilityLabel("提到了你")
    }

    private var separator: some View {
        Text("·")
            .islandMeta()
            .foregroundStyle(IslandInk.quaternary)
    }

    /// Hover wash: the card lights up as one clickable object. Inset a little
    /// so it reads as a control inside the island rather than a new panel.
    private var hoverWash: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(hovering ? IslandInk.hover : Color.clear)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .allowsHitTesting(false)
    }

    /// Full-card tap target, drawn *behind* the content. Every non-interactive
    /// element on the card is marked non-hit-testable, so this layer receives
    /// exactly the clicks that did not land on an icon button — deterministically,
    /// without depending on how SwiftUI arbitrates a child button against an
    /// ancestor tap gesture. That arbitration is the reason the previous
    /// revision removed the body action entirely; a body click that also
    /// triggered "关闭" would be the worst bug this surface could have.
    private var tapSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { openConversation() }
            .help(notification.canExplainContext ? "看看这句话的前后文" : "打开这段对话")
    }

    // MARK: - Briefing (in-place context card)

    private var briefingSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withMotion(CompanionMotion.spring) {
                        panelState.setBriefingExpanded(false)
                    }
                } label: {
                    Label(notification.chatName, systemImage: "chevron.left")
                        .islandRowTitle()
                        .foregroundStyle(IslandInk.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回通知")
                Spacer()
                closeButton
            }
            GroupContextBriefingCard(notification: notification)
        }
    }

    // MARK: - Controls

    private var closeButton: some View {
        Button { panelState.collapseAndYield() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? IslandInk.secondary : IslandInk.tertiary)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭通知")
        .help("关闭通知，保留待办状态")
    }

    private var snoozeButton: some View {
        // onChange below is the single place that syncs panelState —
        // calling setSnoozeMenuExpanded here too would double-fire it.
        Button {
            showSnooze.toggle()
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(showSnooze
                    ? CompanionPalette.islandMint
                    : (hovering ? IslandInk.secondary : IslandInk.tertiary))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .help("稍后提醒")
        .accessibilityLabel("稍后提醒")
        .accessibilityHint("打开稍后提醒时间")
        .onChange(of: showSnooze) { _, isOpen in
            panelState.setSnoozeMenuExpanded(isOpen)
        }
    }

    // MARK: - Actions

    /// The card action. Group mentions open the in-place briefing (the one
    /// place the banner can explain *why* it interrupted); everything else goes
    /// straight to the conversation.
    private func openConversation() {
        showSnooze = false
        panelState.setSnoozeMenuExpanded(false)
        if notification.canExplainContext {
            withMotion(CompanionMotion.spring) {
                panelState.setBriefingExpanded(true)
            }
            monitor.loadGroupContextBriefing(for: notification)
        } else {
            panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
        }
    }

    private func snooze(_ date: Date) {
        let item = notification.actionInboxItem()
        if monitor.snoozeInboxItem(item, until: date) {
            panelState.islandSnoozeUndo = (item, date)
            panelState.showToast(CompanionProductCopy.snoozeReceipt(until: date))
        }
        panelState.islandSurface = .inbox
        panelState.goExtended()
    }
}
