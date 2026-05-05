import SwiftUI
import AppKit

/// 承诺 tab — track promises the user made and their fulfillment state.
struct CommitmentTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var filter: CommitmentFilter = .active
    @State private var query = ""

    enum CommitmentFilter: String, CaseIterable {
        case active = "进行中"
        case overdue = "超期"
        case fulfilled = "已完成"
        case all = "全部"
    }

    private var summary: CommitmentSummary {
        CommitmentSummary(commitments: monitor.commitments)
    }

    private var filteredCommitments: [Commitment] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitor.commitments
            .filter { commitment in
                switch filter {
                case .active:
                    return commitment.status == .pending || commitment.status == .overdue
                case .overdue:
                    return commitment.status == .overdue
                case .fulfilled:
                    return commitment.status == .fulfilled
                case .all:
                    return true
                }
            }
            .filter { commitment in
                guard !normalizedQuery.isEmpty else { return true }
                return [
                    commitment.content,
                    commitment.chatName,
                    commitment.commitTo,
                    commitment.sourceText,
                    commitment.contextText,
                    commitment.captureReason,
                    commitment.nextStep
                ].contains { $0.lowercased().contains(normalizedQuery) }
            }
            .sorted(by: commitmentSort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if filteredCommitments.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredCommitments) { commitment in
                            CommitmentActionRow(commitment: commitment)
                                .environmentObject(monitor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索承诺、原话、背景、群聊或对象", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 12)

                Text("\(summary.active) 进行中")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(summary.overdue > 0 ? .red : .orange)
                    .monospacedDigit()
                Text("\(summary.fulfilled) 已完成 · \(summary.cancelled) 已取消")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    ForEach(CommitmentFilter.allCases, id: \.self) { item in
                        Text(filterTitle(item)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .controlSize(.small)

                Spacer()

                CommitmentMetricPill(label: "超期", count: summary.overdue, color: .red)
                CommitmentMetricPill(label: "今天", count: summary.dueToday, color: .orange)
                CommitmentMetricPill(label: "无期限", count: summary.noDeadline, color: .secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                Text("出现条件：你自己发出的消息 + 上下文有明确任务/请求/安排 + AI 置信度 ≥ 72%。纯“收到/好的”只有在上文明确让你执行时才收录。")
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyIcon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            if !query.isEmpty {
                Text("换个关键词试试")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 36)
    }

    private var emptyIcon: String {
        if !query.isEmpty { return "magnifyingglass" }
        switch filter {
        case .active: return "checkmark.seal"
        case .overdue: return "clock.badge.checkmark"
        case .fulfilled: return "tray"
        case .all: return "tray"
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "没有匹配的承诺" }
        switch filter {
        case .active: return "没有进行中的承诺"
        case .overdue: return "没有超期承诺"
        case .fulfilled: return "还没有已完成记录"
        case .all: return "暂无承诺记录"
        }
    }

    private func filterTitle(_ filter: CommitmentFilter) -> String {
        switch filter {
        case .active: return "进行中 \(summary.active)"
        case .overdue: return "超期 \(summary.overdue)"
        case .fulfilled: return "已完成 \(summary.fulfilled)"
        case .all: return "全部 \(summary.total)"
        }
    }

    private func commitmentSort(_ lhs: Commitment, _ rhs: Commitment) -> Bool {
        let leftRank = statusRank(lhs.status)
        let rightRank = statusRank(rhs.status)
        if leftRank != rightRank { return leftRank < rightRank }

        let leftDeadline = lhs.deadlineAt ?? Date.distantFuture
        let rightDeadline = rhs.deadlineAt ?? Date.distantFuture
        if leftDeadline != rightDeadline { return leftDeadline < rightDeadline }

        return lhs.createdAt > rhs.createdAt
    }

    private func statusRank(_ status: CommitmentStatus) -> Int {
        switch status {
        case .overdue:   return 0
        case .pending:   return 1
        case .fulfilled: return 2
        case .cancelled: return 3
        }
    }
}

private struct CommitmentActionRow: View {
    @EnvironmentObject var monitor: ChatMonitor

    let commitment: Commitment

    @State private var hovered = false
    @State private var actionError: String?

    private var isActive: Bool {
        commitment.status == .pending || commitment.status == .overdue
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 30, height: 30)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(commitment.content.isEmpty ? "未命名承诺" : commitment.content)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(contentStyle)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    statusPill
                }

                HStack(spacing: 6) {
                    metadataPill(systemImage: "bubble.left.and.bubble.right", text: commitment.chatName)
                    if !commitment.commitTo.isEmpty {
                        metadataPill(systemImage: "arrow.right", text: commitment.commitTo)
                    }
                    if !commitment.commitmentKind.isEmpty {
                        metadataPill(systemImage: "tag", text: kindLabel(commitment.commitmentKind))
                    }
                    metadataPill(systemImage: "calendar", text: createdText(commitment.createdAt))
                    metadataPill(systemImage: "waveform.path.ecg", text: "\(Int(commitment.confidence * 100))%")
                }

                timelineLine

                if !bestNextStep.isEmpty {
                    detailBlock(
                        systemImage: "arrow.forward.circle",
                        label: "下一步",
                        text: bestNextStep,
                        accent: isActive ? .blue : .secondary
                    )
                }

                detailGrid

                if let actionError {
                    Text(actionError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            actionButtons
        }
        .padding(10)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(rowStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { contextMenuContent }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isActive {
                Button {
                    updateStatus(.fulfilled)
                } label: {
                    Label("完成", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .help("标记完成")

                Button {
                    updateStatus(.cancelled)
                } label: {
                    Label("取消", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("取消承诺")
            } else {
                Button {
                    updateStatus(.pending)
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("恢复为进行中")
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            WeChatLauncher.openChat(named: commitment.chatName)
        } label: {
            Label("在微信中打开", systemImage: "bubble.left.and.bubble.right")
        }

        Button {
            copy(commitment.content)
        } label: {
            Label("复制承诺内容", systemImage: "doc.on.doc")
        }

        if !bestNextStep.isEmpty {
            Button {
                copy(bestNextStep)
            } label: {
                Label("复制下一步", systemImage: "arrow.forward.circle")
            }
        }

        if !commitment.sourceText.isEmpty {
            Button {
                copy(commitment.sourceText)
            } label: {
                Label("复制当时原话", systemImage: "quote.bubble")
            }
        }

        Divider()

        if isActive {
            Button {
                updateStatus(.fulfilled)
            } label: {
                Label("标记完成", systemImage: "checkmark")
            }

            Button(role: .destructive) {
                updateStatus(.cancelled)
            } label: {
                Label("取消承诺", systemImage: "xmark")
            }
        } else {
            Button {
                updateStatus(.pending)
            } label: {
                Label("恢复为进行中", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var statusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(statusColor.opacity(commitment.status == .cancelled ? 0.16 : 0.86))
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(commitment.status == .cancelled ? Color.secondary : Color.white)
        }
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private func metadataPill(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(text.isEmpty ? "未知" : text)
                .lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
    }

    private var timelineLine: some View {
        HStack(spacing: 8) {
            Label(ageText(commitment.createdAt), systemImage: "clock.arrow.circlepath")
            Text("·")
            if let deadline = commitment.deadlineAt {
                Text(deadlineText(deadline))
                    .foregroundStyle(deadlineStyle(deadline))
                    .monospacedDigit()
            } else {
                Text(commitment.deadlineLabel.isEmpty ? "无明确截止时间" : commitment.deadlineLabel)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var detailGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !commitment.contextText.isEmpty {
                detailBlock(systemImage: "text.bubble", label: "当时背景", text: commitment.contextText, accent: .secondary)
            }
            if !commitment.sourceText.isEmpty {
                detailBlock(systemImage: "quote.bubble", label: "你当时说", text: commitment.sourceText, accent: .secondary)
            }
            if !commitment.captureReason.isEmpty {
                detailBlock(systemImage: "checkmark.seal", label: "为什么出现", text: commitment.captureReason, accent: .secondary)
            } else if commitment.contextText.isEmpty && commitment.sourceText.isEmpty {
                detailBlock(
                    systemImage: "exclamationmark.circle",
                    label: "旧记录",
                    text: "这条承诺来自旧版本，缺少原话和上下文；打开微信可复盘原始聊天。",
                    accent: .orange
                )
            }
        }
    }

    private func detailBlock(systemImage: String, label: String, text: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(label == "下一步" && isActive ? .primary : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(label == "下一步" && isActive ? 0.055 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var bestNextStep: String {
        if !commitment.nextStep.isEmpty { return commitment.nextStep }
        if !commitment.content.isEmpty { return "推进：\(commitment.content)" }
        return ""
    }

    private var rowBackground: Color {
        if commitment.status == .overdue {
            return Color.red.opacity(hovered ? 0.10 : 0.06)
        }
        return hovered ? Color.primary.opacity(0.045) : Color(nsColor: .controlBackgroundColor).opacity(0.38)
    }

    private var rowStroke: Color {
        if commitment.status == .overdue {
            return Color.red.opacity(0.25)
        }
        return Color(nsColor: .separatorColor).opacity(hovered ? 0.55 : 0.28)
    }

    private var contentStyle: Color {
        switch commitment.status {
        case .overdue:   return .red
        case .cancelled: return .secondary
        default:         return .primary
        }
    }

    private var statusColor: Color {
        switch commitment.status {
        case .overdue:   return .red
        case .pending:   return .orange
        case .fulfilled: return .green
        case .cancelled: return .secondary
        }
    }

    private var statusSymbol: String {
        switch commitment.status {
        case .overdue:   return "exclamationmark"
        case .pending:   return "clock"
        case .fulfilled: return "checkmark"
        case .cancelled: return "minus"
        }
    }

    private var statusLabel: String {
        switch commitment.status {
        case .overdue:   return "超期"
        case .pending:   return "进行中"
        case .fulfilled: return "已完成"
        case .cancelled: return "已取消"
        }
    }

    private func kindLabel(_ raw: String) -> String {
        switch raw {
        case "deliverable": return "交付物"
        case "followup": return "跟进"
        case "coordination": return "协调"
        case "decision": return "决策"
        case "schedule": return "安排"
        default: return "承诺"
        }
    }

    private func updateStatus(_ status: CommitmentStatus) {
        do {
            try monitor.updateCommitmentStatus(msgUID: commitment.msgUID, status: status)
            actionError = nil
        } catch {
            actionError = "状态更新失败"
        }
    }

    private func deadlineText(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff < 0 {
            let past = Int(-diff)
            if past < 3600  { return "超期 \(max(1, past / 60)) 分钟" }
            if past < 86400 { return "超期 \(max(1, past / 3600)) 小时" }
            return "超期 \(past / 86400) 天"
        }
        if diff < 3600  { return "\(max(1, Int(diff) / 60)) 分钟后到期" }
        if diff < 86400 { return "\(Int(diff) / 3600) 小时后到期" }
        if diff < 172800 { return "明天到期" }
        return "\(Int(diff) / 86400) 天后到期"
    }

    private func deadlineStyle(_ date: Date) -> Color {
        let diff = date.timeIntervalSince(Date())
        if diff < 0 { return .red }
        if diff < 24 * 3600 { return .orange }
        return .secondary
    }

    private func createdText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func ageText(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 3600 { return "\(max(1, seconds / 60)) 分钟前答应" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前答应" }
        if seconds < 604800 { return "\(seconds / 86400) 天前答应" }
        return createdText(date) + " 答应"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CommitmentMetricPill: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(count > 0 ? color : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((count > 0 ? color : Color.secondary).opacity(0.10))
        .clipShape(Capsule())
    }
}

private struct CommitmentSummary {
    let total: Int
    let pending: Int
    let overdue: Int
    let fulfilled: Int
    let cancelled: Int
    let dueToday: Int
    let noDeadline: Int

    var active: Int { pending + overdue }

    init(commitments: [Commitment]) {
        total = commitments.count
        pending = commitments.filter { $0.status == .pending }.count
        overdue = commitments.filter { $0.status == .overdue }.count
        fulfilled = commitments.filter { $0.status == .fulfilled }.count
        cancelled = commitments.filter { $0.status == .cancelled }.count

        let now = Date()
        let endOfDay = Calendar.current.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(24 * 3600)
        dueToday = commitments.filter {
            guard ($0.status == .pending || $0.status == .overdue), let deadline = $0.deadlineAt else {
                return false
            }
            return deadline <= endOfDay
        }.count
        noDeadline = commitments.filter {
            ($0.status == .pending || $0.status == .overdue) && $0.deadlineAt == nil
        }.count
    }
}
