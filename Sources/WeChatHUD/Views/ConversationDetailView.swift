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
    @State private var transcriptRows: [FocusedTranscript.Row] = []
    @State private var hasTranscriptFocus = false
    @State private var selfNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        messagesSection
                        // Render whenever there is reply-debt context, not only once
                        // suggestions exist: the "生成建议" button lives inside this
                        // section, and it is the only caller of `loadSuggestions()`.
                        // Gating the section on `!suggestions.isEmpty` made the block,
                        // the button, `SuggestionRowView` and `recordReplyFeedback`
                        // unreachable — suggestions could never appear.
                        if !suggestions.isEmpty || isLoadingSuggestions || hasReplyDebtContext {
                            divider
                            replySuggestionsSection
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onAppear { scrollTranscriptToLatest(proxy) }
                .onChange(of: chatUsername) { _, _ in scrollTranscriptToLatest(proxy) }
                .onChange(of: transcriptRows.count) { _, _ in scrollTranscriptToLatest(proxy) }
                .onChange(of: hasTranscriptFocus) { _, _ in scrollTranscriptToLatest(proxy) }
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
        .onChange(of: panelState.pendingTranscriptFocus) { _, focus in
            guard let focus, focus.chatUsername == chatUsername else { return }
            Task { await loadTranscriptAndIdentity() }
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
                            .companionFont(size: 13)
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
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
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
        .task(id: chatUsername) {
            await loadTranscriptAndIdentity()
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
                        .companionFont(size: 12)
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
            Label("回复", systemImage: "square.and.pencil")
                .companionFont(size: 11, weight: .semibold)
                .foregroundStyle(CompanionPalette.islandMint)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $replyText)
                    .accessibilityLabel("回复内容")
                    .companionFont(size: 14)
                    .frame(height: 64)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .scrollContentBackground(.hidden)

                if replyText.isEmpty {
                    Text("输入回复…")
                        .companionFont(size: 14)
                        .companionDimmedForeground(0.35)
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
                    // 「未发送」 is the default state of every composer, so
                    // before the user has done anything it reports nothing.
                    // It earns its line back once a send, copy or failure makes
                    // "not sent" a fact rather than a starting condition.
                    if sendSucceeded || sendResult != nil {
                        Text(composerStatusTitle)
                            .companionFont(size: 11, weight: .medium)
                            .companionDimmedForeground(0.55)
                    }
                    Text(composerStatusDetail)
                        .companionFont(size: 10)
                        .companionDimmedForeground(0.35)
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
                    .companionFont(size: 12, weight: .semibold)
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
        guard let baseline = await monitor.messagesForSendReceipt(chatUsername: chatUsername, limit: 20) else {
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
        // `chatName` is the HUD label, which may be a local alias WeChat has
        // never seen. Passing it as the search set pointed the send at a
        // same-named stranger (and validated them as the target). Search only
        // with names WeChat itself resolves.
        let result = await WeChatLauncher.sendMessageDetailed(
            chatName: chatName,
            text: text,
            sendKey: sendKey,
            searchNames: monitor.weChatSendSearchNames(for: chatUsername)
        )
        needsOperationPermission = result == .failed(.accessibilityDenied)
        var confirmed = false
        if result.succeeded {
            for _ in 0..<3 {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { break }
                guard let messages = await monitor.messagesForSendReceipt(chatUsername: chatUsername, limit: 20) else { continue }
                let identity = await monitor.selfMessageIdentity()
                confirmed = ManualReplyReceipt.confirms(messages: messages, previousIDs: previousIDs,
                    chatUsername: chatUsername, expectedText: text, startedAt: startedAt,
                    myUsername: identity.username, myDisplayName: identity.displayName,
                    mySelfNames: identity.selfNames)
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
                let peerLast = await monitor.lastPeerMessage(chatUsername: chatUsername)
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
                    .companionFont(size: 11, weight: .semibold)
                    .companionDimmedForeground(0.6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回收件箱")

            let isGroup = MessageHelpers.isGroupChat(chatUsername)
                || store.getWhitelistEntry(username: chatUsername)?.isGroup == true
            Image(systemName: isGroup ? "person.3.fill" : "person.fill")
                .companionFont(size: 10)
                .companionDimmedForeground(0.5)

            Text("\(monitor.displayName(for: chatUsername)) · \(isGroup ? "群聊" : "私聊")")
                .companionFont(size: 13, weight: .semibold)
                .foregroundColor(.white)
                .lineLimit(1)

            // WeChat names only some groups. When this one has no name of its
            // own, offer to name it instead of leaving a placeholder.
            if monitor.hasOnlyFallbackName(chatUsername: chatUsername) {
                Button(action: { isRenaming = true }) {
                    // `pencil.circle` at 11pt collapses into a circle with one
                    // diagonal stroke, which reads as ⊘ "not allowed" sitting
                    // next to the chat's name. Uncircled, the pencil stays a
                    // pencil at this size.
                    Image(systemName: "pencil")
                        .companionFont(size: 11, weight: .semibold)
                        .companionDimmedForeground(0.55)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("给这个会话起个名字")
                .accessibilityLabel("给这个会话起个名字")
            }

            Spacer()
            // No trailing close button here: `DetailPanelView` already pins an
            // `xmark.circle.fill` in this exact corner, and being drawn later it
            // covered this one completely — a control no click could ever reach.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Messages

    private static let transcriptLimit = 20

    /// Load newest-first rows via actor helper, then flip into WeChat order
    /// (oldest at top). Sync `recentMessages` stays for WhitelistScan.
    private func loadTranscriptAndIdentity() async {
        // Clear stale rows when routing between chats before the async hop returns.
        transcriptRows = []
        hasTranscriptFocus = false
        let focus = panelState.consumeTranscriptFocus(for: chatUsername)
        async let identityTask = monitor.selfMessageIdentity()
        let loaded: [(sender: String, body: String)]
        if let focus {
            loaded = await monitor.messagesAroundFocus(chatUsername: chatUsername, timestamp: focus.timestamp)
        } else {
            let newestFirst = await monitor.recentMessagesAsync(
                chatUsername: chatUsername, limit: Self.transcriptLimit
            ).map { (sender: $0.sender, body: MessageHelpers.displayText($0.body)) }
            loaded = MessageHelpers.chronologicalWindow(
                newestFirst: newestFirst,
                visible: Self.transcriptLimit
            )
        }
        selfNames = await identityTask.selfNames
        transcriptRows = FocusedTranscript.assemble(loaded: loaded, focus: focus)
        hasTranscriptFocus = transcriptRows.contains { $0.isFocus }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if transcriptRows.isEmpty && PreviewRuntime.isEnabled && !hasTranscriptFocus {
                previewTranscript
            } else if transcriptRows.isEmpty {
                Text("暂无消息记录")
                    .companionFont(size: 13)
                    .companionDimmedForeground(0.35)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(transcriptRows.enumerated()), id: \.offset) { index, msg in
                    messageBubble(sender: msg.sender, body: msg.body, highlighted: msg.isFocus)
                        .id(msg.isFocus ? "transcript-focus" : transcriptAnchor(index, isLast: index == transcriptRows.count - 1))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var previewTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageBubble(sender: "林晓", body: "今天的评审定在几点？")
            messageBubble(sender: "我", body: "我先确认一下。")
        }
    }

    private func messageBubble(sender: String, body: String, highlighted: Bool = false) -> some View {
        let mine = sender == "我" || selfNames.contains(sender)
        return HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(sender)
                    .companionFont(size: 10, weight: .medium)
                    .companionDimmedForeground(0.45)
                Text(body)
                    .companionFont(size: 13)
                    .companionDimmedForeground(0.9)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        (highlighted ? CompanionPalette.jade.opacity(0.28) : Color.white.opacity(mine ? 0.06 : 0.10)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(highlighted ? CompanionPalette.jade.opacity(0.7) : Color.clear, lineWidth: 1)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func transcriptAnchor(_ index: Int, isLast: Bool) -> String {
        isLast ? "transcript-latest" : "transcript-\(index)"
    }

    private func scrollTranscriptToLatest(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(nil) {
                proxy.scrollTo(hasTranscriptFocus ? "transcript-focus" : "transcript-latest", anchor: hasTranscriptFocus ? .center : .bottom)
            }
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
                                .companionFont(size: 10)
                            Text("生成建议")
                                .companionFont(size: 10)
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
                        .companionFont(size: 10)
                        .companionDimmedForeground(0.4)
                }
                .padding(.vertical, 6)
            } else if suggestions.isEmpty {
                Text(suggestionMessage ?? (hasReplyDebtContext ? "点击「生成建议」获取 AI 回复建议" : "当前没有待回复上下文"))
                    .companionFont(size: 10)
                    .companionDimmedForeground(0.3)
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
                .companionFont(size: 10, weight: .semibold)
                .companionDimmedForeground(0.45)
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
                    .companionFont(size: 13)
                    .companionDimmedForeground(0.88)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: {
                    WeChatLauncher.copyText(suggestion.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .companionFont(size: 10)
                        .foregroundColor(copied ? .green : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text(suggestion.tone)
                    .companionFont(size: 10)
                    .companionDimmedForeground(0.4)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
                Text(suggestion.rationale)
                    .companionFont(size: 10)
                    .companionDimmedForeground(0.3)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(hovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .companionAnimation(CompanionMotion.hover(), value: hovered)
        .onTapGesture { onAdopt(suggestion.text) }
    }
}
