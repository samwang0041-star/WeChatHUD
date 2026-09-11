import SwiftUI
import AppKit

struct NotificationBannerView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    let notification: HUDNotification
    @State private var showSnooze = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if panelState.briefingExpanded, notification.canExplainContext {
                briefingSurface
            } else {
                notificationSurface
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.top, notchHeight + 12)
        .padding(.bottom, 16)
        // Fixed layout width: the panel animates its width around this
        // content, and a width-stable subtree re-renders without
        // re-running text layout.
        .frame(width: bannerWidth)
        // Report the height this content actually needs, BEFORE the
        // infinite-height frame below stretches the view to the window.
        // AppDelegate sizes the panel from this measurement, so a long
        // group name or a three-line snippet can no longer be clipped by
        // the window's bottom edge.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // No parent tap gesture: a quick-action click must have exactly one
        // effect, and closing a banner must not also open a conversation.
    }

    private var notificationSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One-line brand strip: a transient banner's top edge is its
            // most expensive real estate, so identity compresses to a
            // single row instead of a two-line block.
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CompanionPalette.islandMint)
                Text(CompanionProductCopy.brandName)
                    .font(.system(size: 13, weight: .semibold))
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
                Text(CompanionProductCopy.brandPromise)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 4)
                closeButton
            }

            HStack(alignment: .top, spacing: 10) {
                // Same avatar vocabulary as the inbox rows — the first
                // character of the chat name — instead of a generic
                // person glyph that can't tell a group from a contact.
                CompanionAvatar(name: notification.chatName, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("“\(notification.snippet)”")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("查看对话") {
                    panelState.showChatDetail(chatUsername: notification.chatUsername, chatName: notification.chatName)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CompanionPalette.islandMint)
                .accessibilityLabel("查看对话")
            }

            HStack(spacing: 8) {
                Button("看看什么事") {
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
                .buttonStyle(BannerChromeStyle(emphasized: !showSnooze))
                snoozeButton
                Spacer(minLength: 0)
            }
            if showSnooze {
                IslandSnoozeMenu { date in
                    showSnooze = false
                    panelState.setSnoozeMenuExpanded(false)
                    snooze(date)
                }
            }
        }
    }

    private var briefingSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withMotion(CompanionMotion.spring) {
                        panelState.setBriefingExpanded(false)
                    }
                } label: {
                    Label(notification.chatName, systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回通知")
                Spacer()
                closeButton
            }
            GroupContextBriefingCard(notification: notification)
        }
    }

    private var closeButton: some View {
        Button { panelState.collapseAndYield() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
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
            Label("稍后提醒", systemImage: "clock")
        }
        .buttonStyle(BannerChromeStyle(emphasized: showSnooze))
        .help("稍后提醒")
        .accessibilityHint("打开稍后提醒时间")
        .onChange(of: showSnooze) { _, isOpen in
            panelState.setSnoozeMenuExpanded(isOpen)
        }
    }

    private var headline: String {
        let when = Date().timeIntervalSince(notification.timestamp) < 60
            ? "刚刚"
            : CompanionProductCopy.clockLabel(notification.timestamp)
        if notification.kind == .groupAt {
            return "\(notification.senderName)在\(notification.chatName) @ 了你 · \(when)"
        }
        if notification.chatName == notification.senderName {
            return "\(notification.senderName) · \(when)"
        }
        return "\(notification.senderName) · \(notification.chatName) · \(when)"
    }

    private func snooze(_ date: Date) {
        let item = monitor.inboxItems.first(where: { $0.chatUsername == notification.chatUsername })
            ?? notification.actionInboxItem()
        if monitor.snoozeInboxItem(item, until: date) {
            panelState.islandSnoozeUndo = (item, date)
            panelState.showToast(CompanionProductCopy.snoozeReceipt(until: date))
        }
        panelState.islandSurface = .inbox
        panelState.goExtended()
    }
}

private struct BannerChromeStyle: ButtonStyle {
    var emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: emphasized ? .semibold : .medium))
            .foregroundColor(.white.opacity(emphasized ? 1 : 0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                emphasized
                    ? CompanionPalette.jade.opacity(configuration.isPressed ? 0.82 : 1)
                    : Color.white.opacity(configuration.isPressed ? 0.22 : 0.10)
            )
            .clipShape(Capsule())
    }
}
