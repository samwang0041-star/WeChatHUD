import SwiftUI

/// Expanded briefing panel shown when user clicks an inbox row.
/// Structure: 📋 情况 → 💡 建议 → 回复建议 → [在微信中打开]
struct BriefingPanelView: View {
    @EnvironmentObject var monitor: ChatMonitor
    let item: InboxItem

    @State private var briefing: InboxBriefing? = nil
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var copiedSuggestion: SuggestedReply? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    // Show instant context while AI loads
                    contextSection
                    loadingSection
                } else if let b = briefing {
                    briefingSection(b)
                } else {
                    // AI unavailable — show context + error
                    contextSection
                    errorSection
                }

                // Always-available exit
                openWeChatButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            briefing = await monitor.loadBriefing(for: item)
            isLoading = false
        }
    }

    // MARK: - Context (instant, from algorithm data)

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // "你上次: xxx · N小时前" — from the ReplyDebtItem's latestOutboundPreview
            if let lastReply = item.toReplyDebtItem().latestOutboundPreview {
                HStack(spacing: 4) {
                    Text("你上次:")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                    Text("\"\(lastReply)\"")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            // VIP insight one-liner (if available)
            if item.isVIP, item.suggestedReplyMinutes > 0 {
                Text("\u{1F4A1} 建议\(item.suggestedReplyMinutes)分钟内回复")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
            }
        }
    }

    // MARK: - Loading

    private var loadingSection: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            Text("管家正在分析…")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Error

    private var errorSection: some View {
        Text("管家分析暂时不可用")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.35))
            .padding(.vertical, 4)
    }

    // MARK: - Full briefing

    private func briefingSection(_ b: InboxBriefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 📋 情况
            VStack(alignment: .leading, spacing: 3) {
                Text("📋 情况")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                Text(b.situation)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 💡 建议
            VStack(alignment: .leading, spacing: 3) {
                Text("💡 建议")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                Text(b.suggestion)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Reply suggestions
            if !b.replies.isEmpty {
                repliesSection(b.replies)
            }
        }
    }

    // MARK: - Reply suggestions

    private func repliesSection(_ replies: [SuggestedReply]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("回复建议")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .padding(.bottom, 2)

            ForEach(replies) { suggestion in
                suggestionRow(suggestion)

                if copiedSuggestion?.text == suggestion.text {
                    copiedBar
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: SuggestedReply) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if suggestion.recommended {
                Text("\u{2705}")
                    .font(.system(size: 10))
            } else {
                // Reserve space so text aligns
                Text("   ")
                    .font(.system(size: 10))
            }
            toneBadge(suggestion.tone)
            Text(suggestion.text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("[选择]") {
                copySuggestion(suggestion)
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(suggestion.recommended ? Color.white.opacity(0.04) : Color.clear)
        .cornerRadius(4)
    }

    private var copiedBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)
            Text("已复制")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Button("在微信中打开并粘贴") {
                guard let suggestion = copiedSuggestion else { return }
                copiedSuggestion = nil
                WeChatLauncher.openChatAndPaste(named: item.chatName, text: suggestion.text)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.06))
        .cornerRadius(4)
    }

    // MARK: - Open WeChat (always available)

    private var openWeChatButton: some View {
        HStack {
            Spacer()
            Button(action: {
                WeChatLauncher.openChat(named: item.chatName)
            }) {
                Text("在微信中打开")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func toneBadge(_ tone: String) -> some View {
        let color: Color = {
            switch tone {
            case "友好": return .green
            case "正式": return .blue
            case "简洁": return Color(red: 0.9, green: 0.6, blue: 0.1)
            default: return .gray
            }
        }()
        return Text(tone)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func copySuggestion(_ suggestion: SuggestedReply) {
        WeChatLauncher.copyText(suggestion.text)
        copiedSuggestion = suggestion
    }
}
