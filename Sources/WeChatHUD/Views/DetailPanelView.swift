import SwiftUI

/// Detail panel — routes on `panelState.detailKind`:
/// - `.conversation`: the analysis workbench for a specific chat.
/// - `.autopilot`: the full autopilot control surface (same content the
///   old tab used to render, now living behind the compact-bar indicator).
/// - `nil`: the standalone Settings window (the gear fallback).
struct DetailPanelView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Inline notification bar for new urgent messages while in detail
                if panelState.currentState == .detail,
                   let top = monitor.inboxItems.first,
                   top.priority != .p2 {
                    detailNotificationBar(top)
                }

                // Main content
                switch panelState.detailKind {
                case .conversation(let chatUsername):
                    if let chatName = panelState.selectedChatName {
                        ConversationDetailView(
                            chatUsername: chatUsername,
                            chatName: chatName
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Chat name missing — fall back to empty pane
                        // instead of an opaque crash. Shouldn't happen
                        // in practice (callers always set both).
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .autopilot:
                    AutopilotDetailPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .none:
                    SettingsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Explicit close — back to compact pill.
            Button(action: {
                panelState.clearDetail()
                panelState.collapse()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    private func detailNotificationBar(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(item.priority == .p0 ? Color.red : Color.yellow)
                .frame(width: 7, height: 7)
            Text(item.aiSummary ?? item.preview)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            if item.isOverdue {
                Text("超时\(item.overdueMinutes)分")
                    .font(.system(size: 9))
                    .foregroundColor(.red)
            }
            Spacer()
            Button("[查看]") {
                // Switch to .extended directly — the old "collapse
                // then mouseEntered 0.3s later" dance produced a
                // visible shrink-then-grow flicker.
                panelState.goExtended()
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }
}

/// Host for the autopilot full-view inside the detail panel. Commit 3
/// fleshes this out with the header + embedded `AutopilotTabView`; the
/// initial routing commit just needs a placeholder that compiles.
struct AutopilotDetailPane: View {
    var body: some View {
        Color.clear
    }
}
