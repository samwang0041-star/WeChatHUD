import SwiftUI

struct NotificationBannerView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var panelState: PanelState
    let notification: HUDNotification

    /// "昵称: 内容" preview. For private chats chatName == senderName,
    /// so it collapses to "senderName: snippet". For groups we prefix the
    /// group name so you can tell which group the message is from.
    private var previewText: String {
        if notification.chatName == notification.senderName {
            return "\(notification.senderName): \(notification.snippet)"
        } else {
            return "\(notification.chatName) · \(notification.senderName): \(notification.snippet)"
        }
    }

    private var badgeColor: Color {
        switch notification.presentationSemanticState {
        case .privateVIPRisk:
            return .yellow
        case .groupMentionFYI:
            return .blue
        case .privateInfoOnly, .groupInfoOnly:
            return .white.opacity(0.45)
        default:
            return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)

            Text(previewText)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            if notification.isVIP {
                Text("VIP")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.12))
                    .cornerRadius(3)
            }

            if notification.canExplainContext {
                GroupContextBriefingButton(notification: notification, compact: true)
            }

            Spacer(minLength: 0)

            // Quick action buttons
            Button(action: {
                WeChatLauncher.openChat(named: notification.chatName)
            }) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, height: 20)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .help("在微信中打开")

            Button(action: {
                monitor.silenceChat(notification.chatUsername)
                panelState.collapse()
            }) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 22, height: 20)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .help("静默处理")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            panelState.showChatDetail(
                chatUsername: notification.chatUsername,
                chatName: notification.chatName
            )
        }
    }
}
