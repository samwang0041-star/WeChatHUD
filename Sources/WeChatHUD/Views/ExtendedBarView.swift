import SwiftUI

/// Hover-expanded pill. Same 36-height, but wider — shows full labels,
/// a readable sync status, and a settings gear (click → detail view).
struct ExtendedBarView: View {
    @EnvironmentObject var panelState: PanelState
    let stats: HUDStats

    var body: some View {
        HStack(spacing: 14) {
            // Status dot
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            // Full-label stats
            statLabel("\(stats.unreadCount) 未读", icon: "envelope.fill")
            statLabel("\(stats.atMentionCount) @你", icon: "at")
            statLabel("\(stats.replyDebtCount) 待回", icon: "arrowshape.turn.up.left.fill")
            statLabel("\(stats.vipCount) VIP", icon: "star.fill")

            Spacer(minLength: 4)

            // Sync status (read-only)
            Text(syncText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
                .monospacedDigit()

            // Settings gear → full detail view.
            Button(action: { panelState.showDetail() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func statLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .foregroundColor(.white)
    }

    private var dotColor: Color {
        switch stats.syncStatus {
        case .ok: return .green
        case .stale, .idle, .syncing: return .yellow
        case .waitingForWeChat, .error: return .red
        }
    }

    private var syncText: String {
        if case .waitingForWeChat = stats.syncStatus { return "微信未启动" }
        guard let last = stats.lastSyncAt else { return "未同步" }
        let diff = Int(Date().timeIntervalSince(last))
        if diff < 60 { return "刚刚同步" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        return "\(diff / 3600)小时前"
    }
}
