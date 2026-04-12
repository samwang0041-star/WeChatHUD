import SwiftUI

/// Detail panel — shows either a conversation analysis workbench
/// (when a chat is selected) or the settings view (gear button).
struct DetailPanelView: View {
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
}
