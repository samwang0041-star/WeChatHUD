import SwiftUI

/// Catch-up mode: shows a prioritized summary of what happened while
/// the user was away. Three sections: needs action → important → low priority.
struct CatchupTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    @State private var hourWindow: Int = 3
    @State private var isLoading = false
    @State private var catchupResult: CatchupResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            if isLoading {
                loadingView
            } else if let result = catchupResult {
                resultView(result)
            } else {
                promptView
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("🕐")
                .font(.system(size: 13))
            Text("离开追赶")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Picker("", selection: $hourWindow) {
                Text("1小时").tag(1)
                Text("3小时").tag(3)
                Text("6小时").tag(6)
                Text("12小时").tag(12)
                Text("24小时").tag(24)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 90)
            .controlSize(.small)

            Spacer()

            Button(action: { Task { await loadCatchup() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text(catchupResult == nil ? "开始追赶" : "刷新")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.7))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(.circular)
            Text("正在分析过去 \(hourWindow) 小时的消息...")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Prompt (initial state)

    private var promptView: some View {
        VStack(spacing: 8) {
            Text("选择时间范围，点击「开始追赶」快速了解你离开期间的重要消息。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)

            let stats = gatherStats()
            if stats.total > 0 {
                HStack(spacing: 12) {
                    statPill("未读", count: stats.unread, color: .blue)
                    statPill("待回", count: stats.replyDebt, color: .orange)
                    statPill("承诺", count: stats.commitments, color: .purple)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 14)
    }

    private func statPill(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }

    // MARK: - Result view

    private func resultView(_ result: CatchupResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !result.needsAction.isEmpty {
                    sectionHeader("🔴 需要你处理", count: result.needsAction.count)
                    ForEach(result.needsAction) { item in
                        catchupRow(item, accent: .red)
                    }
                }

                if !result.important.isEmpty {
                    sectionHeader("📌 重要动态", count: result.important.count)
                    ForEach(result.important) { item in
                        catchupRow(item, accent: .orange)
                    }
                }

                if !result.lowPriority.isEmpty {
                    sectionHeader("💤 可以稍后看", count: result.lowPriority.count)
                    ForEach(result.lowPriority) { item in
                        catchupRow(item, accent: .gray)
                    }
                }

                if result.needsAction.isEmpty && result.important.isEmpty && result.lowPriority.isEmpty {
                    Text("过去 \(hourWindow) 小时没有需要关注的消息。")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(14)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func sectionHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func catchupRow(_ item: CatchupItem, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(accent.opacity(0.7))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.chatName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !item.senderName.isEmpty {
                        Text(item.senderName)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(relativeTime(item.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .monospacedDigit()
                }
                Text(item.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
            .padding(.vertical, 5)
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            WeChatLauncher.openChat(named: item.chatName)
        }
    }

    // MARK: - Data gathering

    private struct Stats {
        let unread: Int
        let replyDebt: Int
        let commitments: Int
        var total: Int { unread + replyDebt + commitments }
    }

    private func gatherStats() -> Stats {
        Stats(
            unread: monitor.unreadItems.count,
            replyDebt: monitor.replyDebtItems.count,
            commitments: monitor.commitments.filter { $0.status == .pending }.count
        )
    }

    private func loadCatchup() async {
        isLoading = true
        defer { isLoading = false }

        let cutoff = Date().addingTimeInterval(-Double(hourWindow) * 3600)
        var needsAction: [CatchupItem] = []
        var important: [CatchupItem] = []
        var lowPriority: [CatchupItem] = []

        // 1. Reply debt items → needs action (they need a reply)
        for item in monitor.replyDebtItems {
            needsAction.append(CatchupItem(
                id: "debt-\(item.chatUsername)",
                chatName: item.chatName,
                senderName: item.senderName,
                summary: "待回复: \(item.preview)",
                timestamp: item.timestamp,
                source: .replyDebt
            ))
        }

        // 2. Overdue unread → needs action
        for item in monitor.unreadItems where item.status == .overdue {
            needsAction.append(CatchupItem(
                id: "overdue-\(item.chatUsername)-\(item.senderUsername)",
                chatName: item.chatName,
                senderName: item.senderName,
                summary: item.preview,
                timestamp: item.timestamp,
                source: .unread
            ))
        }

        // 3. Pending commitments → needs action
        for c in monitor.commitments where c.status == .pending {
            needsAction.append(CatchupItem(
                id: "commit-\(c.msgUID)",
                chatName: c.chatName,
                senderName: "",
                summary: "你的承诺: \(c.content)",
                timestamp: c.createdAt,
                source: .commitment
            ))
        }

        // 4. VIP notifications within window → important
        for notif in monitor.recentNotifications where notif.isVIP && notif.timestamp >= cutoff {
            important.append(CatchupItem(
                id: "vip-\(notif.chatUsername)-\(notif.messageID)",
                chatName: notif.chatName,
                senderName: notif.senderName,
                summary: notif.snippet,
                timestamp: notif.timestamp,
                source: .vip
            ))
        }

        // 5. Pending unread → important (not overdue yet)
        for item in monitor.unreadItems where item.status == .pending {
            // Avoid duplicates with reply debt
            let isDuplicate = needsAction.contains { $0.chatName == item.chatName }
            if !isDuplicate {
                important.append(CatchupItem(
                    id: "pending-\(item.chatUsername)-\(item.senderUsername)",
                    chatName: item.chatName,
                    senderName: item.senderName,
                    summary: item.preview,
                    timestamp: item.timestamp,
                    source: .unread
                ))
            }
        }

        // 6. Non-VIP recent notifications within window → low priority
        for notif in monitor.recentNotifications where !notif.isVIP && notif.timestamp >= cutoff {
            let isDuplicate = (needsAction + important).contains { $0.chatName == notif.chatName }
            if !isDuplicate {
                lowPriority.append(CatchupItem(
                    id: "notif-\(notif.chatUsername)-\(notif.messageID)",
                    chatName: notif.chatName,
                    senderName: notif.senderName,
                    summary: notif.snippet,
                    timestamp: notif.timestamp,
                    source: .notification
                ))
            }
        }

        // Sort each section by timestamp (newest first)
        needsAction.sort { $0.timestamp > $1.timestamp }
        important.sort { $0.timestamp > $1.timestamp }
        lowPriority.sort { $0.timestamp > $1.timestamp }

        catchupResult = CatchupResult(
            needsAction: needsAction,
            important: important,
            lowPriority: lowPriority
        )
    }
}

// MARK: - Models

struct CatchupItem: Identifiable {
    let id: String
    let chatName: String
    let senderName: String
    let summary: String
    let timestamp: Date
    let source: CatchupSource
}

enum CatchupSource {
    case replyDebt
    case unread
    case commitment
    case vip
    case notification
}

struct CatchupResult {
    let needsAction: [CatchupItem]
    let important: [CatchupItem]
    let lowPriority: [CatchupItem]
}
