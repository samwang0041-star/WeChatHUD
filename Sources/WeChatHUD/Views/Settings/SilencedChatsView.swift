import SwiftUI

struct SilencedChatsView: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("被永久静音的对话不会出现在收件箱中。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            let silenced = monitor.silencedItems

            if silenced.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(silenced) { item in
                        silencedRow(item)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))
            Text("没有静音的对话")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func silencedRow(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.chatName)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                if let summary = item.aiSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.preview)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("取消静音") {
                monitor.unsilenceInboxItem(item)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
