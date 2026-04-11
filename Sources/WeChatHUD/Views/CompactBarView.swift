import SwiftUI

struct CompactBarView: View {
    let stats: HUDStats

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            // Icon + number only — no labels, no gear.
            statLabel("\(stats.unreadCount)", icon: "envelope.fill")
            statLabel("\(stats.atMentionCount)", icon: "at")
            statLabel("\(stats.importantCount)", icon: "exclamationmark.circle.fill")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func statLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
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
}
