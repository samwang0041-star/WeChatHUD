import SwiftUI

struct DetailPanelView: View {
    @State private var showSettings = false

    var body: some View {
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
}
