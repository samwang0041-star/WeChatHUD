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
    /// Tracks which suggestion was just copied. Non-nil shows the inline
    /// confirmation bar so the user can open WeChat and paste — no modal alert.
    @State private var copiedSuggestion: AIReplySuggester.Suggestion? = nil

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
                if copiedSuggestion?.text == suggestion.text {
                    copiedConfirmationBar(for: suggestion)
                }
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
            copySuggestion(suggestion)
        }
    }

    /// Inline confirmation bar shown below the copied suggestion.
    /// Replaces the old NSAlert — works safely in a .nonactivatingPanel.
    private func copiedConfirmationBar(for suggestion: AIReplySuggester.Suggestion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.green)
            Text("已复制")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.75))
            Spacer(minLength: 0)
            Button("打开微信并粘贴") {
                copiedSuggestion = nil
                WeChatLauncher.openChatAndPaste(named: item.chatName, text: suggestion.text)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            Button("关闭") {
                copiedSuggestion = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.green.opacity(0.08))
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

    // MARK: - Copy flow

    private func copySuggestion(_ suggestion: AIReplySuggester.Suggestion) {
        WeChatLauncher.copyText(suggestion.text)
        copiedSuggestion = suggestion
    }
}
