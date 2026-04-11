import SwiftUI

struct DetailPanelView: View {
    @EnvironmentObject var panelState: PanelState
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if showSettings {
                    SettingsView(showSettings: $showSettings)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        ChatListView(showSettings: $showSettings)
                            .frame(width: 200)

                        Divider()
                            .background(Color.white.opacity(0.1))

                        // Right panel — placeholder for AI analysis cards
                        VStack {
                            Text("选择一个对话查看分析")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            // Explicit close — back to compact pill.
            Button(action: { panelState.collapse() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}
