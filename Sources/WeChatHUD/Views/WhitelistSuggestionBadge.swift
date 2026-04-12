import SwiftUI

struct WhitelistSuggestionBadge: View {
    @EnvironmentObject var monitor: ChatMonitor
    let chatUsername: String
    let suggestion: AIWhitelistCategorizer.Suggestion
    @State private var showConfirm = false

    var body: some View {
        Button { showConfirm = true } label: {
            Text("建议关注")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showConfirm) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AI 建议将此联系人加入白名单")
                    .font(.system(size: 12, weight: .semibold))
                Text("分类：\(suggestion.category == "work" ? "工作" : suggestion.category == "life" ? "生活" : "其他")")
                    .font(.system(size: 11))
                Text("理由：\(suggestion.reason)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("置信度：\(Int(suggestion.confidence * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                HStack {
                    Button("加入白名单") {
                        monitor.acceptWhitelistSuggestion(chatUsername: chatUsername, suggestion: suggestion)
                        showConfirm = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("忽略") {
                        monitor.dismissWhitelistSuggestion(chatUsername: chatUsername)
                        showConfirm = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}
