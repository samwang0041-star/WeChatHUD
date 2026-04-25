import SwiftUI
import AppKit

/// 日报 tab — daily retrospective summary, tomorrow's first task,
/// commitment tracking, and a copyable WeChat daily report draft.
///
/// Weekly mode was removed in M10 — the new `复盘` tab (Plan M6.5)
/// supersedes it with custom time ranges, AI deep extraction, and
/// persistent cross-week todos. See [Plan M10] in
/// docs/superpowers/plans/2026-04-25-retrospective-tab.md.
struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("日报")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.leading, 4)
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

            dailyContent
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
