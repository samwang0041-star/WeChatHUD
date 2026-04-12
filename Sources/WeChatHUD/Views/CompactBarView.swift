import SwiftUI

/// Tiny resting-state pill. Shows the unread counter defined by spec:
///
///     未读 = (# private chats with WeChat unread_count > 0)
///          + (# @-me messages in groups not yet read in WeChat)
///
/// Cleared only when the user reads the chat **inside WeChat**. Merely
/// hovering or opening our HUD does not decrement.
///
/// The leading slot shows a native spinner ONLY while a scan is in
/// flight ("抓取数据中"). When idle nothing renders there, so the old
/// "status dot" that randomly flipped green/yellow/red is gone. The
/// slot is a fixed 10pt square so the rest of the pill doesn't
/// jump when the spinner appears or disappears.
struct CompactBarView: View {
    let stats: HUDStats
    /// Number of unread items in `.overdue` state. When > 0 the counter
    /// pulses red so the user can see at a glance that something has
    /// been sitting unreplied past the threshold.
    var overdueCount: Int = 0
    var replyDebtHasP0: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            scanIndicator
                .frame(width: 10, height: 10)

            Image(systemName: "envelope.fill")
                .font(.system(size: 11))
                .foregroundColor(overdueCount > 0 ? .red : .white.opacity(0.85))

            Text("\(stats.unreadCount)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(overdueCount > 0 ? .red : .white)
                .monospacedDigit()

            if stats.atMentionCount > 0 {
                // @ sub-badge so the user can see how many of the unread
                // items are explicit @-mentions vs. plain private msgs.
                HStack(spacing: 2) {
                    Image(systemName: "at")
                        .font(.system(size: 10, weight: .bold))
                    Text("\(stats.atMentionCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundColor(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.18))
                .cornerRadius(3)
            }

            if stats.replyDebtCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(stats.replyDebtCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundColor(replyDebtHasP0 ? .orange : .white.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    (replyDebtHasP0 ? Color.orange : Color.white)
                        .opacity(replyDebtHasP0 ? 0.2 : 0.08)
                )
                .cornerRadius(3)
            }

            if stats.vipCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(stats.vipCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundColor(.yellow)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.yellow.opacity(0.16))
                .cornerRadius(3)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    @ViewBuilder
    private var scanIndicator: some View {
        switch stats.syncStatus {
        case .syncing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .scaleEffect(0.7)
        default:
            Color.clear
        }
    }
}
