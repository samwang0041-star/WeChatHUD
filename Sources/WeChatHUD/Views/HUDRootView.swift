import SwiftUI

struct HUDRootView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

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
                let cw = compactBarWidth(
                    inboxItems: monitor.inboxItems,
                    syncStatus: monitor.stats.syncStatus
                )
                CompactInboxBar()
                    .frame(width: cw, height: 36)
            case .extended:
                let itemCount = monitor.inboxItems.count
                let (w, h) = inboxSize(itemCount: itemCount)
                InboxView()
                    .frame(width: w, height: h)
            case .notification:
                if let notif = monitor.latestNotification {
                    NotificationBannerView(notification: notif)
                }
            case .detail:
                DetailPanelView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
    }
}

/// Size of the inbox panel for given item count.
func inboxSize(itemCount: Int) -> (CGFloat, CGFloat) {
    if itemCount == 0 {
        return (400, 120)  // empty state + menu bar clearance + handled section
    }
    let rows = min(CGFloat(itemCount), 10)
    let bodyHeight = max(60, rows * 48)  // 48px per row (slightly taller for new design)
    let handledHeight: CGFloat = 30  // collapsed handled section
    let height: CGFloat = min(38 + 1 + bodyHeight + handledHeight + 6, 500)
    return (480, height)
}
