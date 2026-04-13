import SwiftUI

/// Unified inbox — shows all messages in a single priority-sorted list
/// with action items on top, an undo bar, and a collapsible handled section.
struct InboxView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    @State private var undoItem: InboxItem? = nil
    @State private var undoAction: String = ""  // "已忽略" or "已贪睡" or "已静音"
    @State private var undoTimer: Timer? = nil
    @State private var showHandled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panelState.showSmartDigest {
                smartDigestBanner
            }
            header

            let actionItems = monitor.inboxItems.filter { $0.actionRequired }

            if actionItems.isEmpty && monitor.handledItems.isEmpty {
                emptyState
            } else {
                Divider().background(Color.white.opacity(0.08))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(actionItems) { item in
                            InboxRowView(item: item, onDismiss: {
                                undoAction = "已忽略"
                                undoItem = item
                                monitor.dismissInboxItem(item)
                                scheduleUndoExpiry()
                            }, onSnooze: { date in
                                undoAction = "已贪睡"
                                undoItem = item
                                monitor.snoozeInboxItem(item, until: date)
                                scheduleUndoExpiry()
                            }, onSilence: {
                                undoAction = "已静音"
                                undoItem = item
                                monitor.silenceInboxItem(item)
                                scheduleUndoExpiry()
                            })
                        }

                        // Undo bar
                        if let undo = undoItem {
                            undoBar(item: undo, action: undoAction)
                        }

                        // Handled section (collapsed by default)
                        if !monitor.handledItems.isEmpty {
                            handledSection
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            PixelBuddyView(mood: extendedBuddyMood)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Header

    private var extendedBuddyMood: BuddyMood {
        let actionCount = monitor.inboxItems.filter { $0.actionRequired }.count
        let isProcessing = { if case .syncing = monitor.stats.syncStatus { return true }; return false }()
        return deriveExtendedMood(actionItemCount: actionCount, isAIProcessing: isProcessing)
    }

    private var header: some View {
        let actionCount = monitor.inboxItems.filter { $0.actionRequired }.count
        return HStack(spacing: 6) {
            Spacer()
            if let syncAt = monitor.stats.lastSyncAt {
                Text(syncLabel(syncAt))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.25))
            }
            if actionCount > 0 {
                Text("\(actionCount)")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red)
                    .cornerRadius(3)
            }
            Button(action: { panelState.showDetail() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 26)
        .padding(.bottom, 4)
    }

    // MARK: - Undo Bar

    private func undoBar(item: InboxItem, action: String) -> some View {
        HStack(spacing: 8) {
            Text("\(item.chatName) \(action)")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
            Spacer()
            Button("撤销") {
                monitor.restoreInboxItem(item)
                undoItem = nil
                undoTimer?.invalidate()
                undoTimer = nil
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Handled Section

    private var handledSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header (tap to expand/collapse)
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showHandled.toggle() } }) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                    Text("已处理 (\(monitor.handledItems.count))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                    Image(systemName: showHandled ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.25))
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHandled {
                ForEach(monitor.handledItems) { item in
                    handledRow(item)
                }
            }
        }
    }

    private func handledRow(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.chatName)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                if let summary = item.aiSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }
            Spacer()
            statusLabel(item)
            Button(action: { monitor.restoreInboxItem(item) }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func statusLabel(_ item: InboxItem) -> some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case .dismissed: return ("已忽略", .white.opacity(0.25))
            case .snoozed: return ("已贪睡", .orange.opacity(0.5))
            case .silenced: return ("已静音", .red.opacity(0.4))
            case .active: return ("", .clear)
            }
        }()
        return Text(text)
            .font(.system(size: 9))
            .foregroundColor(color)
    }

    // MARK: - Empty State

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

    // MARK: - Smart Digest Banner

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

    // MARK: - Helpers

    private func syncLabel(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚同步" }
        return "\(seconds / 60)分钟前同步"
    }

    private func scheduleUndoExpiry() {
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in
                undoItem = nil
                undoTimer = nil
            }
        }
    }
}
