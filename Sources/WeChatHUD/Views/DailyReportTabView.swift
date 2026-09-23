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
        .workspaceGround()
        .companionAnimation(CompanionMotion.ease(), value: exportMessage)
        .onChange(of: monitor.dailyReportViewedDate) { _, _ in
            if scope == .weekly { reloadWeeklyCatalog() }
        }
        // The live pending list is the same rows the weekly roll-up counts, so
        // its mutation is the signal that the snapshot is stale. Without this
        // the 周报 kept showing the numbers from whenever the tab was first
        // opened — across a scan, and across a WeChat account switch.
        .onChange(of: monitor.discussionItems.count) { _, _ in
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
            Divider().background(Color.secondary.opacity(0.2))
            if scope == .weekly {
                weeklySummary
                    .onAppear { reloadWeeklyCatalog() }
            } else {
                DailyReportCommandCenterView(isWorkspace: true)
            }
        }
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
            Text(message)
                .lineLimit(isWorkspace ? nil : 2)
                .fixedSize(horizontal: false, vertical: isWorkspace)
          if let exportedReportURL {
              Button("打开结果") {
                   if !CompanionFinder.reveal(exportedReportURL) {
                       exportMessage = "小结已导出。没能打开访达，请到桌面查看文件。"
                   }
              }
              .buttonStyle(CompanionPressStyle())
              .accessibilityLabel("打开导出的日报")
           } else if exportFailed {
               Button("打开桌面") {
                    if !CompanionFinder.openDesktop() {
                        exportMessage = "小结没能保存到桌面。也没能打开访达，请到桌面查看。"
                    }
               }
               .buttonStyle(CompanionPressStyle())
               .accessibilityLabel("打开桌面")
           }
            Spacer(minLength: 0)
        }
        .companionFont(size: isWorkspace ? 12 : 11)
        .foregroundColor(exportFailed ? .red : .secondary)
        .padding(.horizontal, isWorkspace ? 0 : 14)
        .padding(.bottom, 6)
        .transition(.companionStatusReveal)
    }

    private var workspaceToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ReportScope.allCases, id: \.self) { value in
                    CompanionFilterPill(title: value.rawValue, selected: scope == value, tint: SettingsView.Tab.dailyReport.accentColor) {
                        scope = value
                    }
                }
                Spacer()
                Button(action: previousDay) {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(monitor.dailyReportIsLoading)
                .help(previousDayHoldReason ?? "")
                .accessibilityHint(previousDayHoldReason ?? "")
                .accessibilityLabel(scope == .weekly ? "上一周" : "前一天")
                Text(scope == .weekly ? weekRangeText(monitor.dailyReportViewedDate) : dateText(monitor.dailyReportViewedDate))
                    .companionFont(size: 14, weight: .semibold)
                    .frame(minWidth: 96)
                Button(action: nextDay) {
                    Image(systemName: "chevron.right")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(!canGoNext || monitor.dailyReportIsLoading)
                .help(nextDayHoldReason ?? "")
                .accessibilityHint(nextDayHoldReason ?? "")
                .accessibilityLabel(scope == .weekly ? "下一周" : "后一天")
               Button(action: exportReport) {
                   Label("导出", systemImage: "square.and.arrow.up")
               }
               .tint(SettingsView.Tab.dailyReport.accentColor)
               .buttonStyle(.borderedProminent)
               .disabled(monitor.dailyReportIsLoading || (scope == .daily && monitor.dailyReport == nil))
               .help(exportHoldReason ?? "")
               .accessibilityHint(exportHoldReason ?? "")
               .accessibilityLabel("导出今日小结")
            }
            if monitor.dailyReportIsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理…").companionFont(size: 12).foregroundStyle(.secondary)
                }
            }
        }
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
                // 「本周做完了 N 件」 is a claim about *when* things got done, and this
                // store keeps no completion timestamp for a commitment: the filter
                // is 「来源消息或到期时间落在本周」 且「现在的状态是已完成」. A task
                // finished three weeks ago and mentioned on Monday counted as
                // 本周推进.
                Text("本周相关的事里，已完成 \(done.count) 件，还有 \(pending.count) 件要跟进。")
                    .workspaceTitle()
               if pending.isEmpty && done.isEmpty {
                   VStack(alignment: .leading, spacing: 8) {
                        let connected = monitor.stats.lastSyncAt != nil
                        let watching = monitor.store.hasWhitelistEntries()
                        Text(weeklyEmptyCopy(connected: connected, watching: watching))
                            .foregroundStyle(.secondary)
                        weeklyEmptyMove(connected: connected, watching: watching)
                   }
               } else {
                    if !done.isEmpty {
                        Text("已经推进").companionFont(size: 13, weight: .semibold).foregroundStyle(.secondary)
                       ForEach(Array(done.prefix(8).enumerated()), id: \.element.id) { index, item in
                           HStack(alignment: .top, spacing: 10) {
                               Text("\(index + 1)")
                                   .companionFont(size: 13, weight: .bold)
                                   .foregroundStyle(.white)
                                   .frame(width: 24, height: 24)
                                   .background(CompanionPalette.jade, in: Circle())
                               VStack(alignment: .leading, spacing: 4) {
                                   Text(item.content).companionFont(size: 15, weight: .semibold)
                                   Text("来自：\(item.chatName)")
                                       .companionFont(size: 12).foregroundStyle(.secondary)
                               }
                           }
                       }
                        if done.count > 8 {
                            Text("还有 \(done.count - 8) 件已完成，在待办的「看已处理的」里。")
                                .companionFont(size: 12)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !pending.isEmpty {
                        Text("还需要跟进").companionFont(size: 13, weight: .semibold).foregroundStyle(.secondary)
                        ForEach(pending.prefix(8)) { item in
                            HStack {
                                Image(systemName: "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.content)
                                    Text(DiscussionPresentation.dueLabel(item.dueAt)).companionFont(size: 12).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("查看待办") {
                                    panelState.pendingSettingsTab = "tasks"
                                }
                                .buttonStyle(CompanionPressStyle())
                                .foregroundStyle(CompanionPalette.jadeInk)
                            }
                           .companionFont(size: 14)
                       }
                        if pending.count > 8 {
                            Button("还有 \(pending.count - 8) 件在待办里") {
                                panelState.pendingSettingsTab = "tasks"
                            }
                            .buttonStyle(CompanionPressStyle())
                            .foregroundStyle(CompanionPalette.jadeInk)
                            .companionFont(size: 13, weight: .medium)
                        }
                    }
                }
                Text("根据已同步的关注对话生成。")
                    .companionFont(size: 12)
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
                        .companionFont(size: 10)
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CompanionIconButtonStyle())
                .accessibilityLabel("查看前一天日报")
                .help(previousDayHoldReason ?? "")
                .accessibilityHint(previousDayHoldReason ?? "")
                .disabled(monitor.dailyReportIsLoading)

                Text("日报 · \(dateText(monitor.dailyReportViewedDate))")
                    .companionFont(size: 12, weight: .semibold)
                    .foregroundColor(.primary)

                Button(action: nextDay) {
                    Image(systemName: "chevron.right")
                        .companionFont(size: 10)
                        .foregroundColor(canGoNext ? .secondary : .secondary.opacity(0.45))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CompanionIconButtonStyle())
                .accessibilityLabel("查看后一天日报")
                .help(nextDayHoldReason ?? "")
                .accessibilityHint(nextDayHoldReason ?? "")
                .disabled(!canGoNext || monitor.dailyReportIsLoading)
            }
            .padding(.leading, 4)

            Spacer()

            Button(action: exportReport) {
                Image(systemName: "square.and.arrow.up")
                    .companionFont(size: 10)
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CompanionIconButtonStyle())
            .disabled(monitor.dailyReportIsLoading || monitor.dailyReport == nil)
            .accessibilityLabel("导出今日小结")
            .help(exportHoldReason ?? "导出 Markdown")
            .accessibilityHint(exportHoldReason ?? "")

            Button(action: {
                guard !monitor.dailyReportIsLoading else { return }
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                Group {
                    if monitor.dailyReportIsLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .companionFont(size: 10)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(CompanionIconButtonStyle())
            .disabled(monitor.dailyReportIsLoading)
            .accessibilityLabel(monitor.dailyReportIsLoading ? "正在整理…" : "刷新今日小结")
            .help(monitor.dailyReportIsLoading ? "正在整理…" : "刷新今日小结")
            .accessibilityHint(monitor.dailyReportIsLoading ? "正在整理…" : "")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var canGoNext: Bool {
        !Calendar.current.isDateInToday(monitor.dailyReportViewedDate)
    }

    private var nextDayHoldReason: String? {
        if monitor.dailyReportIsLoading { return "正在整理…" }
        if !canGoNext { return scope == .weekly ? "已经是本周" : "已经是今天" }
        return nil
    }

   private var previousDayHoldReason: String? {
       monitor.dailyReportIsLoading ? "正在整理…" : nil
   }

    private func weeklyEmptyCopy(connected: Bool, watching: Bool) -> String {
        if !connected { return "这一周还没有整理出事项。连上微信后会出现在这里。" }
        if !watching { return "这一周还没有整理出事项。先选要关注的对话。" }
        return "这一周还没有整理出事项。今天的待办出现后会汇总到这里。"
    }

    @ViewBuilder
    private func weeklyEmptyMove(connected: Bool, watching: Bool) -> some View {
        if !connected {
            Button("检查连接") { panelState.pendingSettingsTab = "system" }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("检查微信连接")
        } else if !watching {
            Button("关注谁") { panelState.pendingSettingsTab = "contacts" }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("去选要关注的对话")
        } else {
            Button("看今天") { panelState.pendingSettingsTab = "today" }
                .buttonStyle(CompanionPressStyle())
                .foregroundStyle(CompanionPalette.jadeInk)
                .accessibilityLabel("去今天看待办")
        }
    }

   private var exportHoldReason: String? {
        if monitor.dailyReportIsLoading { return "正在整理…" }
        if scope == .daily && monitor.dailyReport == nil { return "还没有今日小结" }
        return nil
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
            exportMessage = CompanionInteractionCopy.dailyExportFailed
            return
        }
        exportedReportURL = url
        exportFailed = false
        exportMessage = "小结已导出。可在访达中查看文件。"
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
