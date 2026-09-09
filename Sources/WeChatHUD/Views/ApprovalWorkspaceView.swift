import SwiftUI

/// 待确认回复 master-detail matching 不漏事 figure 07 / 40.
struct ApprovalWorkspaceView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore

    enum Filter: String, CaseIterable, Identifiable {
        case pending = "待确认"
        case sent = "已发送"
        case failed = "失败"
        case all = "全部"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .pending
    @State private var selectedUID: String?
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
        entries.first(where: { $0.triggerMsgUID == selectedUID }) ?? entries.first
    }

    private var pendingCount: Int {
        monitor.autopilotLog.filter { $0.action == .pending }.count
    }

    private var autoSendOn: Bool {
        (store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).autoSendEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                HSplitView {
                    listPane.frame(minWidth: 280, idealWidth: 340)
                    detailPane.frame(minWidth: 360, idealWidth: 460)
                }
            }
            if let receipt {
                Label(receipt, systemImage: receipt.contains("失败") ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(receipt.contains("失败") ? .orange : CompanionPalette.jade)
                    .padding(.top, 10)
            }
        }
        .onAppear { selectedUID = selected?.triggerMsgUID; syncEditor() }
        .onChange(of: selected?.triggerMsgUID) { _, _ in syncEditor() }
        .onChange(of: entries.map(\.triggerMsgUID)) { _, ids in
            if let selectedUID, ids.contains(selectedUID) { return }
            selectedUID = ids.first
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { value in
                    let count = value == .pending ? pendingCount : nil
                    CompanionFilterPill(
                        title: count.map { "\(value.rawValue) \($0)" } ?? value.rawValue,
                        selected: filter == value
                    ) { filter = value }
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: monitor.autopilotActive ? "arrow.triangle.2.circlepath" : "pause.circle")
                    Text(monitor.autopilotActive ? "正在整理" : "尚未开始整理")
                    Text("·")
                    Text(autoSendOn ? "自动发送开启" : "自动发送关闭")
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
                    } else {
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
            description: Text("点开始整理后，助理会写成草稿。发不发都由你决定。暂停不会删除现有草稿。")
        )
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(entries, id: \.triggerMsgUID) { entry in
                    Button {
                        selectedUID = entry.triggerMsgUID
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            CompanionAvatar(name: entry.senderName, size: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.senderName).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(entry.createdAt, format: .dateTime.hour().minute())
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
                        .background(selected?.triggerMsgUID == entry.triggerMsgUID ? CompanionPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        default: return action.rawValue
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.chatName).font(.system(size: 16, weight: .semibold))
                        Text("收件人 \(selected.senderName) · \(selected.chatUsername.contains("@chatroom") ? "群聊" : "私聊")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看聊天记录") {
                        panelState.showChatDetail(chatUsername: selected.chatUsername, chatName: selected.chatName)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.jade)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.triggerText)
                        .font(.system(size: 14))
                    Text(selected.createdAt, format: .dateTime.hour().minute())
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
                            Label("当前未开启自动发送，这条回复尚未发出。", systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(editedReply.count) / 500")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if selected.action == .pending {
                    HStack(spacing: 8) {
                        Button("确认发送") { showSendConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                        Button("保存修改") {
                            receipt = "已保存草稿"
                        }
                        .buttonStyle(.bordered)
                        Button("取消本条") {
                            monitor.rejectAutopilotItem(logId: selected.id)
                            receipt = "已取消本条，现有草稿仍保留。"
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.vertical, 12)
        }
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
}
