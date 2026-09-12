import SwiftUI
import AppKit

/// SwiftUI → AppKit size channel. Any subtree with
/// `.background(SizeReporter())` publishes its rendered bounds up to the
/// nearest `onPreferenceChange(SizePreferenceKey.self)`.
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Keep whichever value is non-zero. If both are non-zero, prefer
        // the latest (typical case — single reporter in the tree).
        if next != .zero { value = next }
    }
}

struct HUDRootView: View {
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        // Each pill state is rendered at its own fixed intrinsic width,
        // CENTERED inside the window. The window animates symmetrically
        // from the center, so center-aligned content stays visually
        // pinned to screen-center rather than sliding with the left edge.
        //
        // Isolate island *state* swaps from SwiftUI implicit animation so
        // compact/extended/detail do not cross-fade against the mask spring.
        // Do not nil the whole transaction: that also killed in-row expand,
        // which then snapped and could report the covering stage as height.
        Group {
            switch panelState.presentedState {
            case .compact, .peek:
                // Compact/peek fill the panel frame — AppDelegate sizes
                // them geometrically (notch + wings, plus peek slots).
                CompactInboxBar()
            case .extended, .notification, .detail:
                HUDMonitorSurface()
            }
        }
        // Top-aligned so a covering window (the union of current and target
        // frames during a mask-driven spring) keeps the island hung from the
        // notch. Centering would drop compact content into the middle of the
        // cover while the mask shrinks from the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            // One black body: notch band + pill are the same color as
            // the hardware Dynamic Island, so compact wings disappear
            // into it and expand reads as that island growing down.
            ZStack(alignment: .top) {
                CompanionPalette.island
                    .frame(height: islandNotchHeight)
                    .frame(maxWidth: islandNotchWidth)
                IslandShape(
                    notchWidth: islandNotchWidth,
                    notchHeight: islandNotchHeight,
                    pillCornerRadius: 22,
                    notchCornerRadius: 10,
                    topCornerRadius: 16
                )
                .fill(CompanionPalette.island)
            }
        )
        .overlay(alignment: .top) {
            // Toast overlay — transient feedback for silent failures
            // like "在微信中打开" not working. Sits on top of whatever
            // state the panel is in so the user sees it even from
            // compact mode.
            HUDToastLayer()
        }
        .companionAnimation(CompanionMotion.ease(0.2), value: panelState.toastMessage)
        .animation(nil, value: panelState.presentedState)
        .dynamicTypeSize(PreviewRuntime.largeType ? .accessibility2 : .large)
    }

    private var islandNotchWidth: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchWidth
        }
        // Must match `CompactInboxBar`'s fallback: the two views draw the same
        // notch geometry from the same panel, and a 16 vs 200 disagreement
        // during the no-panel window (preview / early launch) would render the
        // island body at one width and its glow layer at another.
        return 200
    }

    private var islandNotchHeight: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchHeight
        }
        return 32
    }
}

private struct HUDMonitorSurface: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        surface
            .background { expandedChrome }
    }

    @ViewBuilder
    private var expandedChrome: some View {
        let show = panelState.presentedState == .extended
            || panelState.presentedState == .notification
            || panelState.presentedState == .detail
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0),
            style: .continuous
        )
        .strokeBorder(IslandChrome.hairline, lineWidth: show ? IslandChrome.hairlineWidth : 0)
        .shadow(color: show ? Color.black.opacity(0.45) : .clear, radius: 20, y: 10)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var surface: some View {
        switch panelState.presentedState {
        case .extended:
            InboxView()
                .frame(width: IslandChrome.expandedWidth, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: SizePreferenceKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    panelState.reportExtendedSize(size)
                }
        case .notification:
            if let notif = monitor.latestNotification {
                StableNotificationBanner(notification: notif)
                    .id(notif.messageID)
                    .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
                    .onPreferenceChange(SizePreferenceKey.self) { size in
                        panelState.reportNotificationSize(size)
                    }
            }
        case .detail:
            DetailPanelView()
                .padding(.top, islandNotchHeight)
        case .compact, .peek:
            EmptyView()
        }
    }

    private var islandNotchHeight: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchHeight
        }
        return 32
    }
}

private struct HUDToastLayer: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        Group {
            if let message = panelState.toastMessage {
                toastView(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(monitor.$inboxActionError) { message in
            if let message { panelState.showToast(message) }
        }
        .onReceive(monitor.$discussionArchiveNotice) { message in
            if let message {
                panelState.showToast(message, duration: 8)
                monitor.discussionArchiveNotice = nil
            }
        }

    }

    private func toastView(_ message: String) -> some View {
        let snoozeUndo = panelState.islandSnoozeUndo
        return HStack(spacing: 6) {
            Image(systemName: snoozeUndo == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(snoozeUndo == nil ? .orange : CompanionPalette.islandMint)
            Text(message)
                .islandMeta()
                .foregroundColor(IslandInk.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if snoozeUndo != nil {
                Button("撤销") {
                    if let item = panelState.islandSnoozeUndo?.item {
                        _ = monitor.restoreInboxItem(item)
                    }
                    panelState.islandSnoozeUndo = nil
                    panelState.toastMessage = nil
                }
                .buttonStyle(.plain)
                .islandSection()
                .foregroundStyle(CompanionPalette.islandMint)
                .accessibilityLabel("撤销")
            }
            Button(action: { panelState.toastMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(IslandInk.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 400)
        .padding(.top, 4)
    }
}

/// Size of the inbox panel. Width is fixed; height is a sum of the parts
/// actually rendered so the panel hugs its content instead of leaving a
/// large empty tail. Caller passes the count of action-required rows (the
/// only rows drawn in the top list) and whether the handled footer is shown.
///
/// SwiftUI reports the real rendered height through `SizePreferenceKey`, and
/// that measurement is what the panel animates to — this is the starting
/// estimate, so it only has to be close. The row height comes from
/// `IslandMetrics` so the estimate cannot drift away from the rows again.
func inboxSize(actionCount: Int, hasHandled: Bool) -> (CGFloat, CGFloat) {
    let width = IslandChrome.expandedWidth

    // Empty inbox — brand block + empty copy + workspace bar.
    if actionCount == 0 && !hasHandled {
        return (width, 236)
    }

    let rows = min(max(actionCount, 1), 10)
    // Notch band + section row.
    let headerHeight: CGFloat = 44
    let dividerHeight: CGFloat = 1
    let rowHeight = IslandMetrics.rowHeight
    let handledHeaderHeight: CGFloat = hasHandled ? 30 : 0
    let bottomBarHeight: CGFloat = 46

    let bodyHeight = CGFloat(rows) * rowHeight
    let total = headerHeight + dividerHeight + bodyHeight + handledHeaderHeight + bottomBarHeight
    return (width, min(total, 720))
}

/// Freeze the recipient and evidence while the user is interacting with a banner.
/// New arrivals remain in the inbox and appear after this presentation is dismissed.
private struct StableNotificationBanner: View {
    @State private var notification: HUDNotification
    init(notification: HUDNotification) { _notification = State(initialValue: notification) }
    var body: some View { NotificationBannerView(notification: notification) }
}
