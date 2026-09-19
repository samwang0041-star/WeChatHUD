import SwiftUI

/// Shared filter so the approval surface and AutopilotTabView cannot disagree
/// about which pending sends still need a human.
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
        case failed = "失败"
        case all = "全部"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .pending
    @State private var selectedID: Int64?
    @State private var editedReply: String = ""
    @State private var receipt: String?
    @State private var showSendConfirm = false
    @State private var isSending = false

    private var entries: [AutopilotLogEntry] {
        switch filter {
        case .pending: return monitor.autopilotLog.filter { $0.action == .pending }
        case .sent: return monitor.autopilotLog.filter { $0.action == .sent || $0.action == .vipNotified }
        case .failed: return monitor.autopilotLog.filter { $0.action == .failed }
        case .all: return monitor.autopilotLog
        }
    }

    private var selected: AutopilotLogEntry? {
        entries.first(where: { $0.id == selectedID }) ?? entries.first
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
                Label(receipt, systemImage: receipt.contains("失败") ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(receipt.contains("失败") ? .orange : CompanionPalette.jadeInk)
                    .padding(.top, 10)
            }
        }
        .onAppear { selectedID = selected?.id; syncEditor() }
        .onChange(of: selected?.id) { _, _ in syncEditor() }
        .onChange(of: entries.count) { _, _ in reconcileSelection() }
        .onChange(of: filter) { _, _ in reconcileSelection() }
        .companionDialogBackdrop(showSendConfirm) {
            if showSendConfirm {
                CompanionDialog(title: CompanionProductCopy.sendConfirmTitle, onClose: { showSendConfirm = false }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.sendConfirmMessage(name: selected?.chatName ?? "", text: editedReply))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.sendConfirmBack) { showSendConfirm = false }
                            Button(CompanionProductCopy.sendConfirmAction) {
                                showSendConfirm = false
                                Task { await confirmSend() }
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(isSending)
                        }
                    }
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
                    Text(monitor.autopilotActive ? "正在整理" : "尚未开始整理")
                    Text("·")
                    Text(autoSendToolbarText)
                    if monitor.autopilotActive {
                        Button(monitor.autopilotManuallyPaused ? "恢复" : "暂停") {
                            Task {
                                if monitor.autopilotManuallyPaused {
                                    await monitor.autopilotService?.manualResume()
                                } else {
                                    await monitor.autopilotService?.manualPause()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if showsSessionToggle {
                        Button("开始整理") { monitor.toggleAutopilot() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .font(.system(size: 12))
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
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !humanNeededSends.isEmpty {
                    HStack {
                        Text(autoSendOn ? "需人工确认" : "等你确认")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(humanNeededSends.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 2)
                    ForEach(humanNeededSends) { item in
                        ApprovalPendingSendRow(
                            item: item,
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
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            CompanionAvatar(name: entry.senderName, size: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.senderName).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(CommitmentPresentation.timeLabel(entry.createdAt))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                statusLabel(entry)
                                Text(entry.triggerText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(10)
                        .background(selected?.id == entry.id ? CompanionPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            Text(entry.action == .pending ? "待确认回复" : actionTitle(entry.action))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func actionTitle(_ action: AutopilotAction) -> String {
        switch action {
        case .sent, .vipNotified: return "已发送"
        case .failed: return "发送失败"
        case .pending: return "待确认回复"
        default: return "已记录"
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.chatName).workspaceTitle()
                        Text("收件人 \(selected.senderName) · \(MessageHelpers.isGroupChat(selected.chatUsername) ? "群聊" : "私聊")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看聊天记录") {
                        panelState.showChatDetail(chatUsername: selected.chatUsername, chatName: selected.chatName)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.jadeInk)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.triggerText)
                        .font(.system(size: 14))
                    Text(CommitmentPresentation.timeLabel(selected.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("拟回复", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                        CompanionBadge(title: "AI 草稿", systemImage: "text.badge.star")
                    }
                    TextEditor(text: $editedReply)
                        .accessibilityLabel("拟回复")
                        .font(.system(size: 14))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                    HStack {
                        if !autoSendOn {
                            Label(autoSendState == nil
                                ? "暂时读不到自动发送设置，这条是否已经发出请在微信里核对。"
                                : "当前未开启自动发送，这条回复尚未发出。", systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(replyLengthHint)
                            .font(.system(size: 11))
                            .foregroundStyle(replyOverSuggestedLength ? Color.red : Color.secondary)
                    }
                }

               if selected.action == .pending {
                   HStack(spacing: 8) {
                       Button("确认发送") { showSendConfirm = true }
                           .tint(SettingsView.Tab.autopilotDashboard.accentColor)
                           .buttonStyle(.borderedProminent)
                           .disabled(editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                       Button("保存修改") {
                            Task {
                                do {
                                    try await monitor.saveAutopilotDraft(logId: selected.id, reply: editedReply)
                                    receipt = "已保存草稿"
                                } catch {
                                    receipt = "草稿没有保存，请重试。"
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        Button("取消本条") {
                            monitor.rejectAutopilotItem(
                                logId: selected.id,
                                chatUsername: selected.chatUsername,
                                replyText: selected.generatedReply
                            )
                            receipt = "已取消本条，对应的待发草稿已一并移除。"
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.vertical, 12)
        } else if !humanNeededSends.isEmpty {
            ContentUnavailableView(
                autoSendOn ? "这些回复需要你确认后再发" : (autoSendState == nil ? "暂时读不到自动发送设置，先别假定这些已经发出" : "自动发送已关，这些都要你点一下才会发出去"),
                systemImage: "paperplane",
                description: Text("立即发送或取消都可以在左侧完成。草稿仍在待确认列表里。")
            )
        }
    }

    private func reconcileSelection() {
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        selectedID = entries.first?.id
    }

    private func syncEditor() {
        editedReply = selected?.generatedReply ?? ""
    }

    private func confirmSend() async {
        guard let selected, !isSending else { return }
        isSending = true
        defer { isSending = false }
        // 「什么都没敲」 and 「敲了但没在数据库里确认」 are different answers, and
        // the old `false` printed the second one for both: confirming a reply in
        // a muted conversation told the user to go check WeChat for a message
        // that had never been typed. The mute list is the one place that fact is
        // read, so this cannot drift from what 取消静音 offers.
        if monitor.silencedConversations.contains(where: { $0.username == selected.chatUsername }) {
            receipt = "这个对话已静音，这条没有发出。请先在「已静音的对话」里取消静音，再确认发送。"
            return
        }
        let ok = await monitor.approveAutopilotItem(
            logId: selected.id,
            reply: editedReply,
            chatName: selected.chatName,
            chatUsername: selected.chatUsername,
            createdAt: selected.createdAt
        )
        receipt = ok
            ? CompanionProductCopy.sendSuccess(name: selected.chatName)
            : CompanionProductCopy.sendUncertain
    }

    private func sendPendingNow(_ item: PendingSend) async -> String? {
        guard let config = monitor.loadAutopilotConfig() else {
            return ChatMonitor.unreadableConfigNotice
        }
        let outcome = await monitor.sendAutopilotNow(id: item.id, config: config)
        await monitor.syncAutopilotPendingQueue()
        switch outcome {
        case .sent:
            receipt = CompanionProductCopy.sendSuccess(name: item.chatName)
            return nil
        case .blocked(let reason):
            return reason
        case .notFound:
            return "队列项已不存在"
        }
    }

    private func cancelPending(_ item: PendingSend) async {
        await monitor.autopilotService?.cancelPendingSend(id: item.id)
        await monitor.syncAutopilotPendingQueue()
        receipt = "已取消即将发送的回复"
    }
}

private struct ApprovalPendingSendRow: View {
    let item: PendingSend
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
            HStack(alignment: .top, spacing: 10) {
                CompanionAvatar(name: item.senderName, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.chatName).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(item.remainingSeconds)s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.replyText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let reason = item.manualOnlyReason {
                        Text(reason)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    Task {
                        busy = true
                        await onCancel()
                        busy = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                Button("立即发送") { showConfirm = true }
                .tint(CompanionPalette.jade)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busy)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .companionDialogBackdrop(showConfirm) {
            if showConfirm {
                CompanionDialog(title: CompanionProductCopy.sendConfirmTitle, onClose: { showConfirm = false }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(CompanionProductCopy.sendConfirmMessage(name: item.chatName, text: item.replyText))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.sendConfirmBack) { showConfirm = false }
                            Button(CompanionProductCopy.sendConfirmAction) {
                                showConfirm = false
                                Task {
                                    busy = true
                                    error = await onSendNow()
                                    busy = false
                                }
                            }
                            .tint(CompanionPalette.jade)
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                        }
                    }
                }
            }
        }
    }
}
