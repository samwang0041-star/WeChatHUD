import XCTest
import SQLite3
@testable import WeChatHUD

/// §231/§232: the discussion queue is the only thing that survives between scans,
/// and the scan watermark never replays what it already advanced past. So a scope
/// check whose negative branch is a `DELETE` may only take that branch on a
/// confirmed withdrawal — never on a read that failed.
final class DiscussionQueueScopePurgeTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "discussion-scope-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false, category: .work)
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    private func tracker() async -> DiscussionTracker {
        let ai = MockAIService()
        var config = AIConfig()
        config.provider = AIProviderSlot(providerID: "custom", baseURL: "http://localhost:9999",
                                         model: "mock", apiKey: "test")
        await ai.setConfig(config)
        await ai.setDefaultResponse(#"{"items":[]}"#)
        return DiscussionTracker(store: store, aiService: ai)
    }

    private func message(_ id: Int) -> MessageInfo {
        MessageInfo(id: "q\(id)", localId: id, chatUsername: "peer", chatName: "同事",
                    senderUsername: "me", senderName: "我", text: "把合同发给法务\(id)",
                    baseType: 1, subType: 0, createTime: 1000 + id)
    }

    /// Stand-in for the failure modes that actually happen at this instant
    /// (BUSY past the timeout, SQLITE_FULL/IOERR, a table mid-migration): every
    /// read of `whitelist` now errors rather than answering 「no row」.
    private func makeWhitelistUnreadable() throws {
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
    }

    private func queuedCount() throws -> Int {
        try store.pendingDiscussionMessages(chatUsername: "peer").count
    }

    func testUnreadableWhitelistKeepsTheDurableQueue() async throws {
        try store.enqueueDiscussionMessages([message(1), message(2)])
        XCTAssertEqual(try queuedCount(), 2)
        try makeWhitelistUnreadable()

        let count = await tracker().extract(chatUsername: "peer", chatName: "同事",
                                                  messages: [message(3)], myUsername: "me",
                                                  myDisplayName: "我", mySelfNames: [])
        XCTAssertEqual(count, 0, "读不到时不抽取，也不得声称抽过")
        XCTAssertEqual(try queuedCount(), 2,
                       "一行没被分析的消息不能因为「这次读不到白名单」而被删掉")
    }

    /// The guard must not be a no-op: a genuine unfollow still purges, otherwise
    /// 「取关即清空」 silently stops working and revoked chats keep producing items.
    func testConfirmedUnfollowStillPurgesTheQueue() async throws {
        try store.enqueueDiscussionMessages([message(1), message(2)])
        XCTAssertEqual(try queuedCount(), 2)
        try store.exec("DELETE FROM whitelist WHERE username='peer'")

        _ = await tracker().extract(chatUsername: "peer", chatName: "同事",
                                    messages: [message(3)], myUsername: "me",
                                    myDisplayName: "我", mySelfNames: [])
        XCTAssertEqual(try queuedCount(), 0, "确证取关仍然清空 —— 否则这条判据只是把删除换成永不删除")
    }

    /// `resumePending` is the path that iterates the queue itself, so a nil here
    /// purges chats that merely failed to read — with nobody watching.
    func testResumePendingDoesNotPurgeAnUnreadableChat() async throws {
        try store.enqueueDiscussionMessages([message(1), message(2)])
        try makeWhitelistUnreadable()

        _ = await tracker().resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        XCTAssertEqual(try queuedCount(), 2, "drain 循环里的一次读失败不能变成整条队列的删除")
    }
}
