import SwiftUI

struct NotificationBannerView: View {
    let notification: HUDNotification

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(notification.isAtMention ? Color.red : Color.orange)
                .frame(width: 8, height: 8)

            Text(notification.chatName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Text("·")
                .foregroundColor(.secondary)

            Text("\(notification.senderName): \"\(notification.snippet)\"")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
