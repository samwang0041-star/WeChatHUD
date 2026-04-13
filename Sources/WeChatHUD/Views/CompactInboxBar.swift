import SwiftUI

/// Compact bar — the 36px signal indicator shown when the user is busy.
/// Shows the most important piece of information at a glance.
///
/// Visual states:
///   1. Idle (sync OK, nothing actionable) — green dot + "一切正常"
///   2. Idle (sync error / WeChat not running) — warning + error text
///   3. Only P2 items — gray dot + "N条待处理"
///   4. Has P0/P1 — red/yellow dot + AI summary of top item + optional "+N" + optional "超时Nm"
struct CompactInboxBar: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        HStack(spacing: 6) {
            statusContent
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusContent: some View {
        // Only count actionRequired items — matches what extended list actually shows
        let actionItems = monitor.inboxItems.filter { $0.actionRequired }
        let p0p1Items = actionItems.filter { $0.priority != .p2 }
        let hasUrgent = !p0p1Items.isEmpty

        if hasUrgent, let top = actionItems.first {
            urgentContent(top: top, extraCount: p0p1Items.count - 1)
        } else if !actionItems.isEmpty {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text("\(actionItems.count)条待处理")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        } else if !syncIsOK {
            // State 2: Sync error
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                Text(syncErrorText)
                    .font(.system(size: 11))
                    .foregroundColor(.yellow.opacity(0.8))
            }
        } else {
            // State 1: All clear
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green.opacity(0.7))
                    .frame(width: 6, height: 6)
                Text("一切正常")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private func urgentContent(top: InboxItem, extraCount: Int) -> some View {
        HStack(spacing: 5) {
            // Priority dot
            Circle()
                .fill(top.priority == .p0 ? Color.red : Color.yellow)
                .frame(width: 7, height: 7)

            // Summary text (AI or fallback to raw preview)
            Text(top.aiSummary ?? top.preview)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

            // Overdue badge
            if top.isOverdue {
                Text("超时\(top.overdueMinutes)分")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(3)
            }

            // Extra count badge (only show when there are additional P0/P1 items)
            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private var gearButton: some View {
        Button(action: { panelState.showDetail() }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sync state helpers

    /// Normal operating states — don't disturb the user.
    private var syncIsOK: Bool {
        switch monitor.stats.syncStatus {
        case .ok, .idle, .syncing: return true
        default: return false
        }
    }

    /// Only shown when something is actually wrong.
    private var syncErrorText: String {
        switch monitor.stats.syncStatus {
        case .stale:
            return "未同步"
        case .waitingForWeChat:
            return "微信未运行"
        case .error(let msg):
            return msg.localizedCaseInsensitiveContains("WeChat") ? "微信未运行" : "未同步"
        default:
            return ""
        }
    }
}

// MARK: - Compact width helper

/// Compute the appropriate compact bar width based on inbox state.
func compactBarWidth(inboxItems: [InboxItem], syncStatus: SyncStatus) -> CGFloat {
    let hasUrgent = inboxItems.contains { $0.priority != .p2 }
    if hasUrgent { return 380 }
    if !inboxItems.isEmpty { return 240 }
    return 200
}
