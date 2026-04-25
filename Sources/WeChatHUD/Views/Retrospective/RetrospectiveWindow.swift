import SwiftUI

/// Phase 1 placeholder window. Phase 2 plan replaces this with the full
/// timeline density rows + chrome + summary block per Spec §4.2.
/// This stub exists so RetrospectiveWindowManager can be wired now and
/// the [⤢ 完整窗口] button in the floating tab does something concrete.
struct RetrospectiveWindow: View {
    @EnvironmentObject var monitor: ChatMonitor
    @State private var summaryText: String = "（尚未生成）"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("复盘 (Phase 1 占位窗口)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Text("Phase 2 plan 将在此处接入完整时间轴 / 红 banner / AI 总结块 / 待办四态按钮 / 数据账本入口。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Color.white.opacity(0.1))

            ScrollView {
                Text(summaryText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
        .onAppear { refresh() }
        .onReceive(monitor.retrospectiveJob.$state) { _ in refresh() }
    }

    private func refresh() {
        guard case .completed(let runID) = monitor.retrospectiveJob.state,
              let run = monitor.hudStore.runByID(runID)
        else { return }
        var lines: [String] = ["Run \(run.id) · \(run.status.rawValue) · \(run.chatCount) chats / \(run.msgCount) msgs"]
        for item in run.summaryTop3 { lines.append("• \(item.text)") }
        if let r = run.summaryRisk { lines.append("⚡ \(r.text)") }
        if let m = run.summaryMissed { lines.append("💡 \(m.text)") }
        summaryText = lines.joined(separator: "\n\n")
    }
}
