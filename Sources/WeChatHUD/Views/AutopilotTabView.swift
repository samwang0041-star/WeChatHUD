import SwiftUI

/// Autopilot tab in the extended pill — real-time activity feed,
/// pending review queue, session stats, and start/stop toggle.
struct AutopilotTabView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var store: HUDStore
    /// The settings workspace already supplies the page title. The compact
    /// detail host keeps this false so its smaller controls stay concise.
    let isWorkspace: Bool

    init(isWorkspace: Bool = false) {
        self.isWorkspace = isWorkspace
    }

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
                    ForEach(pending) { entry in
                        PendingReviewRow(entry: entry)
                    }
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                }

                // ── Activity feed with filter ──
                activitySection
            }
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .font(.system(size: isWorkspace ? 16 : 12, weight: .semibold))
                .foregroundStyle(monitor.autopilotActive ? .green : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.autopilotActive
                     ? (isAutopilotPaused ? "代回复已暂停" : "正在整理回复")
                     : "代回复还没开始")
                    .font(.system(size: isWorkspace ? 13 : 10, weight: .semibold))
                if isWorkspace {
                    Text(autoSendSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            // Start/end button. Starting a session never changes the saved
            // auto-send setting; that remains visible and editable below.
            Button(action: { monitor.toggleAutopilot() }) {
                HStack(spacing: 4) {
                    Image(systemName: monitor.autopilotActive ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: isWorkspace ? 12 : 11, weight: .semibold))
                    Text(monitor.autopilotActive ? "停止" : "开始整理")
                        .font(.system(size: isWorkspace ? 12 : 10, weight: .semibold))
                }
                .foregroundColor(monitor.autopilotActive ? .red : .green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((monitor.autopilotActive ? Color.red : Color.green).opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(monitor.autopilotActive ? "停止整理回复" : "开始整理回复")
            .accessibilityHint(monitor.autopilotActive ? "停止当前自动整理" : "开始整理该回的消息；发不发仍由自动回复设置决定")

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
                    HStack(spacing: 4) {
                        Image(systemName: monitor.autopilotManuallyPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9))
                        if isWorkspace {
                            Text(monitor.autopilotManuallyPaused ? "恢复" : "暂停")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundColor(monitor.autopilotManuallyPaused ? .green : .yellow)
                    .padding(.horizontal, isWorkspace ? 6 : 3)
                    .padding(.vertical, 3)
                    .background((monitor.autopilotManuallyPaused ? Color.green : Color.yellow).opacity(0.15))
                    .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(monitor.autopilotManuallyPaused ? "恢复自动回复" : "暂停自动回复")

                // Session stats
                HStack(spacing: 6) {
                    miniStat(systemIcon: "checkmark", value: monitor.autopilotSessionSent, color: .green)
                    miniStat(systemIcon: "hourglass", value: monitor.autopilotSessionPending, color: .orange)
                }

                // Session duration
                if let start = sessionStart {
                    Text(sessionDuration(since: start))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            if isWorkspace {
                Button {
                    openAutopilotSettings()
                } label: {
                    Label("自动回复设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.link)
                .accessibilityLabel("打开自动回复设置")
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

    private func miniStat(systemIcon: String, value: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemIcon).font(.system(size: 8, weight: .semibold))
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
            dashStat("延迟", value: "\(stats.avgDelay)s", color: .secondary)
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
                .font(.system(size: 11))
                .foregroundColor(.secondary)
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
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .foregroundColor(.yellow)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .font(.system(size: isWorkspace ? 30 : 22, weight: .medium))
                .foregroundStyle(CompanionPalette.accent.opacity(0.75))
            Text("还没有待确认的回复")
                .font(.system(size: isWorkspace ? 16 : 12, weight: .semibold))
            Text("点开始后，助理会整理该回的消息。发不发都由你决定。")
                .font(.system(size: isWorkspace ? 13 : 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isWorkspace {
                workspaceGuideCard
                    .padding(.top, 6)
            }

            if !isWorkspace {
                configSummaryCard

                VStack(alignment: .leading, spacing: 3) {
                    ruleRow("私聊", desc: "按自动回复设置处理", color: .green)
                    ruleRow("群聊", desc: "不自动发送", color: .blue)
                }
                .padding(.top, 4)

                Button("打开自动回复设置") { openAutopilotSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// Workspace empty-state guide: what the assistant does, in what order,
    /// and which guardrails apply before anything is sent.
    private var workspaceGuideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            workspaceGuideStep(1, "自动整理需要回复的消息")
            workspaceGuideStep(2, "按你的语气生成回复草稿")
            workspaceGuideStep(3, "你确认后才发送；没打开「自动发出去」时，草稿会停在这里")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ruleRow("私聊", desc: "按自动回复设置处理", color: .green, labelSize: 11, descSize: 12)
                ruleRow("群聊", desc: "不自动发送", color: .blue, labelSize: 11, descSize: 12)
            }

            HStack {
                Spacer(minLength: 0)
                Button("查看发送限制") { openAutopilotSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityLabel("查看发送限制，打开自动回复设置")
            }
        }
        .frame(width: 560, alignment: .leading)
        .companionSurface(padding: 18)
    }

    private func workspaceGuideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CompanionPalette.accent)
                .frame(width: 22, height: 22)
                .background(CompanionPalette.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var autoSendSummary: String {
        let config = store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()
        return config.autoSendEnabled
            ? "已打开自动发出去 · 比较有把握的回复会按你设的节奏发出"
            : "没有打开自动发出去 · 只写成草稿，等你确认"
    }

    private var isAutopilotPaused: Bool {
        monitor.autopilotPaused || monitor.autopilotManuallyPaused
    }

    private var configSummaryCard: some View {
        HStack(spacing: 7) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(autoSendSummary)
                .font(.system(size: isWorkspace ? 12 : 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: isWorkspace ? 560 : 340)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private func openAutopilotSettings() {
        panelState.pendingSettingsTab = "autopilot"
        if !isWorkspace {
            panelState.onShowSettings?()
        }
    }

    private func ruleRow(_ label: String, desc: String, color: Color, labelSize: CGFloat = 10, descSize: CGFloat = 11) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundColor(color)
                .frame(width: 30, alignment: .leading)
            Text(desc)
                .font(.system(size: descSize))
                .foregroundColor(.secondary)
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
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(filtered) { entry in
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
            .foregroundColor(selected ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(selected ? Color.primary.opacity(0.12) : Color.clear)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(label)，\(count) 条")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        .foregroundColor(color)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Text(entry.triggerText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(entry.riskLevel.label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(riskColor(entry.riskLevel))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(riskColor(entry.riskLevel).opacity(0.15))
                    .cornerRadius(3)
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
                            .font(.system(size: 12))
                    } else {
                        Text(reply)
                            .font(.system(size: 12))
                            .foregroundColor(.cyan)
                            .lineLimit(2)
                    }
                }
            }

            // Line 3: reason + actions
            HStack(spacing: 6) {
                if let reason = entry.aiReasoning {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发送待审核回复")

                Button(action: {
                    if editing { editing = false } else {
                        editedReply = entry.generatedReply ?? ""
                        editing = true
                    }
                }) {
                    Text(editing ? "取消" : "改")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(editing ? "取消编辑回复" : "编辑回复")

                Button(action: { monitor.rejectAutopilotItem(logId: entry.id) }) {
                    Text("忽略")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("忽略待审核回复")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(5)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("待审核：\(entry.senderName)，风险\(entry.riskLevel.label)，信心\(Int(entry.confidence * 100))%")
    }

    private func riskColor(_ risk: AutopilotRisk) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

// MARK: - Activity row (expandable)

private struct ActivityRow: View {
    let entry: AutopilotLogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button(action: { withMotion(CompanionMotion.ease(0.15)) { expanded.toggle() } }) {
                HStack(spacing: 5) {
                    actionIcon
                        .frame(width: 12)

                    Text(entry.senderName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 48, alignment: .leading)
                        .lineLimit(1)

                    if entry.action == .sent || entry.action == .vipNotified, let reply = entry.generatedReply {
                        Text("→ \(reply)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(entry.triggerText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(relativeTime(entry.createdAt))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起自动回复活动详情" : "展开自动回复活动详情")

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
                        detailRow("风险", value: entry.riskLevel.label)
                        detailRow("动作", value: actionLabel)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.03))
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
    }

    private var actionLabel: String {
        switch entry.action {
        case .sent: return "已发送"
        case .stall: return "暂缓"
        case .queued: return "待发送"
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
        case .stall:
            Image(systemName: "pause.circle.fill").font(.system(size: 9)).foregroundColor(.yellow)
        case .queued:
            Image(systemName: "timer").font(.system(size: 9)).foregroundColor(.cyan)
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
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.chatName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text(item.risk.label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(riskColor(item.risk))
                // Countdown
                Text("\(item.remainingSeconds)s")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.cyan)
                // Style score badge
                Text("风格 \(item.styleScore)")
                    .font(.system(size: 8))
                    .foregroundColor(item.styleScore >= 70 ? .green : .orange)
            }

            if isEditing {
                TextField("编辑回复", text: $editText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .padding(4)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(3)
                HStack(spacing: 6) {
                    Button("发送") {
                        Task {
                            let config = monitor.loadAutopilotConfig()
                            let outcome = await monitor.editAndSendAutopilot(id: item.id, newText: editText, config: config)
                            await MainActor.run {
                                switch outcome {
                                case .sent:
                                    isEditing = false
                                    sendError = nil
                                case .blocked(let reason):
                                    sendError = reason
                                case .notFound:
                                    isEditing = false
                                    sendError = "队列项已不存在"
                                }
                            }
                        }
                    }
                    .font(.system(size: 11)).foregroundColor(.green)
                    .buttonStyle(.plain)
                    .accessibilityLabel("发送编辑后的回复")
                    Button("取消") { isEditing = false }
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消编辑待发送回复")
                }
            } else {
                Text(item.replyText)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }

            if let trigger = item.peerLastMessage, !trigger.isEmpty {
                Text("收到：\(trigger)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let manualReason = item.manualOnlyReason {
                Text("需人工确认：\(manualReason)")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            if let sendError {
                Text(sendError)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text("信心 \(Int(item.confidence * 100))%")
                Text(item.reasoning)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("取消") {
                    Task { await monitor.autopilotService?.cancelPendingSend(id: item.id) }
                }
                .font(.system(size: 11)).foregroundColor(.red)
                .buttonStyle(.plain)
                .accessibilityLabel("取消待发送回复")

                Button("立即发送") {
                    Task {
                        let config = monitor.loadAutopilotConfig()
                        let outcome = await monitor.sendAutopilotNow(id: item.id, config: config)
                        await MainActor.run {
                            switch outcome {
                            case .sent:
                                sendError = nil
                            case .blocked(let reason):
                                sendError = reason
                            case .notFound:
                                sendError = "队列项已不存在"
                            }
                        }
                    }
                }
                .font(.system(size: 11)).foregroundColor(.green)
                .buttonStyle(.plain)
                .accessibilityLabel("立即发送待发送回复")

                Button("编辑") {
                    editText = item.replyText
                    isEditing = true
                }
                .font(.system(size: 11)).foregroundColor(.blue)
                .buttonStyle(.plain)
                .accessibilityLabel("编辑待发送回复")

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func riskColor(_ risk: AutopilotRisk) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}
