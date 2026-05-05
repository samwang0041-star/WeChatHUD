import SwiftUI
import AppKit

/// A single row in the unified inbox list.
/// Shows priority dot, contact info, status labels, and hover actions.
struct InboxRowView: View {
    @EnvironmentObject var panelState: PanelState
    @EnvironmentObject var monitor: ChatMonitor
    let item: InboxItem
    let onDismiss: () -> Void
    var onSnooze: ((Date) -> Void)? = nil
    var onSilence: (() -> Void)? = nil

    @State private var hovered = false
    @State private var expanded = false
    @State private var showSnoozePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                priorityDot
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    // First line: name + badges + status + time
                    firstLine
                    // Second line: summary or preview
                    secondLine
                    // Tier 2: auto-briefing for group @mentions — a one-
                    // line "他想你: ..." that appears without the user
                    // having to click. The view itself decides whether
                    // to render anything (empty when not applicable).
                    inlineBriefingLine
                }

                if hovered {
                    hoverButtons
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovered ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { expanded.toggle() }
            .contextMenu {
                contextMenuContent
            }

            if expanded {
                ActionPanelView(item: item)
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(item.actionRequired ? "标为已处理" : "隐藏这条更新") {
            onDismiss()
        }
        Menu("稍后提醒") {
            Button("15 分钟后") { onSnooze?(Date().addingTimeInterval(15 * 60)) }
            Button("1 小时后") { onSnooze?(Date().addingTimeInterval(60 * 60)) }
            Button("明天上午") { onSnooze?(tomorrowMorning()) }
        }
        Button("静音此对话") {
            onSilence?()
        }

        Divider()

        Button("在微信中打开") {
            WeChatLauncher.openChat(named: item.chatName)
        }
        Button("查看对话详情") {
            panelState.showChatDetail(chatUsername: item.chatUsername, chatName: item.chatName)
        }
        Button("复制消息原文") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.preview, forType: .string)
        }
        if let summary = item.aiSummary, !summary.isEmpty {
            Button("复制 AI 摘要") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
            }
        }

        Divider()

        if item.isWhitelisted {
            if item.isVIP {
                Button("降为普通关注") {
                    monitor.setInboxItemVIP(item, isVIP: false)
                }
            } else {
                Button("设为 VIP") {
                    monitor.setInboxItemVIP(item, isVIP: true)
                }
            }
            Button("取消关注此对话", role: .destructive) {
                monitor.untrackInboxItem(item)
            }
        } else {
            Button(item.isGroup ? "关注此群聊" : "关注此联系人") {
                monitor.setInboxItemVIP(item, isVIP: !item.isGroup)
            }
        }

        if item.isGroup, !item.senderName.isEmpty {
            Divider()
            Button("忽略 \(item.senderName) 的消息") {
                monitor.ignoreInboxItemSender(item)
            }
        }
    }

    private func tomorrowMorning() -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.day = (components.day ?? 0) + 1
        components.hour = 9
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components) ?? Date().addingTimeInterval(24 * 3600)
    }

    // MARK: - First Line

    private var firstLine: some View {
        HStack(spacing: 4) {
            Text(item.chatName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            if item.isVIP {
                Text("VIP")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(2)
            }

            if item.semanticState == .groupMentionFYI {
                Text("提到你")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.blue.opacity(0.9))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(2)
            }

            if item.isVIP, let mood = item.moodEmoji, !mood.isEmpty {
                Text(mood)
                    .font(.system(size: 11))
            }

            if item.isOverdue {
                Text("超时")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(2)
            }

            if item.replied {
                Text("已回复")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(2)
            }

            Spacer()

            Text(relativeTime(item.timestamp))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    // MARK: - Second Line

    private var secondLine: some View {
        HStack(spacing: 0) {
            if item.isGroup, !item.senderName.isEmpty {
                Text(item.senderName + ": ")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            if let summary = item.aiSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
            } else {
                Text(item.preview)
                    .font(.system(size: 11).italic())
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Tier 2: inline briefing

    /// Find the HUDNotification that corresponds to this inbox item.
    /// Inbox items are keyed by chatUsername, so a row for a group
    /// @mention matches the most recent @mention notification for that
    /// chat in `recentNotifications` (which is capped to ~10 items).
    private var matchingNotification: HUDNotification? {
        guard item.isGroup, item.isAtMention else { return nil }
        return monitor.recentNotifications.first {
            $0.chatUsername == item.chatUsername && $0.canExplainContext
        }
    }

    /// Rendered "他想你: ..." inline briefing, or a compact "分析中"
    /// placeholder while the briefing is in flight. Returns nil (row
    /// doesn't render this region) when the item isn't a group
    /// @mention or when no briefing activity has been started yet —
    /// keeps rows that don't need this feature visually unchanged.
    @ViewBuilder
    private var inlineBriefingLine: some View {
        if let notif = matchingNotification {
            let state = monitor.groupContextState(for: notif)
            if state.isLoading && state.briefing == nil {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.7))
                    Text("分析中…")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            } else if let briefing = state.briefing {
                // Only true action rows get the actionable line. FYI
                // mentions stay neutral so a plain @ does not become
                // "需要你处理" by copy alone.
                let summaryText: String = {
                    if item.semanticState == .groupActionRequired,
                       let action = briefing.deepSuggestedAction,
                       !action.isEmpty {
                        return action
                    }
                    return briefing.whyMentioned
                }()
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.85))
                    Text(summaryText)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Priority Dot

    private var priorityDot: some View {
        Circle()
            .fill(priorityColor)
            .frame(width: 8, height: 8)
    }

    private var priorityColor: Color {
        switch item.semanticState {
        case .privateActionRequired, .privateVIPRisk, .groupActionRequired:
            switch item.priority {
            case .p0: return .red
            case .p1: return .yellow
            case .p2: return .white.opacity(0.35)
            }
        case .groupMentionFYI, .groupDecisionOnly:
            return .blue.opacity(0.75)
        default:
            return .white.opacity(0.2)
        }
    }

    // MARK: - Hover Buttons

    private var hoverButtons: some View {
        HStack(spacing: 6) {
            if !item.replied {
                Button(action: {
                    panelState.popoverOpen = true
                    showSnoozePopover = true
                }) {
                    Text("\u{23F0}")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSnoozePopover, arrowEdge: .bottom) {
                    SnoozePopoverContent { date in
                        showSnoozePopover = false
                        panelState.popoverOpen = false
                        onSnooze?(date)
                    }
                }
                .onChange(of: showSnoozePopover) { _, isOpen in
                    panelState.popoverOpen = isOpen
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时" }
        return "\(hours / 24)天"
    }
}

// MARK: - Snooze Popover Content

struct SnoozePopoverContent: View {
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            snoozeButton(label: "30 分钟后", date: Date().addingTimeInterval(30 * 60))
            Divider().opacity(0.2)
            snoozeButton(label: "2 小时后", date: Date().addingTimeInterval(2 * 3600))
            Divider().opacity(0.2)
            snoozeButton(label: "今晚 20:00", date: tonightAt20())
            Divider().opacity(0.2)
            snoozeButton(label: "明早 09:00", date: tomorrowAt09())
        }
        .padding(.vertical, 4)
        .frame(width: 140)
    }

    private func snoozeButton(label: String, date: Date) -> some View {
        Button(action: { onSelect(date) }) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tonightAt20() -> Date {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = 20
        components.minute = 0
        components.second = 0
        let tonight = cal.date(from: components) ?? now
        // If already past 20:00 today, use tomorrow
        return tonight > now ? tonight : cal.date(byAdding: .day, value: 1, to: tonight) ?? tonight
    }

    private func tomorrowAt09() -> Date {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 0
        components.second = 0
        let today9 = cal.date(from: components) ?? now
        return cal.date(byAdding: .day, value: 1, to: today9) ?? now
    }
}
