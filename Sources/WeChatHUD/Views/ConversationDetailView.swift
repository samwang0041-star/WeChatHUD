import SwiftUI

/// Detail view for a selected conversation — messages, AI analysis,
/// pending asks, and reply suggestions. The "workbench" for a single chat.
struct ConversationDetailView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    let chatUsername: String
    let chatName: String

    @State private var suggestions: [AIReplySuggester.Suggestion] = []
    @State private var isLoadingSuggestions = false
    @State private var replyText = ""
    @State private var isSending = false
    @State private var sendResult: String?
    @State private var showSendConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    memoryCard
                    divider
                    messagesSection
                    divider
                    pendingAsksSection
                    divider
                    replySuggestionsSection
                }
                .padding(.bottom, 8)
            }

            Divider().background(Color.white.opacity(0.12))
            replyComposer
        }
        .alert("确认发送", isPresented: $showSendConfirm) {
            Button("发送") { Task { await sendReply() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将通过微信发送给 \(chatName):\n\n\(replyText)")
        }
    }

    // MARK: - Reply Composer

    private var replyComposer: some View {
        HStack(spacing: 8) {
            TextField("输入回复...", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
                .onSubmit {
                    guard !replyText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    showSendConfirm = true
                }

            if isSending {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 28, height: 28)
            } else {
                // Save as draft
                Button(action: {
                    guard !replyText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    try? monitor.saveDraft(chatUsername: chatUsername, chatName: chatName, text: replyText)
                    sendResult = "已存为草稿"
                    replyText = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sendResult = nil }
                }) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 11))
                        .foregroundColor(replyText.isEmpty ? .white.opacity(0.15) : .white.opacity(0.5))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(replyText.isEmpty)
                .help("稍后发送")

                // Send now
                Button(action: {
                    guard !replyText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    showSendConfirm = true
                }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12))
                        .foregroundColor(replyText.isEmpty ? .white.opacity(0.2) : .accentColor)
                        .frame(width: 28, height: 28)
                        .background(replyText.isEmpty ? Color.clear : Color.accentColor.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            if let result = sendResult {
                Text(result)
                    .font(.system(size: 10))
                    .foregroundColor(result.contains("成功") ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .offset(y: -20)
            }
        }
    }

    private func sendReply() async {
        let text = replyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        let sendKey = (await monitor.loadAutopilotConfig()).sendKey
        let success = await WeChatLauncher.sendMessage(chatName: chatName, text: text, sendKey: sendKey)
        if success {
            sendResult = "发送成功"
            replyText = ""
            // Record as positive AI feedback if the reply came from a suggestion
            if suggestions.contains(where: { $0.text == text }) {
                try? monitor.recordReplyFeedback(adopted: true, chatUsername: chatUsername)
            }
            // If autopilot is active, this manual send belongs in the
            // session ledger so the next AI reply doesn't contradict
            // what the user just said.
            if monitor.autopilotActive {
                let peerLast = monitor.lastPeerMessage(chatUsername: chatUsername)
                monitor.appendLedgerEntry(
                    LedgerEntry(
                        timestamp: Date(),
                        outgoingText: text,
                        peerLastMessage: peerLast,
                        topic: nil
                    ),
                    for: chatUsername
                )
            }
        } else {
            sendResult = "发送失败"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sendResult = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: {
                panelState.clearDetail()
                panelState.currentState = .extended
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            let isGroup = chatUsername.contains("@chatroom")
            Image(systemName: isGroup ? "person.3.fill" : "person.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))

            Text(chatName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            Button(action: { WeChatLauncher.openChat(named: chatName) }) {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 9))
                    Text("微信中打开")
                        .font(.system(size: 10))
                }
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Conversation Memory Card

    @ViewBuilder
    private var memoryCard: some View {
        if let memory = monitor.loadConversationMemory(chatUsername: chatUsername),
           !memory.summary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("🧠 上下文记忆")
                Text(memory.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if !memory.keyTopics.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(memory.keyTopics.prefix(5), id: \.self) { topic in
                            Text(topic)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(3)
                        }
                    }
                }

                if !memory.sharedContext.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(memory.sharedContext.prefix(3), id: \.self) { ctx in
                            Text(ctx)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                }

                if !memory.moodTrend.isEmpty {
                    HStack(spacing: 4) {
                        Text("情绪:")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                        Text(memory.moodTrend)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Messages

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("最近消息")
            let messages = monitor.recentMessages(chatUsername: chatUsername, limit: 15)
            if messages.isEmpty {
                Text("暂无消息记录")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, msg in
                    HStack(alignment: .top, spacing: 6) {
                        Text(msg.sender)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 60, alignment: .trailing)
                            .lineLimit(1)
                        Text(msg.body)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Pending asks

    private var pendingAsksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            let asks = monitor.pendingAsksForChat(chatUsername)
            sectionLabel("待处理事项", count: asks.count)
            if asks.isEmpty {
                Text("暂无待处理事项")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 4)
            } else {
                ForEach(asks, id: \.msgUID) { ask in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ask.bucket == .main ? Color.orange : Color.white.opacity(0.3))
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ask.summary)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.82))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(ask.senderName)
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.4))
                                Text(ask.askType.rawValue)
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Reply suggestions

    private var replySuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("AI 回复建议")
                Spacer()
                if !isLoadingSuggestions && suggestions.isEmpty {
                    Button(action: { Task { await loadSuggestions() } }) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                            Text("生成建议")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.accentColor.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 14)

            if isLoadingSuggestions {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("正在生成...")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.vertical, 6)
            } else if suggestions.isEmpty {
                Text("点击「生成建议」获取 AI 回复建议")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func suggestionRow(_ suggestion: AIReplySuggester.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(suggestion.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { WeChatLauncher.copyText(suggestion.text) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text(suggestion.tone)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
                Text(suggestion.rationale)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.04))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { replyText = suggestion.text }
    }

    private func loadSuggestions() async {
        // Find a matching reply debt item for this chat
        guard let item = monitor.replyDebtItems.first(where: { $0.chatUsername == chatUsername }) else { return }
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        suggestions = await monitor.loadReplySuggestions(for: item)
    }

    // MARK: - Shared

    private var divider: some View {
        Divider()
            .background(Color.white.opacity(0.07))
            .padding(.horizontal, 10)
    }

    private func sectionLabel(_ label: String, count: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            if let count = count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .monospacedDigit()
            }
            Spacer()
        }
    }
}
