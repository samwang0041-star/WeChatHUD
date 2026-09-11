import SwiftUI

/// Inspect the real discussion window used as an extraction anchor, rather than
/// routing an old task to today's unrelated conversation tail.
struct DiscussionSourceView: View {
    @EnvironmentObject var reader: WeChatReader
    @EnvironmentObject var monitor: ChatMonitor
    @Environment(\.dismiss) private var dismiss
    let item: DiscussionItem
    var embedded: Bool = false
    var onClose: (() -> Void)? = nil
    var onCorrect: (() -> Void)? = nil
    @State private var messages: [MessageInfo] = []
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("这件事从哪里来").font(.title2.weight(.semibold))
                    Text(monitor.displayName(for: item.chatUsername)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let onClose { onClose() } else { dismiss() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭原文")
            }
            Text(item.content).font(.headline).textSelection(.enabled)
            if !embedded {
                Text("显示已核实锚点及之前最多 40 条原始消息，用来对照原话，不是发送给 AI 的底稿。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            if loading {
                ProgressView("读取本地聊天记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView("暂时无法显示原始讨论", systemImage: "text.bubble", description: Text(failure ?? "本机未保留这个时间窗口的记录，或当前账号无法读取。AI 提取内容不等同于已验证的原文。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(message.senderName.isEmpty ? "未知发送者" : message.senderName).font(.headline)
                                    Spacer()
                                    Text(Date(timeIntervalSince1970: Double(message.createTime)), format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(message.text).font(.body).textSelection(.enabled)
                                if message.id == item.anchorMsgUID {
                                    Text("已识别的关键原话").font(.caption.weight(.semibold)).foregroundStyle(CompanionPalette.jade)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    monitor.openWeChatChat(item.chatUsername)
                } label: {
                    Label("在微信中查看", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("更正归属") { onCorrect?() }
                    .buttonStyle(.bordered)
            }
            Label("AI 整理，可更正。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(embedded ? 16 : 24)
        .frame(minWidth: embedded ? 280 : 640, minHeight: embedded ? 360 : 560, alignment: .topLeading)
        .task {
            defer { loading = false }
            guard !PreviewRuntime.isEnabled else {
                if let detail = item.detail, !detail.isEmpty {
                    messages = [
                        MessageInfo(id: item.anchorMsgUID, localId: 1, chatUsername: item.chatUsername, chatName: item.chatName, senderUsername: "preview", senderName: item.chatName, text: detail, baseType: 1, subType: 0, createTime: item.sourceTimestamp)
                    ]
                } else {
                    failure = "演示事项为虚构数据，没有真实微信原文。"
                }
                return
            }
            guard !reader.hasAccountSwitched(),
                  let cursor = DiscussionSourceWindow.anchorCursor(uid: item.anchorMsgUID, timestamp: item.sourceTimestamp) else {
                failure = "无法确认这条事项的原始锚点或账号。未用当前聊天记录替代来源。"
                return
            }
            do {
                let fetched = try reader.getMessages(chatUsername: item.chatUsername, limit: 40, afterCursor: nil,
                    oldestFirst: false, beforeCursor: cursor)
                guard let verified = DiscussionSourceWindow.verified(
                    fetched, anchorUID: item.anchorMsgUID, chatUsername: item.chatUsername,
                    timestamp: item.sourceTimestamp
                ) else {
                    failure = "未找到与该事项完全对应的原始锚点，无法确认准确讨论窗口。记录可能已被清理或迁移。"
                    return
                }
                messages = verified
            } catch { failure = "读取失败。请在连接与数据中检查账号目录和访问材料，然后重试。" }
        }
    }
}


/// Source identity is checked before any fetched text is shown as evidence.
enum DiscussionSourceWindow {
    static func anchorCursor(uid: String, timestamp: Int) -> (lastCreateTime: Int, lastLocalId: Int)? {
        guard uid.contains("/"), let component = uid.split(separator: "/").last,
              let localID = Int(component), localID > 0 else { return nil }
        return (timestamp, localID)
    }

    static func verified(_ messages: [MessageInfo], anchorUID: String, chatUsername: String, timestamp: Int) -> [MessageInfo]? {
        guard let cursor = anchorCursor(uid: anchorUID, timestamp: timestamp),
              messages.contains(where: {
                  $0.id == anchorUID && $0.chatUsername == chatUsername &&
                  $0.createTime == timestamp && $0.localId == cursor.lastLocalId
              }) else { return nil }
        return Array(messages.filter {
            $0.chatUsername == chatUsername &&
            ($0.createTime < timestamp || ($0.createTime == timestamp && $0.localId <= cursor.lastLocalId))
        }.sorted {
            $0.createTime != $1.createTime ? $0.createTime < $1.createTime : $0.localId < $1.localId
        }.suffix(40))
    }
}
