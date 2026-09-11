import SwiftUI
import AppKit

/// Detail view for a selected conversation — messages, AI analysis,
/// pending asks, and reply suggestions. The "workbench" for a single chat.
struct ConversationDetailView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var reader: WeChatReader
    let chatUsername: String
    let chatName: String

    @State private var suggestions: [AIReplySuggester.Suggestion] = []
    @State private var isLoadingSuggestions = false
    @State private var suggestionMessage: String?
    @State private var replyText = ""
    @State private var isSending = false
    @State private var sendResult: String?
    @State private var needsOperationPermission = false
    @State private var sendSucceeded = false
    @State private var showSendConfirm = false
    @State private var sourceSavedDraftID: Int64?
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    messagesSection
                    if !suggestions.isEmpty || isLoadingSuggestions {
                        divider
                        replySuggestionsSection
                    }
                }
                .padding(.bottom, 8)
            }

            Divider().background(Color.white.opacity(0.12))
            replyComposer
        }
        .onAppear {
            restoreReplyDraft()
            applyPreviewSendReceipt()
        }
        .onChange(of: panelState.previewSendReceipt) { _, _ in
            applyPreviewSendReceipt()
        }
        .onChange(of: chatUsername) { _, _ in
            // A detail view can be reused while routing between chats. Never
            // carry the prior chat's saved-row identity across that boundary.
            sourceSavedDraftID = nil
            restoreReplyDraft()
        }
        .onChange(of: panelState.pendingReplyDraftContinuation) { _, _ in
            applyPendingReplyDraftContinuation()
        }
        .onChange(of: replyText) { _, value in
            monitor.composerDraftEdits[chatUsername] = value
            do { try store.setSetting("composer_draft:\(chatUsername)", value: value) }
            catch { sendResult = "草稿暂未保存，请重试"; sendSucceeded = false }
        }
        .companionDialogBackdrop(showSendConfirm) {
            if showSendConfirm {
                CompanionDialog(title: CompanionProductCopy.sendConfirmTitle, dark: true, onClose: { showSendConfirm = false }) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(CompanionProductCopy.sendConfirmMessage(name: chatName, text: replyText))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.sendConfirmBack) { showSendConfirm = false }
                                .foregroundStyle(.white)
                            Button(CompanionProductCopy.sendConfirmAction) {
                                showSendConfirm = false
                                Task { await sendReply() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(CompanionPalette.jade)
                            .disabled(isSending)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            ChatRenameSheet(
                chatUsername: chatUsername,
                currentName: monitor.displayName(for: chatUsername),
                memberNames: reader.groupMemberNames(for: chatUsername)
            )
        }
    }

    private func restoreReplyDraft() {
        replyText = monitor.composerDraftEdits[chatUsername]
            ?? store.getSetting("composer_draft:\(chatUsername)")
            ?? ""
        if replyText.isEmpty, PreviewRuntime.isEnabled {
            replyText = store.loadDrafts().first(where: { $0.chatUsername == chatUsername })?.text
                ?? "我确认一下大家的时间，15:00 前回复你。"
        }
        applyPendingReplyDraftContinuation()
    }

    private func applyPendingReplyDraftContinuation() {
        guard let continuation = panelState.consumeReplyDraftContinuationRequest(for: chatUsername) else { return }
        // The explicit continuation request represents the user's confirmed
        // choice in the overwrite alert, so it may replace the current
        // composer contents. Subsequent typing is preserved by onChange.
        sourceSavedDraftID = continuation.savedDraftID
        replyText = continuation.text
    }

    private var composerStatusTitle: String {
        if sendSucceeded { return "已发送" }
        if sendResult == CompanionProductCopy.sendUncertain { return "结果待核对" }
        return "未发送"
    }

    private var composerStatusDetail: String {
        if sendSucceeded { return "这条回复已在微信中核对。" }
        if sendResult == CompanionProductCopy.sendUncertain { return "先到微信查看，不要重复发送。" }
        return "发送前会让你确认收件人和内容。"
    }

    private func applyPreviewSendReceipt() {
        guard PreviewRuntime.isEnabled, let receipt = panelState.previewSendReceipt else { return }
        sendResult = receipt
        sendSucceeded = receipt.contains("已发送")
        panelState.previewSendReceipt = nil
    }

    // MARK: - Reply Composer

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result = sendResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result)
                        .font(.system(size: 12))
                        .foregroundColor(sendSucceeded ? CompanionPalette.islandMint : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if sendSucceeded {
                            Button("查看微信") {
                                monitor.openWeChatChat(chatUsername)
                            }
                            .buttonStyle(.link)
                        } else {
                            Button("去微信核对") {
                                monitor.openWeChatChat(chatUsername)
                            }
                            .buttonStyle(.link)
                            Button("复制回复") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(replyText, forType: .string)
                            }
                            .buttonStyle(.link)
                        }
                        if needsOperationPermission {
                            Button("检查微信操作权限") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            replyControls
        }
    }

    private var replyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI 建议", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CompanionPalette.islandMint)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $replyText)
                    .accessibilityLabel("回复内容")
                    .font(.system(size: 14))
                    .frame(minHeight: 58, maxHeight: 108)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .scrollContentBackground(.hidden)

                if replyText.isEmpty {
                    Text("输入回复…")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CompanionPalette.islandMint.opacity(0.55), lineWidth: 1.5)
            )
            .cornerRadius(8)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(composerStatusTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                    Text(composerStatusDetail)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                Spacer()

                if isSending {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 28, height: 28)
                } else {
                    Button("存为草稿") {
                        guard !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        needsOperationPermission = false
                        do {
                            try monitor.saveDraft(chatUsername: chatUsername, chatName: chatName, text: replyText, replacingDraftID: sourceSavedDraftID)
                            // Saving a draft is not a send — the receipt goes
                            // through the toast channel so the composer status
                            // never reads "已发送" for text still in 草稿.
                            sendSucceeded = false
                            sourceSavedDraftID = nil
                            replyText = ""
                            panelState.showToast("已存为草稿")
                        } catch {
                            if case HUDStoreError.draftNotFound = error {
                                sendResult = "这条草稿已被删除，回复内容仍保留"
                            } else {
                                sendResult = "草稿未保存，请重试"
                            }
                            sendSucceeded = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("存为草稿，可在「草稿」里继续编辑")

                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(replyText, forType: .string)
                        // Copy is not a send — marking sendSucceeded would flip
                        // the composer status to "已发送" for unsent text.
                        sendResult = "回复已复制，发送前请核对收件人。"
                        sendSucceeded = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("发送…") {
                        guard !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        showSendConfirm = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(CompanionPalette.jade, in: Capsule())
                    .opacity(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sendReply() async {
        guard !isSending else { return }
        let draftAtSend = replyText
        let text = draftAtSend.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        needsOperationPermission = false
        defer { isSending = false }

        // Keep the entire previous window, not only its latest row: repeated
        // identical replies must not turn an old message into a new receipt.
        let baseline = try? monitor.reader.getMessages(chatUsername: chatUsername, limit: 20)
        guard let baseline else {
            sendResult = "无法读取发送前记录，草稿已保留，请在微信中核对后回复"
            sendSucceeded = false
            return
        }
        let previousIDs = Set(baseline.map(\.id))
        let startedAt = Int(Date().timeIntervalSince1970)
        if PreviewRuntime.isEnabled {
            sendResult = CompanionProductCopy.sendUncertain
            sendSucceeded = false
            return
        }
        let sendKey = monitor.loadAutopilotConfig().sendKey
        let result = await WeChatLauncher.sendMessageDetailed(chatName: chatName, text: text, sendKey: sendKey)
        needsOperationPermission = result == .failed(.accessibilityDenied)
        var confirmed = false
        if result.succeeded {
            for _ in 0..<3 {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { break }
                guard let messages = try? monitor.reader.getMessages(chatUsername: chatUsername, limit: 20) else { continue }
                let username = monitor.reader.myUsername()
                confirmed = ManualReplyReceipt.confirms(messages: messages, previousIDs: previousIDs,
                    chatUsername: chatUsername, expectedText: text, startedAt: startedAt,
                    myUsername: username, myDisplayName: monitor.reader.displayName(for: username),
                    mySelfNames: monitor.reader.mySelfNames)
                if confirmed { break }
            }
        }
        if confirmed {
            sendResult = CompanionProductCopy.sendSuccess(name: chatName)
            sendSucceeded = true
            if replyText == draftAtSend { replyText = "" }
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
            sendResult = result.failureMessage ?? CompanionProductCopy.sendUncertain
            sendSucceeded = false
        }
        if confirmed { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { sendResult = nil } }
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
            .accessibilityLabel("返回收件箱")

            let isGroup = chatUsername.contains("@chatroom")
                || store.getWhitelistEntry(username: chatUsername)?.isGroup == true
            Image(systemName: isGroup ? "person.3.fill" : "person.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))

            Text("\(monitor.displayName(for: chatUsername)) · \(isGroup ? "群聊" : "私聊")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            // WeChat names only some groups. When this one has no name of its
            // own, offer to name it instead of leaving a placeholder.
            if monitor.hasOnlyFallbackName(chatUsername: chatUsername) {
                Button(action: { isRenaming = true }) {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("给这个会话起个名字")
                .accessibilityLabel("给这个会话起个名字")
            }

            Spacer()

            Button(action: { panelState.clearDetail(); panelState.currentState = .extended }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭对话")

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Messages

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let messages = monitor.recentMessages(chatUsername: chatUsername, limit: 8)
            if messages.isEmpty && PreviewRuntime.isEnabled {
                previewTranscript
            } else if messages.isEmpty {
                Text("暂无消息记录")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(messages.suffix(4).enumerated()), id: \.offset) { _, msg in
                    messageBubble(msg)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var previewTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageBubble((sender: "林晓", body: "今天的评审定在几点？"))
            messageBubble((sender: "我", body: "我先确认一下。"))
        }
    }

    private func messageBubble(_ msg: (sender: String, body: String)) -> some View {
        let mine = msg.sender == "我" || monitor.reader.mySelfNames.contains(msg.sender)
        return HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(msg.sender)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                Text(msg.body)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(mine ? 0.06 : 0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    // MARK: - Reply suggestions

    private var replySuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("AI 建议")
                Spacer()
                if !isLoadingSuggestions && suggestions.isEmpty && hasReplyDebtContext {
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
                    Text("正在生成…")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.vertical, 6)
            } else if suggestions.isEmpty {
                Text(suggestionMessage ?? (hasReplyDebtContext ? "点击「生成建议」获取 AI 回复建议" : "当前没有待回复上下文"))
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
        SuggestionRowView(suggestion: suggestion) { text in
            replyText = text
        }
    }

    private func loadSuggestions() async {
        // Find a matching reply debt item for this chat
        guard let item = monitor.replyDebtItems.first(where: { $0.chatUsername == chatUsername }) else {
            suggestionMessage = "当前没有待回复上下文"
            return
        }
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        suggestions = await monitor.loadReplySuggestions(for: item)
        suggestionMessage = suggestions.isEmpty ? "暂时没有可用建议" : nil
    }

    private var hasReplyDebtContext: Bool {
        monitor.replyDebtItems.contains { $0.chatUsername == chatUsername }
    }

    // MARK: - Shared

    private var divider: some View {
        Divider()
            .background(Color.white.opacity(0.07))
            .padding(.horizontal, 10)
    }

    private func sectionLabel(_ label: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
        }
    }
}

// MARK: - Suggestion Row

/// A single AI reply suggestion — hover-highlighted, tap to adopt into
/// the composer, copy button with green checkmark feedback.
private struct SuggestionRowView: View {
    let suggestion: AIReplySuggester.Suggestion
    let onAdopt: (String) -> Void
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(suggestion.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: {
                    WeChatLauncher.copyText(suggestion.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(copied ? .green : .white.opacity(0.4))
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
        .background(hovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .companionAnimation(CompanionMotion.ease(0.15), value: hovered)
        .onTapGesture { onAdopt(suggestion.text) }
    }
}
