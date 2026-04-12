import SwiftUI
import AppKit

/// Expanded panel shown below a `ReplyDebtRow` when the user clicks it.
/// Loads 3 AI-generated reply candidates (友好 / 正式 / 简洁) and lets the
/// user copy one to the clipboard, then optionally open WeChat and paste.
struct ReplyDebtExpandedView: View {
    @EnvironmentObject var monitor: ChatMonitor

    let item: ReplyDebtItem

    @State private var suggestions: [AIReplySuggester.Suggestion] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.08))

            if isLoading {
                loadingView
            } else if suggestions.isEmpty && hasLoaded {
                emptyView
            } else {
                suggestionsView
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            Task {
                isLoading = true
                let results = await monitor.loadReplySuggestions(for: item)
                suggestions = results
                isLoading = false
                hasLoaded = true
            }
        }
    }

    // MARK: - Loading spinner

    private var loadingView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text("正在生成回复建议…")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Empty / error state

    private var emptyView: some View {
        Text("暂无回复建议（AI 服务未配置或调用失败）")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: - Suggestions list

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("智能回复建议")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                suggestionRow(suggestion, index: index)
            }
        }
        .padding(.bottom, 6)
    }

    private func suggestionRow(_ suggestion: AIReplySuggester.Suggestion, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            toneBadge(suggestion.tone)
                .padding(.top, 2)

            Text(suggestion.text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hoveredIndex == index ? Color.white.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hoveredIndex = $0 ? index : nil }
        .onTapGesture {
            copySuggestionAndAsk(suggestion)
        }
    }

    // MARK: - Tone badge

    private func toneBadge(_ tone: String) -> some View {
        let color = toneColor(tone)
        return Text(tone)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private func toneColor(_ tone: String) -> Color {
        switch tone {
        case "友好": return .green
        case "正式": return .blue
        case "简洁": return Color(red: 0.9, green: 0.6, blue: 0.1)
        default:    return .white
        }
    }

    // MARK: - Copy + paste flow

    private func copySuggestionAndAsk(_ suggestion: AIReplySuggester.Suggestion) {
        // Write text to NSPasteboard.
        WeChatLauncher.copyText(suggestion.text)

        // Ask user if they want to open WeChat and paste.
        let alert = NSAlert()
        alert.messageText = "已复制到剪贴板"
        alert.informativeText = "是否打开微信对话框并粘贴？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开并粘贴")
        alert.addButton(withTitle: "只复制")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Open the chat, then paste after a short settle delay.
        WeChatLauncher.openChat(named: item.chatName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            WeChatLauncher.pasteClipboard()
        }
    }
}
