import XCTest
@testable import WeChatHUD

/// WeChat's recall notice names the owner with a *display name*, and two
/// members of one group can carry the same one. The match it produces drives a
/// destructive cascade with no retry (the scan watermark moves past the
/// revokemsg row either way), so an ambiguous name must record the recall
/// without tombstoning anyone's artifacts.
final class ScanEngineRecallAttributionTests: XCTestCase {

    private var root: String!
    private var store: HUDStore!

    private let base = 1_700_000_000
    private let chat = "99001@chatroom"
    private var msgA: String { "msg/0/message_1.db/MessageTable/11" }
    private var msgB: String { "msg/0/message_1.db/MessageTable/12" }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "recall-attr-\(UUID())"
        try FileManager.default.createDirectory(atPath: root!, withIntermediateDirectories: true)
        store = HUDStore(dbPath: root! + "/hud.sqlite3")
        try store.open()
        try store.upsertCommitment(
            msgUID: msgA, chatUsername: chat, chatName: "项目群",
            content: "今晚把合同发你", commitTo: "我", confidence: 1, promptVersion: "t")
        try store.upsertCommitment(
            msgUID: msgB, chatUsername: chat, chatName: "项目群",
            content: "明天上午开会", commitTo: "我", confidence: 1, promptVersion: "t")
    }

    override func tearDown() {
        store?.close()
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func message(
        _ uid: String, localId: Int, sender: String, name: String, text: String, offset: Int
    ) -> MessageInfo {
        MessageInfo(
            id: uid, localId: localId, chatUsername: chat, chatName: "项目群",
            senderUsername: sender, senderName: name, text: text,
            baseType: 1, subType: 0, createTime: base + offset
        )
    }

    private func recallRow(text: String) -> MessageInfo {
        MessageInfo(
            id: "msg/0/message_1.db/MessageTable/99", localId: 99,
            chatUsername: chat, chatName: "项目群",
            senderUsername: "wxid_admin", senderName: "群主", text: text,
            baseType: 10000, subType: 0, createTime: base + 60, sysKind: "revokemsg"
        )
    }

    private func record(
        recall: MessageInfo, candidates: [MessageInfo],
        myUsername: String = "wxid_me", myDisplayName: String = "我自己"
    ) {
        ScanEngine.recordRecall(
            recall, chatUsername: chat, candidates: candidates, contactMap: [:],
            store: store, myUsername: myUsername, myDisplayName: myDisplayName,
            mySelfNames: ["我自己"]
        )
    }

    private func liveCommitmentUIDs() -> Set<String> {
        Set(store.loadCommitments()
            .filter { $0.status == .pending || $0.status == .overdue }
            .map(\.msgUID))
    }

    func testSharedDisplayNameCannotStealTheOthersTombstone() throws {
        // 同群里两个「张伟」。管理员撤回了其中一个的一条消息 — 文本里只有名字。
        record(
            recall: recallRow(text: "群主 撤回了 \"张伟\" 的一条消息"),
            candidates: [
                message(msgA, localId: 11, sender: "wxid_zhang_a", name: "张伟",
                        text: "今晚把合同发你", offset: 10),
                message(msgB, localId: 12, sender: "wxid_zhang_b", name: "张伟",
                        text: "明天上午开会", offset: 20),
            ]
        )
        XCTAssertEqual(liveCommitmentUIDs(), [msgA, msgB],
                       "an ambiguous name must not cancel either member's commitment")
        let rows = store.loadRecalledMessages()
        XCTAssertEqual(rows.count, 1, "the recall itself is still worth recording")
        XCTAssertEqual(rows.first?.originalText, "",
                       "and it must not claim someone else's message as the withdrawn one")
    }

    func testUnambiguousNameStillCascades() throws {
        record(
            recall: recallRow(text: "群主 撤回了 \"张伟\" 的一条消息"),
            candidates: [
                message(msgA, localId: 11, sender: "wxid_zhang_a", name: "张伟",
                        text: "今晚把合同发你", offset: 10),
                message(msgB, localId: 12, sender: "wxid_lisi", name: "李四",
                        text: "明天上午开会", offset: 20),
            ]
        )
        XCTAssertEqual(liveCommitmentUIDs(), [msgB])
        XCTAssertEqual(store.loadRecalledMessages().first?.originalText, "今晚把合同发你")
    }

    func testOwnRecallIsNotGatedOnDisplayName() throws {
        // "你撤回了一条消息" resolves through the sender-id gate, not a name,
        // so the ambiguity rule must not disable the most common case.
        record(
            recall: recallRow(text: "你撤回了一条消息"),
            candidates: [
                message(msgA, localId: 11, sender: "wxid_me", name: "我自己",
                        text: "今晚把合同发你", offset: 10),
            ]
        )
        XCTAssertEqual(liveCommitmentUIDs(), [msgB])
    }

    func testUnreadFetchLimitClampsBeforeDoubling() throws {
        // `unread_count` is WeChat's column. The group branch doubles it, and an
        // unclamped Int.max trapped on the multiply and killed the resident
        // process over a page size.
        XCTAssertEqual(
            ScanEngine.unreadFetchLimit(SessionInfo(
                username: chat, isGroup: true, unreadCount: Int.max, lastTimestamp: base)),
            ScanEngine.unreadWindowCap)
        XCTAssertEqual(
            ScanEngine.unreadFetchLimit(SessionInfo(
                username: chat, isGroup: true, unreadCount: Int.min, lastTimestamp: base)), 20)
        XCTAssertEqual(
            ScanEngine.unreadFetchLimit(SessionInfo(
                username: "wxid_peer", isGroup: false, unreadCount: 40, lastTimestamp: base)), 40,
            "a private chat must still fetch exactly the unanswered tail")
    }
}
