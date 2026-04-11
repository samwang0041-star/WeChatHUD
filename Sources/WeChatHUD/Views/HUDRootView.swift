import SwiftUI

struct HUDRootView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        ZStack {
            // Base layer: compact or extended pill (same height, different width).
            switch panelState.currentState {
            case .compact:
                CompactBarView(stats: monitor.stats)
                    .transition(.opacity)
            case .extended:
                ExtendedBarView(stats: monitor.stats)
                    .transition(.opacity)
            case .notification:
                VStack(spacing: 0) {
                    CompactBarView(stats: monitor.stats)
                    if let notif = monitor.latestNotification {
                        NotificationBannerView(notification: notif)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            case .detail:
                DetailPanelView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: panelState.currentState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
