import XCTest
@testable import WeChatHUD

/// 群 @ 溯源在「通知时间戳比源消息新」时的覆盖度。
///
/// 横幅时间戳取 min(now, max(msg.createTime, session.lastTimestamp))，所以
/// 对于 create_time 偏旧的转发/机器人消息，通知时间戳会明显晚于源消息本身，二者
/// 之间可能隔着几十条闲聊。旧实现只按 24 条一页向后翻，且在一页不满时立即收敛，
/// 于是源消息落在窗口尾部时直接溯源失败（返回 nil → 群上下文整段缺失）。
/// 现在的实现先用已知时间戳做一次带上限的查询，常见路径一条查询即可命中。
final class GroupMentionStaleTimestampCoverageTests: XCTestCase {

    func testStaleNotificationTimestampStillResolvesSourceBelowPagedWindow() {
        // 源消息在 ts=100（通知时间戳 200，慢了 100 秒），其后还有 60 条闲聊。
        var messages: [MessageInfo] = [
            message("src", "@你 预算表发我一下", 100, 1)
        ]
        for index in 1...60 {
            messages.append(message("f\(index)", "闲聊\(index)", 100 + index, index + 1))
        }
        let provider = CountingProvider(messages: messages)

        let result = GroupContextSourceLoader.load(
            notification: notification(id: "src", ts: 200),
            reader: provider
        )

        XCTAssertNotNil(result, "源消息比通知时间戳旧时必须仍能溯源")
        XCTAssertEqual(result?.first?.id, "src")
        XCTAssertEqual(result?.dropFirst().prefix(3).map(\.id), ["f1", "f2", "f3"])
        // 旧实现：第一页只有 24 条闲聊、最后一页不满即收敛 → 3 次查询后返回 nil。
        // 现在：1 次快速查询命中 + 2 次窗口查询 = 3 次，且结果正确。
        XCTAssertLessThanOrEqual(provider.callCount, 3)
    }

    private func notification(id: String, ts: TimeInterval) -> HUDNotification {
        HUDNotification(
            chatUsername: "room@chatroom", chatName: "群", senderUsername: "bob",
            senderName: "Bob", attentionLevel: .watch, messageID: id,
            rawText: "@你 预算表发我一下", snippet: "@你 预算表发我一下", isAtMention: true,
            timestamp: Date(timeIntervalSince1970: ts), kind: .groupAt
        )
    }

    private func message(_ id: String, _ text: String, _ ts: Int, _ localID: Int) -> MessageInfo {
        MessageInfo(
            id: id, localId: localID, chatUsername: "room@chatroom", chatName: "群",
            senderUsername: "sender", senderName: "成员", text: text,
            baseType: 1, subType: 0, createTime: ts
        )
    }
}

/// 记录 getMessages 调用次数的 provider，过滤/游标语义与
/// GroupContextSourceLoaderTests.Provider 保持一致（endTime 为开区间，
/// beforeCursor 含同一秒的 localId）。
private final class CountingProvider: GroupContextMessageProvider {
    let messages: [MessageInfo]
    private(set) var callCount = 0

    init(messages: [MessageInfo]) {
        self.messages = messages
    }

    func getMessages(
        chatUsername: String, limit: Int, sinceLocalId: Int?,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)?, oldestFirst: Bool,
        startTime: Int?, endTime: Int?,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    ) throws -> [MessageInfo] {
        callCount += 1
        let filtered = messages.filter { message in
            guard message.chatUsername == chatUsername else { return false }
            if let startTime, message.createTime < startTime { return false }
            if let endTime, message.createTime >= endTime { return false }
            if let cursor = afterCursor,
               !(message.createTime > cursor.lastCreateTime ||
                 (message.createTime == cursor.lastCreateTime && message.localId > cursor.lastLocalId)) { return false }
            if let cursor = beforeCursor,
               !(message.createTime < cursor.lastCreateTime ||
                 (message.createTime == cursor.lastCreateTime && message.localId <= cursor.lastLocalId)) { return false }
            return true
        }
        let sorted = filtered.sorted {
            if $0.createTime != $1.createTime {
                return oldestFirst ? $0.createTime < $1.createTime : $0.createTime > $1.createTime
            }
            return oldestFirst ? $0.localId < $1.localId : $0.localId > $1.localId
        }
        return Array(sorted.prefix(limit))
    }
}
