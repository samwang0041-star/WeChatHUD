import SwiftUI
import AppKit

struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    /// The workspace uses a readable three-level hierarchy. The HUD keeps the
    /// existing compact header because it is rendered in a much smaller panel.
    private let isWorkspace: Bool
    @State private var exportMessage: String?
    @State private var exportedReportURL: URL?
    @State private var exportFailed = false
    @State private var scope: ReportScope = .daily
    @State private var weeklyCatalog: [DiscussionItem] = []

    private enum ReportScope: String, CaseIterable {
        case daily = "日报"
        case weekly = "周报"
    }

    init(isWorkspace: Bool = true) {
        self.isWorkspace = isWorkspace
    }

    var body: some View {
        Group {
            if isWorkspace {
                workspaceBody
            } else {
                compactBody
            }
        }
        .foregroundStyle(.primary)
        .background(isWorkspace ? CompanionPalette.canvas : Color(nsColor: .windowBackgroundColor))
        .onChange(of: monitor.dailyReportViewedDate) { _, _ in
            if scope == .weekly { reloadWeeklyCatalog() }
        }
        .onChange(of: scope) { _, value in
            if value == .weekly { reloadWeeklyCatalog() }
        }
        .task {
            await monitor.loadDailyReport()
        }
    }

    private var workspaceBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceToolbar
            if let exportMessage {
                exportStatus(exportMessage)
            }
            if scope == .weekly {
                weeklySummary
                    .onAppear { reloadWeeklyCatalog() }
            } else {
                DailyReportCommandCenterView(isWorkspace: true)
            }
        }
        .background(CompanionPalette.canvas)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let exportMessage {
                exportStatus(exportMessage)
            }
            Divider().background(Color.secondary.opacity(0.2))
            DailyReportCommandCenterView(isWorkspace: false)
        }
    }

    private func exportStatus(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: exportFailed ? "exclamationmark.triangle" : "checkmark.circle")
            Text(message).lineLimit(1)
            if let exportedReportURL {
                Button("打开这份小结") {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedReportURL])
                }
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .accessibilityLabel("打开这份小结")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: isWorkspace ? 12 : 11))
        .foregroundColor(exportFailed ? .red : .secondary)
        .padding(.horizontal, isWorkspace ? 20 : 14)
        .padding(.bottom, 6)
    }

    private var workspaceToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ReportScope.allCases, id: \.self) { value in
                    Button { scope = value } label: {
                        Text(value.rawValue)
                            .workspaceBody()
                            .fontWeight(scope == value ? .semibold : .regular)
                            .foregroundStyle(scope == value ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(scope == value ? CompanionPalette.selectedFill : Color.clear, in: Capsule())
                    }
                    .buttonStyle(CompanionPressStyle())
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
                }
                Spacer()
                Button(action: previousDay) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .disabled(monitor.dailyReportIsLoading)
                .accessibilityLabel(scope == .weekly ? "上一周" : "前一天")
                Text(scope == .weekly ? weekRangeText(monitor.dailyReportViewedDate) : dateText(monitor.dailyReportViewedDate))
                    .workspaceBody()
                    .fontWeight(.semibold)
                    .frame(minWidth: 96)
                Button(action: nextDay) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(CompanionPressStyle())
                .workspaceMeta()
                .foregroundStyle(.secondary)
                .disabled(!canGoNext || monitor.dailyReportIsLoading)
                .accessibilityLabel(scope == .weekly ? "下一周" : "后一天")
                Button(action: exportReport) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(CompanionPalette.jade)
                .disabled(monitor.dailyReportIsLoading || (scope == .daily && monitor.dailyReport == nil))
                .accessibilityLabel("导出今日小结")
            }
            if monitor.dailyReportIsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(scope == .weekly ? "正在写这周的小结。" : "正在写今天的小结。")
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var weeklySummary: some View {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: monitor.dailyReportViewedDate)
        let items = weeklyCatalog.filter { item in
            guard let interval else { return false }
            let date = Date(timeIntervalSince1970: TimeInterval(item.sourceTimestamp))
            return interval.contains(date) || (item.dueAt.map { interval.contains($0) } ?? false)
        }
        let done = items.filter { $0.status == .done }
        let pending = items.filter { $0.status == .pending && !$0.kind.isRecord }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("本周推进了 \(done.count) 件事，还有 \(pending.count) 件要跟进。")
                    .workspaceTitle()
                if pending.isEmpty && done.isEmpty {
                    Text("这一周还没有整理出事项。连上微信并关注对话后会出现在这里。")
                        .foregroundStyle(.secondary)
                } else {
                    if !done.isEmpty {
                        Text("已经推进")
                            .workspaceMeta()
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                       ForEach(Array(done.prefix(8).enumerated()), id: \.element.id) { index, item in
                           HStack(alignment: .top, spacing: 10) {
                               Text("\(index + 1)")
                                   .workspaceMeta()
                                   .fontWeight(.semibold)
                                   .foregroundStyle(.secondary)
                                   .frame(width: 22, alignment: .leading)
                               VStack(alignment: .leading, spacing: 4) {
                                   Text(item.content)
                                       .workspaceBody()
                                       .fontWeight(.semibold)
                                   Text("来自：\(item.chatName)")
                                       .workspaceMeta()
                                       .foregroundStyle(.secondary)
                               }
                           }
                       }
                        if done.count > 8 {
                            Text("还有 \(done.count - 8) 件已完成，在待办的「看已处理的」里。")
                                .workspaceMeta()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !pending.isEmpty {
                        Text("还需要跟进")
                            .workspaceMeta()
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        ForEach(pending.prefix(8)) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.content)
                                        .workspaceBody()
                                    Text(DiscussionPresentation.dueLabel(item.dueAt))
                                        .workspaceMeta()
                                        .foregroundStyle(.secondary)
                                }
                            }
                       }
                        Button(pending.count > 8
                               ? "还有 \(pending.count - 8) 件，在待办里看"
                               : "在待办里看") {
                            panelState.pendingSettingsTab = "tasks"
                        }
                        .buttonStyle(CompanionPressStyle())
                        .workspaceMeta()
                        .foregroundStyle(.secondary)
                    }
                }
                Text("根据已同步的关注对话生成。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reloadWeeklyCatalog() {
        weeklyCatalog = monitor.loadDiscussionCatalog()
    }

    private func weekRangeText(_ date: Date) -> String {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return dateText(date)
        }
        let start = interval.start
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: previousDay) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看前一天日报")
                .disabled(monitor.dailyReportIsLoading)

                Text("日报 · \(dateText(monitor.dailyReportViewedDate))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Button(action: nextDay) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(canGoNext ? .secondary : .secondary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看后一天日报")
                .disabled(!canGoNext || monitor.dailyReportIsLoading)
            }
            .padding(.leading, 4)

            Spacer()

            if monitor.dailyReportIsLoading, monitor.dailyReport != nil {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 12, height: 12)
                    Text("刷新中")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 8)
            }

            Button(action: exportReport) {
                Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(monitor.dailyReportIsLoading || monitor.dailyReport == nil)
            .accessibilityLabel("导出今日小结")
            .help("导出 Markdown")

            Button(action: {
                guard !monitor.dailyReportIsLoading else { return }
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(monitor.dailyReportIsLoading)
            .accessibilityLabel("刷新今日小结")
            .help("刷新今日小结")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var canGoNext: Bool {
        !Calendar.current.isDateInToday(monitor.dailyReportViewedDate)
    }

    private func previousDay() {
        guard !monitor.dailyReportIsLoading else { return }
        let calendar = Calendar.current
        let offset = scope == .weekly ? -7 : -1
        if let prev = calendar.date(byAdding: .day, value: offset, to: monitor.dailyReportViewedDate) {
            exportMessage = nil
            exportedReportURL = nil
            monitor.dailyReportViewedDate = prev
            Task { await monitor.loadDailyReport() }
        }
    }

    private func nextDay() {
        guard !monitor.dailyReportIsLoading else { return }
        let calendar = Calendar.current
        let offset = scope == .weekly ? 7 : 1
        if let next = calendar.date(byAdding: .day, value: offset, to: monitor.dailyReportViewedDate),
           next <= Date() {
            exportMessage = nil
            exportedReportURL = nil
            monitor.dailyReportViewedDate = next
            Task { await monitor.loadDailyReport() }
        }
    }

    private func refreshReport() {
        guard !monitor.dailyReportIsLoading else { return }
        Task { await monitor.loadDailyReport(force: true) }
    }

    private func exportReport() {
        guard !monitor.dailyReportIsLoading else { return }
        guard let url = monitor.exportDailyReport() else {
            exportedReportURL = nil
            exportFailed = true
            exportMessage = "小结没有写到文件，请检查桌面写入权限后重试。"
            return
        }
        exportedReportURL = url
        exportFailed = false
        exportMessage = "小结已放到桌面。"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        if Calendar.current.isDateInToday(date) {
            return "今天"
        }
        return formatter.string(from: date)
    }

    private func dateKeyText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

}

struct DailyReportHUDTabView: View {
    var body: some View {
        DailyReportTabView(isWorkspace: false)
            .preferredColorScheme(.dark)
    }
}
