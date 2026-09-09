import SwiftUI

struct InsightAttentionBar: View {
    let overview: ChatInsightEngine.GlobalOverview
    let briefing: GlobalBriefing?
    let onJumpToChat: (String) -> Void

    var body: some View {
        let aiItems = briefing?.actionRequired ?? []
        let hasOverdueChats = overview.overdueChats > 0
        let hasOverdueCommits = overview.overdueCommitments > 0
        let hasNeglected = !overview.neglectedHighValue.isEmpty
        let anything = !aiItems.isEmpty || hasOverdueChats || hasOverdueCommits || hasNeglected

        if anything {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text("需要你立即处理")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                    Spacer()
                }

                if !aiItems.isEmpty {
                    ForEach(Array(aiItems.prefix(5).enumerated()), id: \.offset) { _, item in
                        actionItemRow(
                            source: item.source,
                            what: item.what,
                            hours: item.waitingHours,
                            urgency: item.urgency
                        )
                    }
                } else {
                    if hasOverdueChats {
                        actionCountRow(
                            icon: "clock.badge.exclamationmark",
                            text: "\(overview.overdueChats) 个关注的对话待回超时",
                            color: .red
                        )
                    }
                    if hasOverdueCommits {
                        actionCountRow(
                            icon: "checkmark.circle.trianglebadge.exclamationmark",
                            text: "\(overview.overdueCommitments) 条承诺已过期",
                            color: .red
                        )
                    }
                    if hasNeglected {
                        let preview = overview.neglectedHighValue.prefix(3).map(\.name).joined(separator: "、")
                        actionCountRow(
                            icon: "person.slash",
                            text: "重要联系人冷落: \(preview)",
                            color: .orange
                        )
                    }
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.06))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.red.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private func actionItemRow(source: String, what: String, hours: Double, urgency: String) -> some View {
        Button(action: { onJumpToChat(source) }) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(urgency == "高" ? Color.red : urgency == "中" ? Color.orange : Color.gray)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(source)
                            .font(.system(size: 12, weight: .semibold))
                        if hours > 0 {
                            Text("· 等 \(formatHoursShort(hours))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(what)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.75))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionCountRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.85))
            Spacer()
        }
    }

    private func formatHoursShort(_ hours: Double) -> String {
        if hours < 1 { return "\(Int(hours * 60))m" }
        if hours < 24 { return "\(Int(hours))h" }
        return "\(Int(hours / 24))d"
    }
}
