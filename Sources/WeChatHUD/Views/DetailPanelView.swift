import SwiftUI

/// Detail panel — shows either a conversation analysis workbench
/// (when a chat is selected) or the settings view (gear button).
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
                if let chatUsername = panelState.selectedChatUsername,
                   let chatName = panelState.selectedChatName {
                    ConversationDetailView(
                        chatUsername: chatUsername,
                        chatName: chatName
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SettingsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Explicit close — back to compact pill.
            Button(action: { panelState.collapse() }) {
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
