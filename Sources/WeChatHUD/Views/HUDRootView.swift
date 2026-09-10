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
        // `.transaction { $0.animation = nil }` disables all SwiftUI
        // implicit transitions on state changes. Without this, SwiftUI
        // cross-fades / scales the content view in parallel with the
        // AppKit window-frame animation; because the two use different
        // curves and durations they visibly desync, producing a "content
        // slides left after the window has settled" artifact.
        Group {
            switch panelState.currentState {
            case .compact:
                // Compact fills the entire panel frame — AppDelegate's
                // `panelSize(for: .compact)` sizes the panel to
                // (notchWidth + wings) × notchHeight, so we don't
                // hardcode dimensions here. Letting it flex keeps the
                // bar honest when the display (and therefore the
                // notch geometry) changes under us.
                CompactInboxBar()
            case .extended, .notification, .detail:
                HUDMonitorSurface()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    notchCornerRadius: 10
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
        .transaction { $0.animation = nil }
        .dynamicTypeSize(PreviewRuntime.largeType ? .accessibility2 : .large)
    }

    private var islandNotchWidth: CGFloat {
        if let app = NSApp.delegate as? AppDelegate, let panel = app.panel {
            return panel.notch.notchWidth
        }
        return 16
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
        switch panelState.currentState {
        case .extended:
            InboxView()
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: IslandChrome.expandedWidth)
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
                    .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
            }
        case .detail:
            DetailPanelView()
                .padding(.top, islandNotchHeight)
        case .compact:
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
    }

    private func toastView(_ message: String) -> some View {
        let snoozeUndo = panelState.islandSnoozeUndo
        return HStack(spacing: 6) {
            Image(systemName: snoozeUndo == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(snoozeUndo == nil ? .orange : CompanionPalette.islandMint)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CompanionPalette.islandMint)
                .accessibilityLabel("撤销")
            }
            Button(action: { panelState.toastMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 400)
        .padding(.top, 4)
    }
}

/// Size of the inbox panel. Width is fixed-compact; height is a sum of the
/// parts actually rendered so the panel hugs its content instead of leaving
/// a large empty tail. Caller passes the count of action-required rows (the
/// only rows drawn in the top list) and whether the handled footer is shown.
func inboxSize(actionCount: Int, hasHandled: Bool) -> (CGFloat, CGFloat) {
    let width = IslandChrome.expandedWidth

    // Empty inbox — brand + status + empty copy + workspace bar.
    if actionCount == 0 && !hasHandled {
        return (width, 220)
    }

    let rows = min(max(actionCount, 1), 10)
    let headerHeight: CGFloat = 52
    let dividerHeight: CGFloat = 1
    let rowHeight: CGFloat = 88
    let handledHeaderHeight: CGFloat = hasHandled ? 32 : 0
    let bottomPadding: CGFloat = 12

    let bodyHeight = CGFloat(rows) * rowHeight
    let total = headerHeight + dividerHeight + bodyHeight + handledHeaderHeight + bottomPadding
    return (width, min(total, 720))
}

/// Freeze the recipient and evidence while the user is interacting with a banner.
/// New arrivals remain in the inbox and appear after this presentation is dismissed.
private struct StableNotificationBanner: View {
    @State private var notification: HUDNotification
    init(notification: HUDNotification) { _notification = State(initialValue: notification) }
    var body: some View { NotificationBannerView(notification: notification) }
}
