import SwiftUI

struct CompactBarView: View {
    let stats: HUDStats

    var body: some View {
        HStack(spacing: 16) {
            // Status dot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            // Stats
            HStack(spacing: 12) {
                statLabel("\(stats.unreadCount)条未读", icon: "envelope.fill")
                statLabel("\(stats.atMentionCount)条@", icon: "at")
                statLabel("\(stats.importantCount)条重要", icon: "exclamationmark.circle.fill")
            }

            Spacer()

            // Sync status
            Text(syncText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Settings gear
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func statLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white)
    }

    private var dotColor: Color {
        switch stats.syncStatus {
        case .ok: return .green
        case .stale, .idle, .syncing: return .yellow
        case .error: return .red
        }
    }

    private var syncText: String {
        guard let last = stats.lastSyncAt else { return "未同步" }
        let diff = Int(Date().timeIntervalSince(last))
        if diff < 60 { return "同步: 刚刚" }
        if diff < 3600 { return "同步: \(diff / 60)分钟前" }
        return "同步: \(diff / 3600)小时前"
    }
}
