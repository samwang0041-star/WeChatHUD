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

    /// 另一个同名的人这一小时没发言，也不构成"窗口里那条就是他"的证据。
    func testQuietTwinOutsideTheMatchBandStillCounts() throws {
        record(
            recall: recallRow(text: "群主 撤回了 \"张伟\" 的一条消息"),
            candidates: [
                message(msgA, localId: 11, sender: "wxid_zhang_a", name: "张伟",
                        text: "今晚把合同发你", offset: 10),
                message(msgB, localId: 12, sender: "wxid_zhang_b", name: "张伟",
                        text: "明天上午开会", offset: -3_600),
            ]
        )
        XCTAssertEqual(liveCommitmentUIDs(), [msgA, msgB],
                       "认领范围只数 10 分钟窗口会把潜水的同名者漏掉")
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

    func testUnreadableContactsDoNotPersistAGuessedRole() throws {
        ScanEngine.recordRecall(
            recallRow(text: "群主 撤回了 \"张伟\" 的一条消息"),
            chatUsername: chat,
            candidates: [
                message(msgA, localId: 11, sender: "wxid_zhang_a", name: "张伟",
                        text: "今晚把合同发你", offset: 10),
            ],
            contactMap: [:],
            contactsUnreadable: true,
            store: store,
            myUsername: "wxid_me",
            myDisplayName: "我自己",
            mySelfNames: ["我自己"]
        )
        XCTAssertTrue(store.loadRecalledMessages().isEmpty,
                      "读不到联系人时不能把撤回落成泛泛之交")
        XCTAssertEqual(liveCommitmentUIDs(), [msgA, msgB],
                       "读不到也不能先把承诺墓碑掉")
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

    /// 「已处理到这条」的水位不能带上未来的时间：`rebuildInbox` 把超过永久静音
    /// 阈值的 silencedAt 读成"这个对话永久静音"，一条时间戳超前的消息就能让对话
    /// 再也不出现；而 Double(Int64.max) 会让 Int() 直接 trap 掉常驻进程。
    func testWatermarkSecondsCannotDateAheadOfNow() throws {
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertEqual(
            MessageHelpers.watermarkSeconds(Date(timeIntervalSince1970: Double(now - 120))),
            now - 120)
        XCTAssertEqual(
            MessageHelpers.watermarkSeconds(Date(timeIntervalSince1970: Double(now) + 3_153_600_000)),
            now, "一年后的时间戳只能表示\"到此刻为止已处理\"")
        XCTAssertEqual(
            MessageHelpers.watermarkSeconds(Date(timeIntervalSince1970: Double(Int64.max))), now,
            "2^63 的 Double 进 Int() 会 trap，这里必须在进 Int 之前收口")
        XCTAssertEqual(MessageHelpers.watermarkSeconds(Date(timeIntervalSince1970: -1)), 0)
        XCTAssertEqual(MessageHelpers.watermarkSeconds(Date(timeIntervalSince1970: .nan)), 0)
        XCTAssertNoThrow(MessageHelpers.watermarkSeconds(Date(timeIntervalSince1970: .infinity)))
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
