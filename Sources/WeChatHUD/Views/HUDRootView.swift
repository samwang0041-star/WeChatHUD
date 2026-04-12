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
                CompactBarView(
                    stats: monitor.stats,
                    overdueCount: monitor.unreadItems.filter { $0.status == .overdue }.count,
                    replyDebtHasP0: monitor.replyDebtItems.first?.priority == .p0
                )
                .frame(width: PanelState.width(for: .compact), height: 36)
            case .extended:
                // Expanded pill — tabs for VIP and 未读. Fall back to the
                // bare stats bar only when we truly have nothing to show,
                // including suppressed items (so 已处理 stays reachable).
                if monitor.recentNotifications.isEmpty
                    && monitor.unreadItems.isEmpty
                    && monitor.suppressedItems.isEmpty
                    && monitor.replyDebtItems.isEmpty {
                    ExtendedBarView(stats: monitor.stats)
                        .frame(width: 340, height: 36)
                } else {
                    let (w, h) = extendedTabsSize(
                        vip: monitor.recentNotifications.count,
                        unread: max(monitor.unreadItems.count, monitor.suppressedItems.count),
                        replyDebt: monitor.replyDebtItems.count
                    )
                    ExtendedTabsView(
                        vipNotifications: monitor.recentNotifications,
                        unreadItems: monitor.unreadItems,
                        suppressedItems: monitor.suppressedItems,
                        replyDebtItems: monitor.replyDebtItems
                    )
                    .frame(width: w, height: h)
                }
            case .notification:
                VStack(spacing: 0) {
                    CompactBarView(
                        stats: monitor.stats,
                        replyDebtHasP0: monitor.replyDebtItems.first?.priority == .p0
                    )
                        .frame(width: 420, height: 36)
                    if let notif = monitor.latestNotification {
                        NotificationBannerView(notification: notif)
                    }
                }
            case .detail:
                DetailPanelView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
    }
}

/// Size of the tab pane for given VIP / unread counts. Must match the
/// logic in `AppDelegate.panelSize` so the SwiftUI content and the
/// NSPanel frame agree.
func extendedTabsSize(vip: Int, unread: Int, replyDebt: Int) -> (CGFloat, CGFloat) {
    // Body height follows the tallest tab. VIP rows are slightly taller
    // now to fit the `什么情况` action on群聊@消息; unread rows remain 30pt,
    // while 待回 rows are taller to fit reason chips.
    let vipRows = min(CGFloat(max(vip, 0)), 10)
    let unreadRows = min(CGFloat(max(unread, 0)), 10)
    let replyDebtRows = min(CGFloat(max(replyDebt, 0)), 8)

    let vipSectionHeaderBudget: CGFloat = vip > 0 ? 40 : 0
    let vipBodyHeight = max(50, vipRows * 34 + vipSectionHeaderBudget)
    let unreadBodyHeight = max(50, unreadRows * 30)
    let replyDebtBodyHeight = max(70, replyDebtRows * 42)
    let bodyHeight = max(vipBodyHeight, unreadBodyHeight, replyDebtBodyHeight)
    let height: CGFloat = 38 + 1 + bodyHeight + 6
    let width: CGFloat = replyDebt > 0 ? 520 : 480
    return (width, height)
}
