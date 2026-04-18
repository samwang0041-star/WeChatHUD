import SwiftUI
import AppKit

/// 日报 tab — daily retrospective summary, tomorrow's first task,
/// commitment tracking, and a copyable WeChat daily report draft.
struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    enum ReportMode: String, CaseIterable {
        case daily = "日报"
        case weekly = "周报"
    }
    @State private var reportMode: ReportMode = .daily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode toggle
            HStack(spacing: 0) {
                Picker("", selection: $reportMode) {
                    ForEach(ReportMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                .controlSize(.small)
                Spacer()
                Button(action: {
                    Task { await monitor.loadDailyReport(force: true) }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Divider().background(Color.white.opacity(0.07))

            if reportMode == .daily {
                dailyContent
            } else {
                weeklyContent
            }
        }
        .task {
            await monitor.loadDailyReport()
        }
    }

    // MARK: - Daily content

    private var dailyContent: some View {
        Group {
            if monitor.dailyReport == nil && monitor.dailyReportGeneratedAt == nil {
                loadingState
            } else if let report = monitor.dailyReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        overviewSection(report: report)
                        divider
                        summarySection(report: report)
                        divider
                        tomorrowSection(report: report)
                        divider
                        commitmentsSection
                        divider
                        wechatDraftSection(report: report)
                    }
                    .padding(.bottom, 8)
                }
            } else {
                emptyState("日报生成失败，请稍后重试")
            }
        }
    }

    // MARK: - Weekly content

    private var weeklyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                weeklyOverview
                divider
                weeklyHierarchyTasks
                divider
                weeklyCommitments
                divider
                weeklyPendingAsks
                divider
                exportButton
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Weekly hierarchy tasks (user-requested feature)
    //
    // Slices extracted `DiscussionItem`s by the counterpart's
    // relationship hierarchy so the user gets their weekly read-out
    // of: 上级派给我 / 我派给下级 / 平级协作. Filters to the last 7
    // days based on `source_timestamp`.

    private var weeklyItems: [DiscussionItem] {
        let weekAgo = Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)
        return monitor.discussionItems.filter { item in
            item.sourceTimestamp >= weekAgo
        }
    }

    /// (item, hierarchy of the counterpart chat) pairs.
    private func itemsWithHierarchy() -> [(item: DiscussionItem, hierarchy: RelationshipProfile.Hierarchy?)] {
        weeklyItems.map { item in
            let profile = monitor.relationshipProfile(for: item.chatUsername)
            return (item, profile?.hierarchy)
        }
    }

    /// Items that qualify as "上级派给我":
    /// counterpart is superior AND the item is owned by me.
    private var itemsFromSuperior: [DiscussionItem] {
        itemsWithHierarchy()
            .filter { $0.hierarchy == .superior && $0.item.owner == .mine }
            .map(\.item)
    }

    /// Items that qualify as "我派给下级":
    /// counterpart is subordinate AND the item is owned by them.
    private var itemsToSubordinate: [DiscussionItem] {
        itemsWithHierarchy()
            .filter { $0.hierarchy == .subordinate && $0.item.owner == .theirs }
            .map(\.item)
    }

    /// 平级协作: anything in a peer relationship, regardless of owner.
    private var itemsWithPeers: [DiscussionItem] {
        itemsWithHierarchy()
            .filter { $0.hierarchy == .peer }
            .map(\.item)
    }

    private var weeklyHierarchyTasks: some View {
        VStack(alignment: .leading, spacing: 10) {
            hierarchyGroup(
                title: "上级派给我",
                items: itemsFromSuperior,
                emptyHint: "本周上级没有新任务给你",
                accent: .orange
            )
            hierarchyGroup(
                title: "我派给下级",
                items: itemsToSubordinate,
                emptyHint: "本周没有派出去的任务",
                accent: .blue
            )
            hierarchyGroup(
                title: "平级协作",
                items: itemsWithPeers,
                emptyHint: "本周没有跟平级同事的协作事项",
                accent: .gray
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func hierarchyGroup(
        title: String,
        items: [DiscussionItem],
        emptyHint: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(accent.opacity(0.6)).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Text("·  \(items.count) 条")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .monospacedDigit()
                Spacer()
            }
            if items.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.leading, 12)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.kind.iconName)
                                .font(.system(size: 9))
                                .foregroundColor(accent.opacity(0.7))
                                .frame(width: 10, alignment: .center)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.content)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(item.status == .done ? 0.4 : 0.85))
                                    .strikethrough(item.status == .done)
                                    .lineLimit(2)
                                Text(item.chatName)
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            Spacer(minLength: 0)
                            statusBadge(for: item)
                        }
                        .padding(.vertical, 2)
                        .padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func statusBadge(for item: DiscussionItem) -> some View {
        Group {
            switch item.status {
            case .done:
                Text("已完成")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(3)
            case .pending:
                if let due = item.dueAt, Date() > due {
                    Text("超期")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(3)
                } else {
                    EmptyView()
                }
            default: EmptyView()
            }
        }
    }

    // MARK: - Export

    private var exportButton: some View {
        HStack {
            Spacer()
            Button(action: copyWeeklyReport) {
                Label("复制周报 Markdown", systemImage: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func copyWeeklyReport() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let weekStart = df.string(from: now.addingTimeInterval(-7 * 86400))
        let weekEnd = df.string(from: now)
        var lines = ["# 本周工作总结 (\(weekStart) – \(weekEnd))", ""]

        func section(_ title: String, items: [DiscussionItem]) {
            lines.append("## \(title)")
            if items.isEmpty {
                lines.append("（无）")
            } else {
                for item in items {
                    var line = "- \(item.content)"
                    if item.status == .done { line += " ✅" }
                    line += "  _(\(item.chatName))_"
                    lines.append(line)
                }
            }
            lines.append("")
        }
        section("上级派给我", items: itemsFromSuperior)
        section("我派给下级", items: itemsToSubordinate)
        section("平级协作", items: itemsWithPeers)

        let md = lines.joined(separator: "\n")
        WeChatLauncher.copyText(md)
    }

    private var weeklyOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("本周概览")
            let pending = monitor.commitments.filter { $0.status == .pending }.count
            let fulfilled = monitor.commitments.filter { $0.status == .fulfilled }.count
            let overdue = monitor.commitments.filter { $0.status == .overdue }.count

            HStack(spacing: 6) {
                statPill(label: "待处理承诺", value: "\(pending)", color: pending > 0 ? .orange : .white)
                statPill(label: "已完成", value: "\(fulfilled)", color: fulfilled > 0 ? .green : .white)
                statPill(label: "超期", value: "\(overdue)", color: overdue > 0 ? .red : .white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var weeklyCommitments: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("本周承诺", count: monitor.commitments.count)
            if monitor.commitments.isEmpty {
                Text("本周暂无承诺记录")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 6)
            } else {
                ForEach(sortedCommitments) { commitment in
                    CommitmentRow(commitment: commitment)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var weeklyPendingAsks: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("本周待办")
            Text("查看「待回」和「追赶」标签页获取最新待办事项")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .padding(.vertical, 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Loading

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text("正在生成日报…")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    // MARK: - Overview

    private func overviewSection(report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("今日概览")
            HStack(spacing: 6) {
                statPill(
                    label: "消息",
                    value: "\(monitor.stats.unreadCount)",
                    color: .blue
                )
                statPill(
                    label: "待处理",
                    value: "\(report.stats.asksPending)",
                    color: report.stats.asksPending > 0 ? .orange : .white
                )
                statPill(
                    label: "承诺",
                    value: "\(pendingCommitmentsCount)",
                    color: pendingCommitmentsCount > 0 ? .yellow : .white
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var pendingCommitmentsCount: Int {
        monitor.commitments.filter { $0.status == .pending || $0.status == .overdue }.count
    }

    private func statPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color == .white ? .white : color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color == .white ? Color.white.opacity(0.07) : color.opacity(0.12))
        .cornerRadius(5)
    }

    // MARK: - Summary

    private func summarySection(report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("今日总结")
            Text(report.todaySummary)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Tomorrow

    private func tomorrowSection(report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("明天第一件事")
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.85))
                    .padding(.top, 1)
                Text(report.tomorrowFirstThing.action)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Commitments

    private var commitmentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("承诺追踪", count: monitor.commitments.count)
            if monitor.commitments.isEmpty {
                Text("暂无承诺记录")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 6)
            } else {
                ForEach(sortedCommitments) { commitment in
                    CommitmentRow(commitment: commitment)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var sortedCommitments: [Commitment] {
        monitor.commitments.sorted { a, b in
            statusRank(a.status) < statusRank(b.status)
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

    // MARK: - WeChat Draft

    private func wechatDraftSection(report: AIDailyRetrospector.Retrospective) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("微信日报草稿")
                Spacer()
                Button(action: {
                    WeChatLauncher.copyText(report.wechatDailyReport)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("复制")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 14)

            Text(report.wechatDailyReport)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Shared

    private var divider: some View {
        Divider()
            .background(Color.white.opacity(0.07))
            .padding(.horizontal, 10)
    }

    private func sectionLabel(_ label: String, count: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            if let count = count {
                Text("\(count)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }
}

// MARK: - Commitment Row

private struct CommitmentRow: View {
    let commitment: Commitment

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            statusDot
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(commitment.content)
                    .font(.system(size: 11))
                    .foregroundColor(contentColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
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
        }
        .padding(.vertical, 3)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: Color {
        switch commitment.status {
        case .overdue:   return .red
        case .pending:   return .orange
        case .fulfilled: return .green
        case .cancelled: return .white.opacity(0.25)
        }
    }

    private var contentColor: Color {
        switch commitment.status {
        case .overdue:   return .red.opacity(0.9)
        case .cancelled: return .white.opacity(0.35)
        default:         return .white.opacity(0.82)
        }
    }

    private func deadlineText(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff < 0 {
            let past = Int(-diff)
            if past < 3600  { return "已超期 \(past / 60)分" }
            if past < 86400 { return "已超期 \(past / 3600)时" }
            return "已超期 \(past / 86400)天"
        }
        if diff < 3600  { return "\(Int(diff) / 60)分后" }
        if diff < 86400 { return "\(Int(diff) / 3600)时后" }
        return "\(Int(diff) / 86400)天后"
    }

    private func deadlineColor(_ date: Date) -> Color {
        let diff = date.timeIntervalSince(Date())
        if diff < 0       { return .red.opacity(0.85) }
        if diff < 3600    { return .orange.opacity(0.9) }
        return .white.opacity(0.4)
    }
}
