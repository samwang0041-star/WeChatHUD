import SwiftUI
import AppKit

struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.07))
            DailyReportCommandCenterView()
        }
        .task {
            await monitor.loadDailyReport()
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: previousDay) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Text("日报 · \(dateText(monitor.dailyReportViewedDate))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))

                Button(action: nextDay) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(canGoNext ? .white.opacity(0.5) : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!canGoNext)
            }
            .padding(.leading, 4)

            Spacer()

            if monitor.dailyReportIsLoading, monitor.dailyReport != nil {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 12, height: 12)
                    Text("刷新中")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(.trailing, 8)
            }

            Button(action: {
                if let url = monitor.exportDailyReport() {
                    print("[WCHUD] exported to \(url.path)")
                }
            }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("导出 Markdown")

            Button(action: {
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("刷新日报")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var canGoNext: Bool {
        !Calendar.current.isDateInToday(monitor.dailyReportViewedDate)
    }

    private func previousDay() {
        let calendar = Calendar.current
        if let prev = calendar.date(byAdding: .day, value: -1, to: monitor.dailyReportViewedDate) {
            monitor.dailyReportViewedDate = prev
            Task { await monitor.loadDailyReport() }
        }
    }

    private func nextDay() {
        let calendar = Calendar.current
        if let next = calendar.date(byAdding: .day, value: 1, to: monitor.dailyReportViewedDate),
           next <= Date() {
            monitor.dailyReportViewedDate = next
            Task { await monitor.loadDailyReport() }
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        if Calendar.current.isDateInToday(date) {
            return "今天"
        }
        return formatter.string(from: date)
    }
}
