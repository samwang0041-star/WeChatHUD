import SwiftUI

/// A single row in the unified inbox list.
struct InboxRowView: View {
    let item: InboxItem
    let onDismiss: () -> Void
    @State private var hovered = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                priorityBadge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.chatName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        if item.isVIP {
                            Text("VIP")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(2)
                        }
                        if item.isGroup {
                            Text("群聊")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        Spacer()
                        Text(timeAgo(item.timestamp))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    HStack(spacing: 4) {
                        if item.isGroup {
                            Text(item.senderName + ":")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        Text(item.preview)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                if hovered {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovered ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { expanded.toggle() }

            if expanded && item.actionRequired {
                ReplyDebtExpandedView(item: item.toReplyDebtItem())
            }
        }
    }

    private var priorityBadge: some View {
        let (color, label) = priorityDisplay(item.priority, actionRequired: item.actionRequired)
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .frame(width: 22, height: 16)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private func priorityDisplay(_ p: InboxPriority, actionRequired: Bool) -> (Color, String) {
        guard actionRequired else { return (.white.opacity(0.3), "📋") }
        switch p {
        case .p0: return (.red, "P0")
        case .p1: return (.yellow, "P1")
        case .p2: return (.white.opacity(0.5), "P2")
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        return "\(hours / 24)天前"
    }
}
