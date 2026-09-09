import XCTest
@testable import WeChatHUD

final class GroupContextSourceLoaderTests: XCTestCase {
    func testLoadsExactSourceCenteredWindowWhenLaterMemberSpoke() {
        let messages = [
            message("before", "前文", 100, 1),
            message("mention", "@你 看预算", 110, 2),
            message("later", "我补充背景", 120, 3)
        ]
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "mention", ts: 110),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(result?.map(\.id), ["before", "mention", "later"])
    }

    func testFindsHistoricalSourceBeyondNewestPage() {
        let messages = (0..<60).map { index in
            message("m\(index)", "正文\(index)", 100 + index, index + 1)
        }
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "m5", ts: 105),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(result?.first?.id, "m0")
        XCTAssertTrue(result?.contains(where: { $0.id == "m5" }) == true)
        XCTAssertFalse(result?.contains(where: { $0.id == "m40" }) == true)
    }

    func testMissingSourceReturnsNilInsteadOfUsingNewestMessage() {
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "missing", ts: 200),
            reader: Provider(messages: [message("latest", "无关", 200, 1)])
        )
        XCTAssertNil(result)
    }

    @MainActor func testSourceAnchoredAnalysisKeepsSourceOlderThan48Hours() {
        let old = message("old", "@你 旧问题", 100, 1)
        let filtered = ChatMonitor.filterGroupAnalysisMessages(
            [old], sourceAnchored: true, now: Date(timeIntervalSince1970: 100 + 49 * 3600)
        )
        XCTAssertEqual(filtered.map(\.id), ["old"])
    }

    func testLoaderWindowCanBeOrderedNewestFirstForChatAnalyzer() {
        let messages = [message("old", "旧", 100, 1), message("new", "新", 200, 2)]
        XCTAssertEqual(GroupContextSourceLoader.newestFirst(messages).map(\.id), ["new", "old"])
    }

    private func notification(id: String, ts: TimeInterval) -> HUDNotification {
        HUDNotification(
            chatUsername: "room@chatroom", chatName: "群", senderUsername: "bob",
            senderName: "Bob", attentionLevel: .watch, messageID: id,
            rawText: "@你 原文", snippet: "@你 原文", isAtMention: true,
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

private struct Provider: GroupContextMessageProvider {
    let messages: [MessageInfo]

    func getMessages(
        chatUsername: String, limit: Int, sinceLocalId: Int?,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)?, oldestFirst: Bool,
        startTime: Int?, endTime: Int?,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    ) throws -> [MessageInfo] {
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
        let ordered = filtered.sorted {
            if $0.createTime != $1.createTime { return oldestFirst ? $0.createTime < $1.createTime : $0.createTime > $1.createTime }
            return oldestFirst ? $0.localId < $1.localId : $0.localId > $1.localId
        }
        return Array(ordered.prefix(limit))
    }
}
