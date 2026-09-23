import SwiftUI

/// Shared filter so every surface that lists pending sends agrees on which ones
/// still need a human.
enum ApprovalWorkspacePolicy {
    static func pendingSendsNeedingHuman(
        _ queue: [PendingSend],
        autoSendEnabled: Bool
    ) -> [PendingSend] {
        if autoSendEnabled {
            return queue.filter { $0.manualOnlyReason != nil }
        }
        return queue
    }

    /// A receipt belongs to the row that earned it. `displayedRowID` has to be the
    /// row the detail pane is showing *right now*, not the stored selection: the
    /// acted-on draft leaves 待确认 the moment the write lands, and then the
    /// selection id still names the vanished row while the pane has already fallen
    /// back to the next one. Gating on the stored id would post 「已取消本条」 under
    /// an unrelated reply, with its own green check.
    static func receiptStillOnScreen(actionedRowID: Int64, displayedRowID: Int64?) -> Bool {
        displayedRowID == actionedRowID
    }
}

/// 待确认回复 master-detail matching 不漏事 figure 07 / 40.
struct ApprovalWorkspaceView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore

    /// Island detail pane keeps start/stop on its own header.
    var showsSessionToggle: Bool = true

    enum Filter: String, CaseIterable, Identifiable {
       case pending = "待确认"
       case sent = "已发送"
        case failed = "没发出去"
       case all = "全部"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .pending
    @State private var selectedID: Int64?
    @State private var selectedPendingID: UUID?
    @State private var editedReply: String = ""
    @State private var receipt: Receipt?
    @State private var showSendConfirm = false
    @State private var isSending = false
    @State private var isCancelling = false
    @State private var isSavingDraft = false

    @State private var sendConfirmError: String?
    @State private var isStartingAutopilot = false
    @State private var isPausingAutopilot = false

    /// A receipt states its own verdict instead of having one inferred from its
    /// wording. The icon used to be chosen by looking for 「失败」 in the
    /// sentence, and none of the refusals on this screen contain it — a muted
    /// conversation, an unreadable 托管设置, an unsaved draft and a reply whose
    /// receipt never came back all printed a green checkmark over a message
    /// that never reached anyone.
    private struct Receipt: Equatable {
        let text: String
        let isFailure: Bool
        var offersUnsilence: Bool = false

        static func done(_ text: String) -> Receipt { Receipt(text: text, isFailure: false) }
        static func problem(_ text: String, offersUnsilence: Bool = false) -> Receipt {
            Receipt(text: text, isFailure: true, offersUnsilence: offersUnsilence)
        }
    }

    private var entries: [AutopilotLogEntry] {
        switch filter {
        case .pending: return monitor.autopilotLog.filter { $0.action == .pending }
        case .sent: return monitor.autopilotLog.filter { $0.action == .sent || $0.action == .vipNotified }
        case .failed: return monitor.autopilotLog.filter { $0.action == .failed }
        case .all: return monitor.autopilotLog
        }
    }

    private var selected: AutopilotLogEntry? {
        if selectedPending != nil { return nil }
        if let selectedID, let match = entries.first(where: { $0.id == selectedID }) {
            return match
        }
        return selectedPendingID == nil ? entries.first : nil
    }

    private var selectedPending: PendingSend? {
        if let selectedPendingID,
           let match = humanNeededSends.first(where: { $0.id == selectedPendingID }) {
            return match
        }
        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            return humanNeededSends.first
        }
        return nil
    }

    private var actionBusy: Bool { isSending || isCancelling || isSavingDraft }

    private var pauseHoldReason: String {
        monitor.autopilotManuallyPaused ? "正在恢复整理" : "正在暂停整理"
    }

    private var pauseButtonTitle: String {
        if isPausingAutopilot {
            return monitor.autopilotManuallyPaused ? "正在恢复…" : "正在暂停…"
        }
        return monitor.autopilotManuallyPaused ? "恢复" : "暂停"
    }

    private func startAutopilotSession() {
        guard !isStartingAutopilot else { return }
        isStartingAutopilot = true
        Task { @MainActor in
            let receipt = AutopilotStartReceipt.resolve(
                started: await monitor.startAutopilotAndWait()
            )
            isStartingAutopilot = false
            panelState.showToast(receipt.toast, duration: receipt.dismissesPopover ? 2 : 4)
        }
    }

    private func toggleAutopilotPause() {
        guard !isPausingAutopilot else { return }
        let resume = monitor.autopilotManuallyPaused
        isPausingAutopilot = true
        Task { @MainActor in
            defer { isPausingAutopilot = false }
            if resume {
                await monitor.autopilotService?.manualResume()
            } else {
                await monitor.autopilotService?.manualPause()
            }
        }
    }

    private var actionHoldReason: String? {
        if isSending { return "正在发送" }
        if isSavingDraft { return "正在保存草稿" }
        if isCancelling { return "正在取消本条" }
        return nil
    }

    private var pendingCount: Int {
        monitor.autopilotLog.filter { $0.action == .pending }.count
    }

    /// `nil` means 「这一页读不到托管设置」, which is a different fact from
    /// 「自动发送没开」 — and this page uses the value to tell the user a reply
    /// has not gone out yet. A busy lock used to flip every sentence on this
    /// page to the "off" wording while sends were continuing.
    private var autoSendState: Bool? {
        store.autopilotConfigForSendGate()?.autoSendEnabled
    }

    private var autoSendOn: Bool { autoSendState == true }

    private var autoSendToolbarText: String {
        switch autoSendState {
        case .some(true): return "自动发送开启"
        case .some(false): return "自动发送关闭"
        case nil: return "自动发送状态暂时读不到"
        }
    }

    /// Nothing in the app enforces a maximum length on a reply — the counter
    /// used to read 「n / 500」, which is a cap the user would believe and that
    /// does not exist. It now says what happens past it: it goes out as typed.
    private static let suggestedReplyLength = 500

    private var replyOverSuggestedLength: Bool {
        editedReply.count > Self.suggestedReplyLength
    }

    private var replyLengthHint: String {
        replyOverSuggestedLength
            ? "\(editedReply.count) 字 · 已超过建议 \(Self.suggestedReplyLength) 字，仍会原样发出"
            : "\(editedReply.count) / \(Self.suggestedReplyLength)"
    }

    private var humanNeededSends: [PendingSend] {
        ApprovalWorkspacePolicy.pendingSendsNeedingHuman(
            monitor.autopilotPendingSendQueue,
            autoSendEnabled: autoSendOn
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty && humanNeededSends.isEmpty {
                emptyState
            } else {
                HSplitView {
                    listPane.frame(minWidth: 220, idealWidth: 340)
                    detailPane.frame(minWidth: 240, idealWidth: 460)
                }
            }
            if let receipt {
                HStack(alignment: .top, spacing: 10) {
                    Label(receipt.text,
                          systemImage: receipt.isFailure ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .companionFont(size: 13, weight: .medium)
                        .foregroundStyle(receipt.isFailure ? .orange : CompanionPalette.jadeInk)
                    if receipt.offersUnsilence, let chatUsername = selected?.chatUsername {
                        Button("取消静音") {
                            if monitor.unsilenceConversation(username: chatUsername) {
                                self.receipt = .done("已取消静音，可以再确认发送")
                            }
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(CompanionPalette.jadeInk)
                        .accessibilityLabel("取消静音并留下这条待确认回复")
                    }
                }
                .padding(.top, 10)
                .transition(.companionStatusReveal)
            }
        }
        .onAppear {
            if selectedPending == nil { selectedID = selected?.id }
            syncEditor()
        }
        .companionAnimation(CompanionMotion.ease(), value: receipt)
        .onChange(of: selected?.id) { _, _ in
            // A receipt is about the action taken on one row. It used to survive
            // selecting a different row, so 「已发送给「A」」 sat under B's detail
            // pane — and since the Receipt now carries its own verdict, the
            // stale banner reports a confident, wrong green checkmark.
            receipt = nil
            syncEditor()
        }
        .onChange(of: selectedPending?.id) { _, _ in
            receipt = nil
        }
        .onChange(of: entries.count) { _, _ in reconcileSelection() }
        .onChange(of: humanNeededSends.count) { _, _ in reconcileSelection() }
        .onChange(of: filter) { _, _ in reconcileSelection() }
        .companionDialogBackdrop(showSendConfirm) {
            if showSendConfirm {
                CompanionDialog(title: CompanionProductCopy.sendConfirmTitle, onClose: { if !isSending { showSendConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.sendConfirmMessage(name: selected?.chatName ?? "", text: editedReply))
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sendConfirmError {
                            Text(sendConfirmError)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.sendConfirmBack) { showSendConfirm = false }
                                .companionBusyHold(isSending, "正在发送")
                            Button {
                                Task {
                                    let sent = await confirmSend()
                                    if sent { showSendConfirm = false }
                                }
                            } label: {
                                Text(isSending ? "正在发送…" : CompanionProductCopy.sendConfirmAction)
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isSending)
                            .help(isSending ? "正在发送" : "")
                            .accessibilityHint(isSending ? "正在发送" : "")
                        }
                    }
                    .companionAnimation(CompanionMotion.ease(), value: sendConfirmError)
                }
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { value in
                    let count = value == .pending ? pendingCount : nil
                    CompanionFilterPill(
                        title: count.map { "\(value.rawValue) \($0)" } ?? value.rawValue,
                        selected: filter == value,
                        tint: SettingsView.Tab.autopilotDashboard.accentColor
                    ) { filter = value }
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: monitor.autopilotActive ? "arrow.triangle.2.circlepath" : "pause.circle")
                    Text(monitor.autopilotActive ? "正在整理…" : "尚未开始整理")
                    Text("·")
                    Text(autoSendToolbarText)
                    if monitor.autopilotActive {
                        Button {
                            toggleAutopilotPause()
                        } label: {
                            Text(pauseButtonTitle)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isPausingAutopilot)
                        .help(isPausingAutopilot ? pauseHoldReason : "")
                        .accessibilityHint(isPausingAutopilot ? pauseHoldReason : "")
                    } else if showsSessionToggle {
                        Button {
                            startAutopilotSession()
                        } label: {
                            Text(isStartingAutopilot ? AutopilotStartCopy.starting : AutopilotStartCopy.start)
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isStartingAutopilot)
                            .help(isStartingAutopilot ? AutopilotStartCopy.startingHint : AutopilotStartCopy.startHint)
                            .accessibilityHint(isStartingAutopilot ? AutopilotStartCopy.startingHint : AutopilotStartCopy.startHint)
                    }
                }
                .companionFont(size: 12)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            filter == .pending ? "还没有待确认的回复" : "这一栏还没有记录",
            systemImage: "bubble.left.and.bubble.right",
            // The 暂停 reassurance belongs to the state where a 暂停 button is on
            // screen; while nothing is running this page explains a control the
            // user cannot see.
            description: Text(monitor.autopilotActive
                ? "正在整理，写好的草稿会出现在这一栏。暂停不会删除现有草稿。"
                : "点开始整理后，助理会写成草稿。发不发都由你决定。")
        )
        .frame(maxWidth: .infinity, minHeight: 280)
        .overlay(alignment: .bottom) {
            if filter != .pending {
                Button("看待确认") {
                    withMotion(CompanionMotion.pageChange()) { filter = .pending }
                }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .padding(.bottom, 24)
                .accessibilityLabel("看待确认的回复")
            } else if !monitor.autopilotActive {
                Button {
                    startAutopilotSession()
                } label: {
                    Text(isStartingAutopilot ? AutopilotStartCopy.starting : AutopilotStartCopy.start)
                }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                    .padding(.bottom, 24)
                    .disabled(isStartingAutopilot)
                    .help(isStartingAutopilot ? AutopilotStartCopy.startingHint : AutopilotStartCopy.startHint)
                    .accessibilityLabel(isStartingAutopilot ? AutopilotStartCopy.starting : AutopilotStartCopy.start)
                    .accessibilityHint(isStartingAutopilot ? AutopilotStartCopy.startingHint : AutopilotStartCopy.startHint)
            }
        }
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !humanNeededSends.isEmpty {
                    HStack {
                        Text(autoSendOn ? "需人工确认" : "等你确认")
                            .companionFont(size: 12, weight: .semibold)
                        Text("\(humanNeededSends.count)")
                            .companionFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 2)
                    ForEach(humanNeededSends) { item in
                        ApprovalPendingSendRow(
                            item: item,
                            isSelected: selectedPending?.id == item.id,
                            onSelect: {
                                selectedPendingID = item.id
                                selectedID = nil
                            },
                            onSendNow: { await sendPendingNow(item) },
                            onCancel: { await cancelPending(item) }
                        )
                    }
                    if !entries.isEmpty {
                        Divider().padding(.vertical, 6)
                    }
                }
                ForEach(entries) { entry in
                    Button {
                        selectedID = entry.id
                        selectedPendingID = nil
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            CompanionAvatar(name: entry.senderName, size: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.senderName).companionFont(size: 13, weight: .semibold)
                                    Spacer()
                                    Text(CommitmentPresentation.timeLabel(entry.createdAt))
                                        .companionFont(size: 11).foregroundStyle(.secondary)
                                }
                                statusLabel(entry)
                                Text(entry.triggerText)
                                    .companionFont(size: 12)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(10)
                        .background(selected?.id == entry.id ? CompanionPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(CompanionRowPressStyle())
                }
            }
            .padding(.trailing, 10)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func statusLabel(_ entry: AutopilotLogEntry) -> some View {
        if entry.riskLevel == .high || (entry.aiReasoning?.contains("转账") == true) {
            Text("涉及转账需人工处理")
                .companionFont(size: 11, weight: .medium)
                .foregroundStyle(.orange)
        } else {
            Text(entry.action == .pending ? "待确认回复" : actionTitle(entry.action))
                .companionFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }

    private func actionTitle(_ action: AutopilotAction) -> String {
        switch action {
       case .sent, .vipNotified: return "已发送"
        case .failed: return "没发出去"
       case .pending: return "待确认回复"
        default: return "已记录"
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let pending = selectedPending {
            pendingDetail(pending)
        } else if let selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.chatName).workspaceTitle()
                        Text("收件人 \(selected.senderName) · \(MessageHelpers.isGroupChat(selected.chatUsername) ? "群聊" : "私聊")")
                            .companionFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看聊天记录") {
                        panelState.showChatDetail(chatUsername: selected.chatUsername, chatName: selected.chatName)
                    }
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jadeInk)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.triggerText)
                        .companionFont(size: 14)
                    Text(CommitmentPresentation.timeLabel(selected.createdAt))
                        .companionFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("拟回复", systemImage: "sparkles")
                            .companionFont(size: 13, weight: .semibold)
                        CompanionBadge(title: "AI 草稿", systemImage: "text.badge.star")
                    }
                    TextEditor(text: $editedReply)
                        .accessibilityLabel("拟回复")
                        .companionFont(size: 14)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                    HStack {
                        if !autoSendOn {
                            Label(autoSendState == nil
                                ? "暂时读不到自动发送设置，这条是否已经发出请在微信里核对。"
                                : "当前未开启自动发送，这条回复尚未发出。", systemImage: "info.circle")
                                .companionFont(size: 12)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(replyLengthHint)
                            .companionFont(size: 11)
                            .foregroundStyle(replyOverSuggestedLength ? Color.red : Color.secondary)
                    }
                }

               if selected.action == .pending {
                   HStack(spacing: 8) {
                      Button { sendConfirmError = nil; showSendConfirm = true } label: {
                          Text(isSending ? "正在发送…" : "确认发送")
                      }
                          .tint(SettingsView.Tab.autopilotDashboard.accentColor)
                          .buttonStyle(.borderedProminent)
                           .disabled(editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actionBusy)
                            .help(actionHoldReason ?? (editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "先写回复" : ""))
                            .accessibilityHint(actionHoldReason ?? (editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "先写回复" : ""))
                        Button {
                            let target = selected
                            guard !actionBusy else { return }
                            isSavingDraft = true
                            Task { @MainActor in
                                defer { isSavingDraft = false }
                                let written: Receipt
                                do {
                                    try await monitor.saveAutopilotDraft(logId: target.id, reply: editedReply)
                                    written = .done("已保存草稿")
                                } catch {
                                    written = .problem("草稿没有保存，请重试。")
                                }
                                postReceipt(written, forRow: target.id)
                            }
                        } label: {
                            Text(isSavingDraft ? "正在保存…" : "保存修改")
                        }
                        .buttonStyle(.bordered)
                        .disabled(actionBusy)
                        .help(actionHoldReason ?? "")
                        .accessibilityHint(actionHoldReason ?? "")
                       Button(isCancelling ? "正在取消…" : "取消本条") {
                            let target = selected
                            // 确认发送 has this latch; this one didn't, so a double
                            // tap started two cancels for the same row and the
                            // second read back 「was not pending」 — a row the first
                            // tap already took out of the queue.
                            guard !actionBusy else { return }
                            isCancelling = true
                            Task { @MainActor in
                                defer { isCancelling = false }
                                let outcome = await monitor.rejectAutopilotItem(
                                    logId: target.id,
                                    chatUsername: target.chatUsername,
                                    replyText: target.generatedReply
                                )
                                if case .held(let reason) = outcome {
                                    postReceipt(.problem(reason), forRow: target.id)
                                } else {
                                   postReceipt(.done("已取消本条，对应的待发草稿已一并移除。"),
                                               forRow: target.id)
                               }
                           }
                       }
                      .buttonStyle(.bordered)
                      .disabled(actionBusy)
                       .help(actionHoldReason ?? "")
                       .accessibilityHint(actionHoldReason ?? "")
                   }
                } else if selected.action == .failed {
                    Text("这条没有发出。先到微信里看过，再决定要不要重发。")
                        .companionFont(size: 12)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                       Button("在微信中打开") {
                           monitor.openWeChatChat(selected.chatUsername)
                       }
                        .tint(SettingsView.Tab.autopilotDashboard.accentColor)
                        .buttonStyle(.borderedProminent)
                       Button("复制回复") {
                            let ok = CompanionClipboard.write(editedReply)
                            postReceipt(
                                ok ? .done(CompanionInteractionCopy.replyCopied) : .problem(CompanionInteractionCopy.copyFailed),
                                forRow: selected.id
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                       .help(editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "先写回复" : "")
                   }
                } else if selected.action == .sent || selected.action == .vipNotified {
                    Text("要核对请到微信里看这条对话。")
                        .companionFont(size: 12)
                        .foregroundStyle(.secondary)
                   Button("在微信中打开") {
                       monitor.openWeChatChat(selected.chatUsername)
                   }
                    .tint(SettingsView.Tab.autopilotDashboard.accentColor)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.leading, 16)
            .padding(.vertical, 12)
        }
    }

    private func reconcileSelection() {
        if let selectedPendingID, humanNeededSends.contains(where: { $0.id == selectedPendingID }) { return }
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        selectedPendingID = humanNeededSends.first?.id
        selectedID = selectedPendingID == nil ? entries.first?.id : nil
    }

    private func pendingDetail(_ item: PendingSend) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.chatName).workspaceTitle()
                    Text("收件人 \(item.senderName) · \(MessageHelpers.isGroupChat(item.chatUsername) ? "群聊" : "私聊")")
                        .companionFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.manualOnlyReason == nil
                     ? "\(item.remainingSeconds) 秒后将尝试发送"
                     : "等你确认后才会发出")
                    .companionFont(size: 12, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            if let reason = item.manualOnlyReason {
                Text(reason)
                    .companionFont(size: 13)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.replyText)
                .companionFont(size: 14)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            ApprovalPendingSendRow(
                item: item,
                showsActionsOnly: true,
                onSendNow: { await sendPendingNow(item) },
                onCancel: { await cancelPending(item) }
            )
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.vertical, 12)
    }

    private func syncEditor() {
        editedReply = selected?.generatedReply ?? ""
    }

    /// Every receipt on this page is written after an `await`, and the list can
    /// move on while the write is in flight — so the row it belongs to is checked
    /// again at the moment of posting, not just at click time.
    private func postReceipt(_ newReceipt: Receipt, forRow actionedRowID: Int64) {
        guard ApprovalWorkspacePolicy.receiptStillOnScreen(
            actionedRowID: actionedRowID, displayedRowID: selected?.id) else { return }
        receipt = newReceipt
    }

    @discardableResult
    private func confirmSend() async -> Bool {
        guard let selected, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        let actionedRowID = selected.id
        // 「什么都没敲」 and 「敲了但没在数据库里确认」 are different answers, and
        // the old `false` printed the second one for both: confirming a reply in
        // a muted conversation told the user to go check WeChat for a message
        // that had never been typed. The mute list is the one place that fact is
        // read, so this cannot drift from what 取消静音 offers.
        if monitor.silencedConversations.contains(where: { $0.username == selected.chatUsername }) {
            postReceipt(.problem("这个对话已静音，这条没有发出。取消静音后可以再确认发送。",
                                 offersUnsilence: true),
                        forRow: actionedRowID)
            sendConfirmError = "这个对话已静音，这条没有发出。取消静音后可以再确认发送。"
            return false
        }
        let attempt = await monitor.approveAutopilotItem(
            logId: selected.id,
            reply: editedReply,
            chatName: selected.chatName,
            chatUsername: selected.chatUsername,
            createdAt: selected.createdAt
        )
        // 「可能已发」 is reserved for the one case that earned it: the keys went
        // in and only the receipt is missing. It used to be printed for every
        // `false`, so a paused session, an unreadable 托管设置, a session cap and
        // a row that left the queue all told the user to go dig through WeChat
        // for a message that was never typed.
        if attempt.verified {
            postReceipt(.done(CompanionProductCopy.sendSuccess(name: selected.chatName)),
                        forRow: actionedRowID)
            sendConfirmError = nil
            return true
        } else if attempt.keystrokesLanded {
            postReceipt(.problem(CompanionProductCopy.sendUncertain), forRow: actionedRowID)
            sendConfirmError = CompanionProductCopy.sendUncertain
            return false
        } else {
            postReceipt(.problem(attempt.failureMessage ?? "这条没有发出。"), forRow: actionedRowID)
            sendConfirmError = attempt.failureMessage ?? "这条没有发出。"
            return false
        }
    }

    private func sendPendingNow(_ item: PendingSend) async -> String? {
        guard let config = monitor.loadAutopilotConfig() else {
            return ChatMonitor.unreadableConfigNotice
        }
        let outcome = await monitor.sendAutopilotNow(id: item.id, config: config)
        await monitor.syncAutopilotPendingQueue()
        switch outcome {
        case .sent:
            receipt = .done(CompanionProductCopy.sendSuccess(name: item.chatName))
            return nil
        case .blocked(let reason):
            return reason
        case .notFound:
            return "这条已经不在待确认列表里了"
        }
    }

    private func cancelPending(_ item: PendingSend) async {
        let outcome = await monitor.autopilotService?.cancelPendingSend(id: item.id)
            ?? .withdrawn
        await monitor.syncAutopilotPendingQueue()
        // 「已取消」 used to print whatever the two writes below did, and a
        // cancel that failed both of them leaves the row queued on this very
        // screen — a green checkmark next to the reply it claims is gone.
        if case .held(let reason) = outcome {
            receipt = .problem(reason)
        } else {
            receipt = .done("已取消即将发送的回复")
        }
    }
}

private struct ApprovalPendingSendRow: View {
    let item: PendingSend
    var isSelected: Bool = false
    var showsActionsOnly: Bool = false
    var onSelect: (() -> Void)? = nil
    let onSendNow: () async -> String?
    let onCancel: () async -> Void
    @State private var busy = false
    @State private var error: String?
    /// Sending here replaces a message the peer is waiting on and cannot be
    /// taken back, and the queue row truncates the draft to two lines — so
    /// the click opens the same confirmation the detail pane uses, with the
    /// recipient and the whole text.
    @State private var showConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !showsActionsOnly {
                Button(action: { onSelect?() }) {
                    HStack(alignment: .top, spacing: 10) {
                        CompanionAvatar(name: item.senderName, size: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.chatName).companionFont(size: 13, weight: .semibold)
                                Spacer()
                                Text("\(item.remainingSeconds) 秒")
                                    .companionFont(size: 11, design: .monospaced)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.replyText)
                                .companionFont(size: 12)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let reason = item.manualOnlyReason {
                                Text(reason)
                                    .companionFont(size: 11, weight: .medium)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CompanionRowPressStyle())
                .accessibilityLabel("查看 \(item.chatName) 的待确认回复")
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    Task {
                        busy = true
                        await onCancel()
                        busy = false
                    }
                } label: {
                    Text(busy ? "正在取消…" : "取消")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .help(busy ? "正在取消即将发送的回复" : "")
                .accessibilityHint(busy ? "正在取消即将发送的回复" : "")
                Button { error = nil; showConfirm = true } label: {
                    Text(busy ? "正在发送…" : "立即发送")
                }
                .tint(CompanionPalette.jade)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busy)
                .help(busy ? "正在发送" : "")
                .accessibilityHint(busy ? "正在发送" : "")
            }
            if let error {
                Text(error)
                    .companionFont(size: 11)
                    .foregroundStyle(.orange)
                    .transition(.companionStatusReveal)
            }
        }
        .padding(showsActionsOnly ? 0 : 10)
        .background(
            showsActionsOnly
                ? Color.clear
                : (isSelected ? CompanionPalette.selectedFill : CompanionPalette.secondarySurface),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .companionAnimation(CompanionMotion.ease(), value: error)
        .companionDialogBackdrop(showConfirm) {
            if showConfirm {
                CompanionDialog(title: CompanionProductCopy.sendConfirmTitle, onClose: { if !busy { showConfirm = false } }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.sendConfirmMessage(name: item.chatName, text: item.replyText))
                            .companionFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error {
                            Text(error)
                                .companionFont(size: 13)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.companionStatusReveal)
                        }
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.sendConfirmBack) { showConfirm = false }
                                .companionBusyHold(busy, "正在发送")
                            Button {
                                Task {
                                    busy = true
                                    error = await onSendNow()
                                    busy = false
                                    if error == nil { showConfirm = false }
                                }
                            } label: {
                                Text(busy ? "正在发送…" : CompanionProductCopy.sendConfirmAction)
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                            .help(busy ? "正在发送" : "")
                            .accessibilityHint(busy ? "正在发送" : "")
                        }
                    }
                    .companionAnimation(CompanionMotion.ease(), value: error)
                }
            }
        }
    }
}
