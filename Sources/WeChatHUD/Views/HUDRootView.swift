import SwiftUI

struct HUDRootView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(spacing: 0) {
            CompactBarView(stats: monitor.stats)

            if panelState.currentState == .notification {
                if let notif = monitor.latestNotification {
                    NotificationBannerView(notification: notif)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            if panelState.currentState == .detail {
                DetailPanelView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: panelState.currentState)
        .frame(maxWidth: .infinity)
    }
}
