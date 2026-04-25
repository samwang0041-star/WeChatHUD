import SwiftUI

/// Phase 1 placeholder for the floating-tab `复盘` surface (Plan M6.5).
/// Bare-bones [重新生成] + [完整窗口] + a text dump of the latest run
/// summary. Phase 2 plan replaces this with the full UI per Spec §4.1
/// (red banner reply path, AI summary block with evidence chips,
/// uncertain card stack, etc.).
struct RetrospectiveTabView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @State private var lastRunSummary: String = "（尚未生成）"
    @State private var isRunning = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("复盘 · Phase 1 占位")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Button(isRunning ? "生成中…" : "重新生成 ↻") {
                    runJob()
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .foregroundColor(.white.opacity(isRunning ? 0.4 : 0.85))
                .font(.system(size: 11))
            }

            HStack(spacing: 8) {
                Button("打开完整窗口 ⤢") {
                    RetrospectiveWindowManager.shared.showWindow(monitor: monitor)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.7))
                .font(.system(size: 10))

                Spacer()

                if let err = errorText {
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                Text(lastRunSummary)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .onAppear { refresh() }
        .onReceive(monitor.retrospectiveJob.$state) { newState in
            apply(state: newState)
        }
    }

    private func runJob() {
        errorText = nil
        isRunning = true
        monitor.retrospectiveJob.run(
            mode: .sinceLastRetrospective(lastRunEnd: monitor.hudStore.latestCompletedRun()?.rangeEnd),
            myUsername: monitor.myUsername,
            myDisplayName: monitor.myDisplayName
        )
    }

    private func apply(state: RetrospectiveJob.State) {
        switch state {
        case .completed(let runID):
            isRunning = false
            lastRunSummary = renderSummary(runID: runID)
        case .partial(let runID, let failed):
            isRunning = false
            lastRunSummary = "⚠ 部分成功 · 失败 \(failed.count) 个对话\n\n" + renderSummary(runID: runID)
        case .failed(let msg):
            isRunning = false
            errorText = msg
        case .idle:
            isRunning = false
        default:
            isRunning = true
        }
    }

    private func refresh() {
        guard let run = monitor.hudStore.latestCompletedRun() else { return }
        lastRunSummary = renderSummary(runID: run.id)
    }

    private func renderSummary(runID: Int) -> String {
        guard let run = monitor.hudStore.runByID(runID) else { return "（无数据）" }
        var lines: [String] = []
        lines.append("Run \(run.id) · \(run.status.rawValue) · \(run.chatCount) chats / \(run.msgCount) msgs")
        for item in run.summaryTop3 { lines.append("• \(item.text)") }
        if let r = run.summaryRisk { lines.append("⚡ \(r.text)") }
        if let m = run.summaryMissed { lines.append("💡 \(m.text)") }
        return lines.joined(separator: "\n")
    }
}
