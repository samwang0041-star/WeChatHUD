import SwiftUI

/// Autopilot indicator for the extended header's right wing (the
/// actionable instance of the compact bar's glanceable buddy). Left-click
/// opens a popover with start/stop/pause controls plus links into
/// 待确认回复 (in the island) and Settings. Right-click is intentionally
/// empty — we keep the interaction surface minimal.
struct AutopilotIndicator: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState

    var body: some View {
        Button(action: {
            withMotion(CompanionMotion.islandRowExpand()) {
                panelState.setAutopilotPopoverOpen(!panelState.autopilotPopoverOpen)
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(iconColor)
                if monitor.autopilotActive {
                    stats
                }
            }
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandIconButtonStyle())
        .help(tooltip)
    }

    // MARK: - Visual state

    /// Icon tint — unlike emoji, SF Symbols respect `foregroundColor`.
    /// Off-state stays at 0.6 opacity so the affordance is discoverable
    /// without dominating the pill visually.
    private var iconColor: Color {
        if !monitor.autopilotActive { return .white.opacity(0.6) }
        if monitor.autopilotPaused || monitor.autopilotManuallyPaused { return .yellow }
        return .green
    }

    @ViewBuilder
    private var stats: some View {
        HStack(spacing: 2) {
            if monitor.autopilotSessionSent > 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.green.opacity(0.85))
                Text("\(monitor.autopilotSessionSent)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.green.opacity(0.85))
            }
            if monitor.autopilotSessionPending > 0 {
                Image(systemName: "hourglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange.opacity(0.85))
                Text("\(monitor.autopilotSessionPending)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.orange.opacity(0.85))
            }
        }
    }

    private var tooltip: String {
        if !monitor.autopilotActive { return "自动回复 · 已关闭 · 点击打开" }
        let status: String = {
            if monitor.autopilotManuallyPaused { return "已手动暂停" }
            if monitor.autopilotPaused { return "已暂停 (微信前台)" }
            return "运行中"
        }()
        let stats = monitor.autopilotSessionStats
        let duration = Self.formatDuration(stats.duration)
        return "自动回复 · \(status) · 已跑 \(duration) · 点击查看"
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        RelativeTimeFormatter.elapsedLabel(interval)
    }
}

// MARK: - Popover content

/// Popover shown when the user clicks the AutopilotIndicator. Layout
/// flips between "off" and "running" states; in the paused state the
/// pause button swaps to a resume button with a yellow info line.
struct AutopilotPopoverView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    var close: () -> Void
    /// True while 开始整理 is waiting for the real start result. Keeps the
    /// button in a named, disabled state instead of letting a second press
    /// queue behind the first one.
    @State private var starting = false
    @State private var stopping = false
    @State private var pausing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if monitor.autopilotActive {
                runningBody
            } else {
                offBody
            }

            Divider().opacity(0.3)
            footerLinks
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IslandInk.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "airplane.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(monitor.autopilotActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("自动回复")
                    .font(.system(size: 12, weight: .semibold))
                if monitor.autopilotActive {
                    Text(runningHeaderSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("当前关着")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private var runningHeaderSubtitle: String {
        let duration = AutopilotIndicator.formatDuration(monitor.autopilotSessionStats.duration)
        if monitor.autopilotManuallyPaused { return "已手动暂停 · \(duration)" }
        if monitor.autopilotPaused { return "已暂停 · \(duration)" }
        return "已跑 \(duration)"
    }

    // MARK: - Off-state body

    private var offBody: some View {
        Button(action: start) {
            HStack(spacing: 4) {
                Image(systemName: starting ? "hourglass" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(starting ? AutopilotStartCopy.starting : AutopilotStartCopy.start)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(IslandInboxRowButtonStyle(
            highlighted: false,
            resting: Color.green.opacity(starting ? 0.45 : 0.8),
            cornerRadius: 5
        ))
        .disabled(starting)
        .accessibilityLabel(starting ? AutopilotStartCopy.starting : AutopilotStartCopy.start)
        .help(starting ? AutopilotStartCopy.startingHint : AutopilotStartCopy.startHint)
    }

    /// Pressing 开始整理 must report what actually happened. The old handler
    /// called the fire-and-forget `startAutopilot()` and toasted success
    /// unconditionally, so a session that never started still told the user
    /// "已开始整理". The receipt now comes from `startAutopilotAndWait()`, and
    /// a failure leaves the popover — and this button — on screen as the retry
    /// entry.
    private func start() {
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            let receipt = AutopilotStartReceipt.resolve(
                started: await monitor.startAutopilotAndWait()
            )
            starting = false
            panelState.showToast(receipt.toast, duration: receipt.dismissesPopover ? 2 : 4)
            if receipt.dismissesPopover { close() }
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        Task { @MainActor in
            let receipt = AutopilotStopReceipt.resolve(
                stopped: await monitor.stopAutopilotAndWait()
            )
            stopping = false
            panelState.showToast(receipt.toast, duration: receipt.dismissesPopover ? 2 : 4)
            if receipt.dismissesPopover { close() }
        }
    }

    // MARK: - Running-state body

    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            statsBlock

            HStack(spacing: 6) {
                pauseResumeButton
                stopButton
            }

            if monitor.autopilotPaused && !monitor.autopilotManuallyPaused {
                Text("已暂停 — 你正在用微信，离开后自动恢复")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var statsBlock: some View {
        let stats = monitor.autopilotSessionStats
        return VStack(alignment: .leading, spacing: 3) {
            statRow(systemIcon: "checkmark", label: "已发", value: stats.totalSent, color: .green)
            statRow(systemIcon: "hourglass", label: "待确认", value: monitor.autopilotSessionPending, color: .orange)
            if stats.totalSkipped > 0 {
                statRow(systemIcon: "slash.circle", label: "跳过", value: stats.totalSkipped, color: .secondary)
            }
        }
    }

    private func statRow(systemIcon: String, label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemIcon).font(.system(size: 10))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(color)
        }
    }

    private var pauseResumeButton: some View {
        let paused = monitor.autopilotManuallyPaused
        return Button(action: {
            guard !pausing, !stopping else { return }
            pausing = true
            Task { @MainActor in
                defer { pausing = false }
                if paused {
                    await monitor.autopilotService?.manualResume()
                } else {
                    await monitor.autopilotService?.manualPause()
                }
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(pausing ? (paused ? "正在恢复…" : "正在暂停…") : (paused ? "恢复" : "暂停"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(paused ? .green : .yellow)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(IslandInboxRowButtonStyle(
            highlighted: false,
            resting: (paused ? Color.green : Color.yellow).opacity(0.15),
            cornerRadius: 4
        ))
        .disabled(stopping || pausing)
        .help(pausing ? (paused ? "正在恢复整理" : "正在暂停整理") : (stopping ? AutopilotStopCopy.stoppingHint : ""))
        .accessibilityHint(pausing ? (paused ? "正在恢复整理" : "正在暂停整理") : (stopping ? AutopilotStopCopy.stoppingHint : ""))
    }

    private var stopButton: some View {
        Button(action: stop) {
            HStack(spacing: 3) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(stopping ? AutopilotStopCopy.stopping : AutopilotStopCopy.stop)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(IslandInboxRowButtonStyle(
            highlighted: false,
            resting: Color.red.opacity(0.15),
            cornerRadius: 4
        ))
        .disabled(stopping || pausing)
        .help(stopping ? AutopilotStopCopy.stoppingHint : (pausing ? "正在暂停整理" : ""))
        .accessibilityLabel(stopping ? AutopilotStopCopy.stopping : AutopilotStopCopy.stop)
        .accessibilityHint(stopping ? AutopilotStopCopy.stoppingHint : (pausing ? "正在暂停整理" : ""))
    }

    // MARK: - Footer links

    private var footerLinks: some View {
        HStack(spacing: 8) {
            Button(action: {
                AutopilotPopoverRouting.openPendingRepliesInPanel(panelState)
                close()
            }) {
                Text("待确认回复")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(IslandRowButtonStyle())
            .help("打开待确认列表")
            .accessibilityHint("打开待确认列表")

            Text("·")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Button(action: {
                // Reuse the pending-tab channel — SettingsView listens on
                // `pendingSettingsTab` and jumps to the matching section.
                panelState.pendingSettingsTab = "autopilot"
                panelState.onShowSettings?()
                close()
            }) {
                Text("设置")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(IslandRowButtonStyle())

            Spacer()
        }
    }
}

/// Words for the popover's 「开始整理」 press.
enum AutopilotStartCopy {
    static let start = "开始整理"
    static let starting = "正在启动…"
    static let startHint = "开始整理该回的消息；发不发仍由自动回复设置决定"
    static let startingHint = "正在启动自动回复，请稍候…"
    static let started = "自动回复已开始整理"
    static let failed = "自动回复没能启动，服务还没准备好。请重试。"
}

enum AutopilotStopCopy {
    static let stop = "停止"
    static let stopping = "正在停止…"
    static let stoppingHint = "正在停止自动回复"
    static let stopped = "自动回复已停止"
    static let failed = "自动回复没有停干净，整理可能还在跑。请重试。"
}

struct AutopilotStopReceipt: Equatable {
    let stopped: Bool
    let toast: String
    let dismissesPopover: Bool

    static func resolve(stopped: Bool) -> AutopilotStopReceipt {
        stopped
            ? AutopilotStopReceipt(stopped: true, toast: AutopilotStopCopy.stopped, dismissesPopover: true)
            : AutopilotStopReceipt(stopped: false, toast: AutopilotStopCopy.failed, dismissesPopover: false)
    }
}

/// The receipt for one 开始整理 press. Only a confirmed start may dismiss the
/// popover: a failure has to leave the button on screen as the retry entry.
struct AutopilotStartReceipt: Equatable {
    let started: Bool
    let toast: String
    let dismissesPopover: Bool

    static func resolve(started: Bool) -> AutopilotStartReceipt {
        started
            ? AutopilotStartReceipt(
                started: true,
                toast: AutopilotStartCopy.started,
                dismissesPopover: true
            )
            : AutopilotStartReceipt(
                started: false,
                toast: AutopilotStartCopy.failed,
                dismissesPopover: false
            )
    }
}

/// The in-island 待确认回复 entry that makes `DetailKind.autopilot` reachable:
/// routes the detail panel to the same ApprovalWorkspaceView the Settings
/// window shows, without opening a second window.
@MainActor
enum AutopilotPopoverRouting {
    static func openPendingRepliesInPanel(_ panelState: PanelState) {
        panelState.showDetail(kind: .autopilot)
    }
}
