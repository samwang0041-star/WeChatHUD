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

    static func statusSentence(active: Bool, paused: Bool, autoSendOn: Bool) -> String {
        let run: String
        if !active {
            run = "尚未开始整理"
        } else if paused {
            run = "已暂停"
        } else {
            run = "正在整理"
        }
        let send = autoSendOn ? "自动发送开启" : "自动发送关闭"
        return "\(run) · \(send)"
    }
}

enum ApprovalCopy {
    static let confirmSend = "确认发送"
    static let saveDraft = "保存修改"
    static let cancelItem = "取消本条"
    static let pause = "暂停"
    static let resume = "恢复"
    static let emptyPending = "还没有待确认的回复"
    static let emptyOther = "这一栏还没有记录"
    static let emptyHint = "点开始整理，草稿会出现在这里。发不发都由你决定。"
    static let reply = "回复"
    static let openChat = "查看聊天记录"
    static let sendNow = "立即发送"
    static let dismissSend = "取消"
    static let cancelledSend = "这条不发了。"
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

    private var autoSendOn: Bool {
        (store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).autoSendEnabled
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
                    .workspaceRowTitle()
                    .foregroundStyle(receipt.contains("失败") ? .orange : CompanionPalette.jade)
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
                            .workspaceBody()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button(CompanionProductCopy.sendConfirmBack) { showSendConfirm = false }
                            Button(CompanionProductCopy.sendConfirmAction) {
                                showSendConfirm = false
                                Task { await confirmSend() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(CompanionPalette.jade)
                            .disabled(isSending)
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { value in
                    let count = value == .pending ? pendingCount : nil
                    CompanionFilterPill(
                        title: count.map { "\(value.rawValue) \($0)" } ?? value.rawValue,
                        selected: filter == value
                    ) { filter = value }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Text(ApprovalWorkspacePolicy.statusSentence(
                    active: monitor.autopilotActive,
                    paused: monitor.autopilotManuallyPaused,
                    autoSendOn: autoSendOn
                ))
                .workspaceMeta()
                .foregroundStyle(.secondary)
                Spacer()
                if monitor.autopilotActive {
                    Button(monitor.autopilotManuallyPaused ? ApprovalCopy.resume : ApprovalCopy.pause) {
                        Task {
                            if monitor.autopilotManuallyPaused {
                                await monitor.autopilotService?.manualResume()
                            } else {
                                await monitor.autopilotService?.manualPause()
                            }
                        }
                    }
                    .workspaceMeta()
                    .buttonStyle(CompanionPressStyle())
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(filter == .pending ? ApprovalCopy.emptyPending : ApprovalCopy.emptyOther)
                .workspaceTitle()
            Text(ApprovalCopy.emptyHint)
                .workspaceBody()
                .foregroundStyle(.secondary)
            if showsSessionToggle && filter == .pending && !monitor.autopilotActive {
                Button(AutopilotStartCopy.start) { monitor.toggleAutopilot() }
                    .buttonStyle(.borderedProminent)
                    .tint(CompanionPalette.jade)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !humanNeededSends.isEmpty {
                    HStack {
                        Text(autoSendOn ? "需人工确认" : "即将发送")
                            .workspaceRowTitle()
                        Text("\(humanNeededSends.count)")
                            .workspaceMeta()
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
                                    Text(entry.senderName).workspaceRowTitle()
                                    Spacer()
                                    Text(CommitmentPresentation.timeLabel(entry.createdAt))
                                        .workspaceMeta().foregroundStyle(.secondary)
                                }
                                statusLabel(entry)
                                Text(entry.triggerText)
                                    .workspaceBody()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(10)
                        .background(selected?.id == entry.id ? CompanionPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(CompanionPressStyle())
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
                .workspaceMeta()
                .foregroundStyle(.orange)
        } else {
            Text(entry.action == .pending ? "待确认回复" : actionTitle(entry.action))
                .workspaceMeta()
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
                        Text("收件人 \(selected.senderName) · \(selected.chatUsername.contains("@chatroom") ? "群聊" : "私聊")")
                            .workspaceBody()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ApprovalCopy.openChat) {
                        panelState.showChatDetail(chatUsername: selected.chatUsername, chatName: selected.chatName)
                    }
                    .workspaceMeta()
                    .buttonStyle(CompanionPressStyle())
                    .foregroundStyle(CompanionPalette.jade)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.triggerText)
                        .workspaceBody()
                    Text(CommitmentPresentation.timeLabel(selected.createdAt))
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(ApprovalCopy.reply)
                        .workspaceRowTitle()
                    TextEditor(text: $editedReply)
                        .accessibilityLabel(ApprovalCopy.reply)
                        .workspaceBody()
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                    HStack {
                        if !autoSendOn {
                            Label("当前未开启自动发送，这条回复尚未发出。", systemImage: "info.circle")
                                .workspaceBody()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(editedReply.count) / 500")
                            .workspaceMeta()
                            .foregroundStyle(.secondary)
                    }
                }

                if selected.action == .pending {
                    HStack(spacing: 12) {
                        Button(ApprovalCopy.confirmSend) { showSendConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .tint(CompanionPalette.jade)
                            .disabled(editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                        Button(ApprovalCopy.saveDraft) {
                            do {
                                try monitor.saveAutopilotDraft(logId: selected.id, reply: editedReply)
                                receipt = "已保存草稿"
                            } catch {
                                receipt = "草稿没有保存，请重试。"
                            }
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(.secondary)
                        Button(ApprovalCopy.cancelItem) {
                            monitor.rejectAutopilotItem(logId: selected.id)
                            receipt = "已取消本条，现有草稿仍保留。"
                        }
                        .buttonStyle(CompanionPressStyle())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.vertical, 12)
        } else if !humanNeededSends.isEmpty {
            Text(autoSendOn ? "这些回复需要你确认后再发" : "自动发送已关，在左侧发送或取消。")
                .workspaceBody()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
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
        let ok = await monitor.approveAutopilotItem(
            logId: selected.id,
            reply: editedReply,
            chatName: selected.chatName,
            chatUsername: selected.chatUsername
        )
        receipt = ok
            ? CompanionProductCopy.sendSuccess(name: selected.chatName)
            : CompanionProductCopy.sendUncertain
    }

    private func sendPendingNow(_ item: PendingSend) async -> String? {
        let outcome = await monitor.sendAutopilotNow(id: item.id, config: monitor.loadAutopilotConfig())
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
        receipt = ApprovalCopy.cancelledSend
    }
}

private struct ApprovalPendingSendRow: View {
    let item: PendingSend
    let onSendNow: () async -> String?
    let onCancel: () async -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CompanionAvatar(name: item.senderName, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.chatName).workspaceRowTitle()
                        Spacer()
                        Text("\(item.remainingSeconds)s")
                            .workspaceMeta()
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(item.replyText)
                        .workspaceBody()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let reason = item.manualOnlyReason {
                        Text(reason)
                            .workspaceMeta()
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(ApprovalCopy.dismissSend) {
                    Task {
                        busy = true
                        await onCancel()
                        busy = false
                    }
                }
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .disabled(busy)
                Button(ApprovalCopy.sendNow) {
                    Task {
                        busy = true
                        error = await onSendNow()
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CompanionPalette.jade)
                .disabled(busy)
            }
            if let error {
                Text(error)
                    .workspaceMeta()
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(CompanionPalette.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
