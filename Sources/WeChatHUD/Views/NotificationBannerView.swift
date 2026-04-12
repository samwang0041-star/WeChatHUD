import SwiftUI

struct NotificationBannerView: View {
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

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(notification.isVIP ? Color.yellow : (notification.isAtMention ? Color.red : Color.orange))
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
