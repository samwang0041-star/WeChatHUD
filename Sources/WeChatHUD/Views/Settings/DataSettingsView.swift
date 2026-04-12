import SwiftUI

/// Data management: recalled messages, commitment tracking, pending asks.
struct DataSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor

    @State private var selectedSection: DataSection = .recalls
    @State private var exportMessage: String?
    @State private var recalledMessages: [RecalledMessage] = []
    @State private var commitments: [Commitment] = []
    @State private var pendingAsks: [PendingAsk] = []
    @State private var didLoad = false

    enum DataSection: String, CaseIterable {
        case recalls = "撤回记录"
        case commitments = "承诺追踪"
        case pendingAsks = "待决事项"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Export button
            HStack {
                Spacer()
                Button(action: {
                    if let url = monitor.exportReport() {
                        exportMessage = "已导出到 \(url.lastPathComponent)"
                    } else {
                        exportMessage = "导出失败"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportMessage = nil }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text("导出报告")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let msg = exportMessage {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Section picker
            Picker("", selection: $selectedSection) {
                ForEach(DataSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedSection) { reload() }

            switch selectedSection {
            case .recalls:
                recallsSection
            case .commitments:
                commitmentsSection
            case .pendingAsks:
                pendingAsksSection
            }
        }
        .onAppear {
            if !didLoad { reload(); didLoad = true }
        }
    }

    // MARK: - Recalls

    private var recallsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近被撤回的消息")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(recalledMessages.count) 条")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if recalledMessages.isEmpty {
                    emptyState("暂无撤回记录")
                } else {
                    ForEach(recalledMessages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(msg.senderRole.icon)
                                    .font(.system(size: 12))
                                Text(msg.senderName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(msg.chatName)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(msg.recallDelaySeconds)秒后撤回")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange.opacity(0.7))
                                Text(MessageInfo.formatRelative(msg.recalledAt))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Text("「\(msg.originalText)」")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)

                            // AI analysis if available
                            if let reason = msg.aiReason {
                                HStack(spacing: 6) {
                                    aiPill(reason, color: msg.aiIntelligenceValue == "high" ? .red : .gray)
                                    if let detail = msg.aiDetail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Commitments

    private var commitmentsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("你的未完成承诺")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    let overdue = commitments.filter {
                        $0.status == .pending && $0.deadlineAt != nil && $0.deadlineAt! < Date()
                    }.count
                    if overdue > 0 {
                        Text("\(overdue) 已超期")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.red)
                    }
                }

                if commitments.isEmpty {
                    emptyState("暂无承诺记录")
                } else {
                    ForEach(commitments) { item in
                        HStack(spacing: 8) {
                            // Status indicator
                            Circle()
                                .fill(commitmentColor(item))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.content)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                HStack(spacing: 6) {
                                    Text("→ \(item.commitTo)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    if let deadline = item.deadlineAt {
                                        Text(deadline < Date() ? "已超期" : "截止 \(MessageInfo.formatRelative(Int(deadline.timeIntervalSince1970)))")
                                            .font(.system(size: 10))
                                            .foregroundColor(deadline < Date() ? .red : .secondary)
                                    }
                                }
                            }

                            Spacer()

                            if item.status == .pending {
                                Button("已完成") {
                                    try? store.updateCommitmentStatus(msgUID: item.msgUID, status: .fulfilled)
                                    reload()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.green)

                                Button("取消") {
                                    try? store.updateCommitmentStatus(msgUID: item.msgUID, status: .cancelled)
                                    reload()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            } else {
                                Text(item.status.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Pending Asks

    private var pendingAsksSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI 识别的待决事项")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    let pending = pendingAsks.filter { $0.status == .pending }.count
                    Text("\(pending) 待处理")
                        .font(.system(size: 10))
                        .foregroundColor(pending > 0 ? .orange : .secondary)
                }

                if pendingAsks.isEmpty {
                    emptyState("暂无待决事项")
                } else {
                    ForEach(pendingAsks) { ask in
                        HStack(spacing: 8) {
                            // Urgency indicator
                            Circle()
                                .fill(urgencyColor(ask))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if let role = ask.senderRole {
                                        Text(role.icon)
                                            .font(.system(size: 10))
                                    }
                                    Text(ask.senderName)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text(ask.chatName)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Text(ask.summary)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    aiPill(ask.askType.label, color: .blue)
                                    Text(String(format: "%.0f%%", ask.confidence * 100))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(MessageInfo.formatRelative(Int(ask.createdAt.timeIntervalSince1970)))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if ask.status == .pending {
                                Button("已处理") {
                                    try? store.updatePendingAskStatus(msgUID: ask.msgUID, status: .done)
                                    reload()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.green)

                                Button("忽略") {
                                    try? store.dismissPendingAsk(msgUID: ask.msgUID)
                                    reload()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            } else {
                                Text(ask.status.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func emptyState(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 20)
            Spacer()
        }
    }

    private func aiPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func commitmentColor(_ item: Commitment) -> Color {
        switch item.status {
        case .pending:
            if let d = item.deadlineAt, d < Date() { return .red }
            return .orange
        case .fulfilled: return .green
        case .overdue: return .red
        case .cancelled: return .gray
        }
    }

    private func urgencyColor(_ ask: PendingAsk) -> Color {
        switch ask.urgency {
        case .urgent: return .red
        case .timely: return .orange
        case .routine: return .blue
        case .none: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func reload() {
        switch selectedSection {
        case .recalls:
            recalledMessages = store.loadRecalledMessages(since: 0, limit: 50)
        case .commitments:
            let pending = store.loadCommitments(status: .pending)
            let fulfilled = store.loadCommitments(status: .fulfilled)
            commitments = pending + fulfilled
        case .pendingAsks:
            let main = store.loadPendingAsks(bucket: .main, status: .pending)
            let review = store.loadPendingAsks(bucket: .review, status: .pending)
            let done = store.loadPendingAsks(bucket: .main, status: .done)
            pendingAsks = main + review + done.prefix(10)
        }
    }
}
