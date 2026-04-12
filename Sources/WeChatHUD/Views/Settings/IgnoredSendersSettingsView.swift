import SwiftUI

struct IgnoredSendersSettingsView: View {
    @EnvironmentObject var store: HUDStore
    @EnvironmentObject var monitor: ChatMonitor
    @State private var ignoredSenders: [IgnoredSenderRule] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这里管理通过消息右键添加的忽略规则。被忽略的人不会再进入未读统计，白名单消息也不会继续打扰。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))

            if ignoredSenders.isEmpty {
                Text("当前没有被忽略的人。")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(ignoredSenders) { rule in
                        row(rule)
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func row(_ rule: IgnoredSenderRule) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.senderName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text(rule.chatName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                if !rule.senderUsername.isEmpty {
                    Text(rule.senderUsername)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button("取消忽略") {
                monitor.unignoreSender(
                    chatUsername: rule.chatUsername,
                    senderUsername: rule.senderUsername,
                    senderName: rule.senderName
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    reload()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    private func reload() {
        ignoredSenders = store.loadIgnoredSenders()
    }
}
