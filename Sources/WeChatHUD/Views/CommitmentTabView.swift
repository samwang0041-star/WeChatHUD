import SwiftUI

/// 承诺 tab — shows all commitments with actions (complete, snooze, cancel).
struct CommitmentTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var filter: CommitmentFilter = .pending

    enum CommitmentFilter: String, CaseIterable {
        case pending = "进行中"
        case all = "全部"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            if filteredCommitments.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredCommitments) { commitment in
                            CommitmentActionRow(commitment: commitment)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("🤝")
                .font(.system(size: 13))
            Text("我的承诺")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Picker("", selection: $filter) {
                ForEach(CommitmentFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 120)
            .controlSize(.small)

            Spacer()

            let pending = monitor.commitments.filter { $0.status == .pending }.count
            let overdue = monitor.commitments.filter { $0.status == .overdue }.count
            if overdue > 0 {
                Text("\(overdue) 超期")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.red)
            }
            if pending > 0 {
                Text("\(pending) 进行中")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filteredCommitments: [Commitment] {
        let sorted = monitor.commitments.sorted { a, b in
            statusRank(a.status) < statusRank(b.status)
        }
        switch filter {
        case .pending:
            return sorted.filter { $0.status == .pending || $0.status == .overdue }
        case .all:
            return sorted
        }
    }

    private func statusRank(_ status: CommitmentStatus) -> Int {
        switch status {
        case .overdue:   return 0
        case .pending:   return 1
        case .fulfilled: return 2
        case .cancelled: return 3
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(filter == .pending ? "没有进行中的承诺" : "暂无承诺记录")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            Text("当你在聊天中做出承诺时，AI 会自动追踪")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Commitment Action Row

private struct CommitmentActionRow: View {
    @EnvironmentObject var monitor: ChatMonitor
    let commitment: Commitment
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(commitment.content)
                        .font(.system(size: 11))
                        .foregroundColor(contentColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }

                HStack(spacing: 8) {
                    if !commitment.chatName.isEmpty {
                        Text(commitment.chatName)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    if !commitment.commitTo.isEmpty {
                        Text("→ \(commitment.commitTo)")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    if let deadline = commitment.deadlineAt {
                        Text(deadlineText(deadline))
                            .font(.system(size: 9))
                            .foregroundColor(deadlineColor(deadline))
                            .monospacedDigit()
                    }
                }
            }

            if commitment.status == .pending || commitment.status == .overdue {
                actionButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button {
                WeChatLauncher.openChat(named: commitment.chatName)
            } label: {
                Label("在微信中打开", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button(action: {
                try? monitor.updateCommitmentStatus(msgUID: commitment.msgUID, status: .fulfilled)
            }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                    .frame(width: 22, height: 22)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("标记完成")

            Button(action: {
                try? monitor.updateCommitmentStatus(msgUID: commitment.msgUID, status: .cancelled)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("取消承诺")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch commitment.status {
        case .overdue:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.8))
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
            }
        case .pending:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.7))
                Image(systemName: "clock").font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
            }
        case .fulfilled:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.7))
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
            }
        case .cancelled:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.15))
                Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private var contentColor: Color {
        switch commitment.status {
        case .overdue:   return .red.opacity(0.9)
        case .cancelled: return .white.opacity(0.35)
        default:         return .white.opacity(0.85)
        }
    }

    private var rowBackground: some View {
        if commitment.status == .overdue {
            return AnyView(Color.red.opacity(hovered ? 0.18 : 0.1))
        }
        return AnyView(hovered ? Color.white.opacity(0.06) : Color.clear)
    }

    private func deadlineText(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff < 0 {
            let past = Int(-diff)
            if past < 3600  { return "超期 \(past / 60)分" }
            if past < 86400 { return "超期 \(past / 3600)时" }
            return "超期 \(past / 86400)天"
        }
        if diff < 3600  { return "\(Int(diff) / 60)分后" }
        if diff < 86400 { return "\(Int(diff) / 3600)时后" }
        return "\(Int(diff) / 86400)天后"
    }

    private func deadlineColor(_ date: Date) -> Color {
        let diff = date.timeIntervalSince(Date())
        if diff < 0    { return .red.opacity(0.85) }
        if diff < 3600 { return .orange.opacity(0.9) }
        return .white.opacity(0.4)
    }
}
