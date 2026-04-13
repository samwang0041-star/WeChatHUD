import SwiftUI
import AppKit

/// A single row in the unified inbox list.
/// Shows priority dot, contact info, status labels, and hover actions.
struct InboxRowView: View {
    @EnvironmentObject var panelState: PanelState
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
                Button("复制消息原文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.preview, forType: .string)
                }
                Button("在微信中打开") {
                    WeChatLauncher.openChat(named: item.chatName)
                }
                Divider()
                Button("查看对话详情") {
                    panelState.showChatDetail(chatUsername: item.chatUsername, chatName: item.chatName)
                }
                Divider()
                Button("静音此对话") {
                    onSilence?()
                }
                if item.isVIP {
                    Button("降为普通关注") {
                        // Demote VIP — requires store access, defer to monitor
                    }
                } else if item.isWhitelisted {
                    Button("设为 VIP") {
                        // Promote to VIP — requires store access
                    }
                }
                if item.isGroup {
                    Button("忽略此发送人") {
                        // Add to ignored senders — not yet implemented
                    }
                }
            }

            if expanded {
                ActionPanelView(item: item)
            }
        }
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

    // MARK: - Priority Dot

    private var priorityDot: some View {
        Circle()
            .fill(priorityColor)
            .frame(width: 8, height: 8)
    }

    private var priorityColor: Color {
        guard item.actionRequired else { return .white.opacity(0.2) }
        switch item.priority {
        case .p0: return .red
        case .p1: return .yellow
        case .p2: return .white.opacity(0.35)
        }
    }

    // MARK: - Hover Buttons

    private var hoverButtons: some View {
        HStack(spacing: 6) {
            if !item.replied {
                Button(action: { showSnoozePopover = true }) {
                    Text("\u{23F0}")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSnoozePopover, arrowEdge: .bottom) {
                    SnoozePopoverContent { date in
                        showSnoozePopover = false
                        onSnooze?(date)
                    }
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
