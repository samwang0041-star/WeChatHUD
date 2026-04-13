import SwiftUI

/// Unified inbox — replaces ExtendedTabsView. Shows all messages in a
/// single priority-sorted list with an action section on top and an
/// info-only section below.
struct InboxView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panelState.showSmartDigest {
                smartDigestBanner
            }
            header
            Divider().background(Color.white.opacity(0.08))
            if monitor.inboxItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let actionItems = monitor.inboxItems.filter { $0.actionRequired }
                        let infoItems = monitor.inboxItems.filter { !$0.actionRequired }

                        ForEach(actionItems) { item in
                            InboxRowView(item: item) {
                                monitor.dismissInboxItem(item)
                            }
                        }

                        if !infoItems.isEmpty {
                            infoSectionHeader
                            ForEach(infoItems) { item in
                                InboxRowView(item: item) {
                                    monitor.dismissInboxItem(item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            let actionCount = monitor.inboxItems.filter { $0.actionRequired }.count
            Text("收件箱")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("\(actionCount)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(actionCount > 0 ? Color.red.opacity(0.3) : Color.white.opacity(0.08))
                .foregroundColor(actionCount > 0 ? .red : .white.opacity(0.5))
                .cornerRadius(3)
            Spacer()
            if let syncAt = monitor.stats.lastSyncAt {
                Text(syncLabel(syncAt))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            Button(action: { panelState.showDetail() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var infoSectionHeader: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            Text("仅通知")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.25))
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("没有待处理消息")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
            if let syncAt = monitor.stats.lastSyncAt {
                Text("上次同步: \(syncLabel(syncAt))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var smartDigestBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text("你离开了一段时间")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Button("知道了") {
                panelState.showSmartDigest = false
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private func syncLabel(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚同步" }
        return "\(seconds / 60)分钟前同步"
    }
}
