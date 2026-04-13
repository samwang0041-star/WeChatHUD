import SwiftUI

/// Autopilot tab in the extended pill — real-time activity feed,
/// pending review queue, session stats, and start/stop toggle.
struct AutopilotTabView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @State private var activityFilter: ActivityFilter = .all
    @State private var sessionStart: Date? = nil

    enum ActivityFilter: Hashable {
        case all, sent, pending, failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: toggle + stats ──
            headerBar
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

            // ── Paused banner ──
            if monitor.autopilotActive && (monitor.autopilotPaused || monitor.autopilotManuallyPaused) {
                pausedBanner
            }

            if !monitor.autopilotActive && monitor.autopilotLog.isEmpty {
                emptyState
            } else {
                // ── Sending queue (countdown) ──
                if !monitor.autopilotPendingSendQueue.isEmpty {
                    sectionHeader("即将发送", icon: "arrow.up.circle.fill", color: .cyan, count: monitor.autopilotPendingSendQueue.count)
                    ForEach(monitor.autopilotPendingSendQueue) { item in
                        PendingSendRow(item: item, monitor: monitor)
                    }
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                }

                // ── Session dashboard ──
                if monitor.autopilotActive {
                    sessionDashboard
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                }

                // ── Pending review queue ──
                let pending = monitor.autopilotLog.filter { $0.action == .pending }
                if !pending.isEmpty {
                    sectionHeader("待审核", icon: "exclamationmark.circle.fill", color: .orange, count: pending.count)
                    ForEach(pending, id: \.triggerMsgUID) { entry in
                        PendingReviewRow(entry: entry)
                    }
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                }

                // ── Activity feed with filter ──
                activitySection
            }
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Start/stop button
            Button(action: { monitor.toggleAutopilot() }) {
                HStack(spacing: 4) {
                    Image(systemName: monitor.autopilotActive ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(monitor.autopilotActive ? "停止" : "开始托管")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(monitor.autopilotActive ? .red : .green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((monitor.autopilotActive ? Color.red : Color.green).opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            if monitor.autopilotActive {
                // Pause/Resume button
                Button(action: {
                    Task {
                        if monitor.autopilotManuallyPaused {
                            await monitor.autopilotService?.manualResume()
                        } else {
                            await monitor.autopilotService?.manualPause()
                        }
                    }
                }) {
                    Image(systemName: monitor.autopilotManuallyPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundColor(monitor.autopilotManuallyPaused ? .green : .yellow)
                        .padding(3)
                        .background((monitor.autopilotManuallyPaused ? Color.green : Color.yellow).opacity(0.15))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)

                // Session stats
                HStack(spacing: 6) {
                    miniStat("✓", value: monitor.autopilotSessionSent, color: .green)
                    miniStat("⏳", value: monitor.autopilotSessionPending, color: .orange)
                }

                Spacer()

                // Session duration
                if let start = sessionStart {
                    Text(sessionDuration(since: start))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .monospacedDigit()
                }
            } else {
                Spacer()
            }
        }
        .onAppear {
            if monitor.autopilotActive && sessionStart == nil {
                sessionStart = Date()
            }
        }
        .onChange(of: monitor.autopilotActive) {
            sessionStart = monitor.autopilotActive ? Date() : nil
        }
    }

    private func miniStat(_ icon: String, value: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(icon).font(.system(size: 8))
            Text("\(value)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundColor(color)
    }

    private func sessionDuration(since start: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(start))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    // MARK: - Session dashboard

    private var sessionDashboard: some View {
        let stats = monitor.autopilotSessionStats
        return HStack(spacing: 12) {
            dashStat("发送", value: "\(stats.totalSent)", color: .green)
            dashStat("已读", value: "\(stats.totalReadNoReply)", color: .blue)
            dashStat("风格", value: "\(stats.avgStyleScore)", color: stats.avgStyleScore >= 70 ? .green : .orange)
            dashStat("延迟", value: "\(stats.avgDelay)s", color: .white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func dashStat(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Paused banner

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 10))
            Text(monitor.autopilotManuallyPaused ? "已手动暂停" : "已暂停 — 检测到你正在使用微信")
                .font(.system(size: 10))
            Spacer()
            Text(monitor.autopilotManuallyPaused ? "点击恢复按钮继续" : "离开微信后自动恢复")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .foregroundColor(.yellow)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "robot")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.2))
            Text("点击「开始托管」启动自动回复")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))

            VStack(alignment: .leading, spacing: 3) {
                ruleRow("私聊", desc: "AI 模拟你的风格自动回复", color: .green)
                ruleRow("VIP", desc: "发送忙碌通知，推送提醒你", color: .yellow)
                ruleRow("群聊", desc: "仅记录，不回复", color: .blue)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func ruleRow(_ label: String, desc: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color)
                .frame(width: 30, alignment: .leading)
            Text(desc)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    // MARK: - Activity section

    private var activitySection: some View {
        let activity = monitor.autopilotLog.filter { $0.action != .pending }
        let filtered: [AutopilotLogEntry] = {
            switch activityFilter {
            case .all: return activity
            case .sent: return activity.filter { $0.action == .sent || $0.action == .vipNotified }
            case .pending: return [] // pending is shown above
            case .failed: return activity.filter { $0.action == .failed }
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // Filter tabs + section header
            HStack(spacing: 0) {
                sectionHeaderInline("活动", icon: "list.bullet", color: .secondary)
                Spacer()
                if !activity.isEmpty {
                    HStack(spacing: 2) {
                        filterChip("全部", filter: .all, count: activity.count)
                        filterChip("已发", filter: .sent, count: activity.filter { $0.action == .sent || $0.action == .vipNotified }.count)
                        filterChip("失败", filter: .failed, count: activity.filter { $0.action == .failed }.count)
                    }
                    .padding(.trailing, 12)
                }
            }

            if filtered.isEmpty {
                Text(activity.isEmpty ? "暂无活动记录" : "无匹配记录")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(filtered, id: \.triggerMsgUID) { entry in
                    ActivityRow(entry: entry)
                }
            }
        }
    }

    private func filterChip(_ label: String, filter: ActivityFilter, count: Int) -> some View {
        let selected = activityFilter == filter
        return Button(action: { activityFilter = filter }) {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 9, weight: selected ? .semibold : .regular))
                if count > 0 && filter != .all {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundColor(selected ? .white : .white.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(selected ? Color.white.opacity(0.15) : Color.clear)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section headers

    private func sectionHeader(_ title: String, icon: String, color: Color, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color.opacity(0.7))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func sectionHeaderInline(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

// MARK: - Pending review row

private struct PendingReviewRow: View {
    let entry: AutopilotLogEntry
    @EnvironmentObject var monitor: ChatMonitor
    @State private var editing = false
    @State private var editedReply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: sender + trigger text
            HStack(spacing: 5) {
                Text(entry.senderName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                Text(entry.triggerText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer()
                // Confidence badge
                Text("\(Int(entry.confidence * 100))%")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(entry.confidence >= 0.7 ? .orange : .red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background((entry.confidence >= 0.7 ? Color.orange : Color.red).opacity(0.15))
                    .cornerRadius(3)
            }

            // Line 2: AI suggested reply (editable)
            if let reply = entry.generatedReply, !reply.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                        .foregroundColor(.cyan)
                    if editing {
                        TextField("", text: $editedReply)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10))
                    } else {
                        Text(reply)
                            .font(.system(size: 10))
                            .foregroundColor(.cyan)
                            .lineLimit(2)
                    }
                }
            }

            // Line 3: reason + actions
            HStack(spacing: 6) {
                if let reason = entry.aiReasoning {
                    Text(reason)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
                Spacer()

                Button(action: {
                    let text = editing ? editedReply : (entry.generatedReply ?? "")
                    Task {
                        _ = await monitor.approveAutopilotItem(
                            logId: entry.id, reply: text,
                            chatName: entry.chatName, chatUsername: entry.chatUsername
                        )
                    }
                }) {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)

                Button(action: {
                    if editing { editing = false } else {
                        editedReply = entry.generatedReply ?? ""
                        editing = true
                    }
                }) {
                    Text(editing ? "取消" : "改")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Button(action: { monitor.rejectAutopilotItem(logId: entry.id) }) {
                    Text("忽略")
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(5)
        .padding(.horizontal, 8)
    }
}

// MARK: - Activity row (expandable)

private struct ActivityRow: View {
    let entry: AutopilotLogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 5) {
                    actionIcon
                        .frame(width: 12)

                    Text(entry.senderName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 48, alignment: .leading)
                        .lineLimit(1)

                    if entry.action == .sent || entry.action == .vipNotified, let reply = entry.generatedReply {
                        Text("→ \(reply)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    } else {
                        Text(entry.triggerText)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(relativeTime(entry.createdAt))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                        .monospacedDigit()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.2))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    detailRow("收到", value: entry.triggerText)
                    if let reply = entry.generatedReply, !reply.isEmpty {
                        detailRow("回复", value: reply)
                    }
                    if let reason = entry.aiReasoning, !reason.isEmpty {
                        detailRow("原因", value: reason)
                    }
                    HStack(spacing: 10) {
                        detailRow("信心", value: "\(Int(entry.confidence * 100))%")
                        detailRow("风险", value: entry.riskLevel.rawValue)
                        detailRow("动作", value: actionLabel)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.03))
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            Text(value)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(2)
        }
    }

    private var actionLabel: String {
        switch entry.action {
        case .sent: return "已发送"
        case .vipNotified: return "VIP通知"
        case .skipped: return "跳过"
        case .groupLogged: return "群记录"
        case .failed: return "失败"
        case .pending: return "待审"
        case .readNoReply: return "已读"
        case .proactive: return "主动"
        }
    }

    @ViewBuilder
    private var actionIcon: some View {
        switch entry.action {
        case .sent:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundColor(.green)
        case .vipNotified:
            Image(systemName: "star.circle.fill").font(.system(size: 9)).foregroundColor(.yellow)
        case .skipped:
            Image(systemName: "forward.fill").font(.system(size: 8)).foregroundColor(.gray)
        case .readNoReply:
            Image(systemName: "eye.fill").font(.system(size: 8)).foregroundColor(.blue.opacity(0.6))
        case .proactive:
            Image(systemName: "bubble.right.fill").font(.system(size: 8)).foregroundColor(.cyan)
        case .groupLogged:
            Image(systemName: "doc.text").font(.system(size: 8)).foregroundColor(.blue.opacity(0.5))
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundColor(.red)
        case .pending:
            Image(systemName: "clock.fill").font(.system(size: 9)).foregroundColor(.orange)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60)m" }
        return "\(diff / 3600)h"
    }
}

// MARK: - Pending Send Row

struct PendingSendRow: View {
    let item: PendingSend
    @ObservedObject var monitor: ChatMonitor
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.chatName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                // Countdown
                Text("\(item.remainingSeconds)s")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.cyan)
                // Style score badge
                Text("S:\(item.styleScore)")
                    .font(.system(size: 8))
                    .foregroundColor(item.styleScore >= 70 ? .green : .orange)
            }

            if isEditing {
                TextField("编辑回复", text: $editText)
                    .font(.system(size: 10))
                    .textFieldStyle(.plain)
                    .padding(4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(3)
                HStack(spacing: 6) {
                    Button("发送") {
                        Task {
                            let config = monitor.loadAutopilotConfig()
                            await monitor.autopilotService?.editAndSend(id: item.id, newText: editText, config: config)
                        }
                        isEditing = false
                    }
                    .font(.system(size: 9)).foregroundColor(.green)
                    .buttonStyle(.plain)
                    Button("取消") { isEditing = false }
                        .font(.system(size: 9)).foregroundColor(.gray)
                        .buttonStyle(.plain)
                }
            } else {
                Text(item.replyText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("取消") {
                    Task { await monitor.autopilotService?.cancelPendingSend(id: item.id) }
                }
                .font(.system(size: 9)).foregroundColor(.red)
                .buttonStyle(.plain)

                Button("立即发送") {
                    Task {
                        let config = monitor.loadAutopilotConfig()
                        await monitor.autopilotService?.sendNow(id: item.id, config: config)
                    }
                }
                .font(.system(size: 9)).foregroundColor(.green)
                .buttonStyle(.plain)

                Button("编辑") {
                    editText = item.replyText
                    isEditing = true
                }
                .font(.system(size: 9)).foregroundColor(.blue)
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
