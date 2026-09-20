import XCTest
@testable import WeChatHUD

/// §239: `loadConversationMemory` collapses 「没有记忆」 and 「这次读不到」 into nil, and
/// `ConversationMemoryUpdater` merged that nil into an empty prior before writing back
/// over every column — one busy lock could replace a 90-day rolling summary with the
/// last 30 messages, irreversibly.
final class ConversationMemoryRebuildHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "memory-rebuild-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    private func plant(summary: String, updatedAgo: TimeInterval) throws {
        try store.exec("""
            INSERT OR REPLACE INTO conversation_memory(
                chat_username, summary, key_topics, pending_items, shared_context,
                communication_notes, mood_trend, conversation_phase, stance,
                message_count_7d, last_updated)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, params: [
                "peer", summary, "[]", "[]", "[]", "[]", "", "", "", "0",
                String(Int(Date().timeIntervalSince1970 - updatedAgo))
            ])
    }

    private func storedSummary() throws -> String? {
        store.loadConversationMemory(chatUsername: "peer")?.summary
    }

    func testReadSeparatesAbsentFromUnreadable() throws {
        if case .absent = store.conversationMemoryRead("peer") {} else {
            XCTFail("没有行时应当是 absent")
        }
        try plant(summary: "90天累积摘要", updatedAgo: 90_000)
        if case .value(let memory) = store.conversationMemoryRead("peer") {
            XCTAssertEqual(memory.summary, "90天累积摘要")
        } else {
            XCTFail("行在且能解码时应当是 value")
        }
        try store.exec("ALTER TABLE conversation_memory RENAME TO conversation_memory_hidden")
        XCTAssertTrue(store.conversationMemoryRead("peer").isUnreadable,
                      "读失败不能和「这个人没有记忆」共用一个答案")
    }

    func testUnreadablePriorIsNeverReroutedIntoARebuild() throws {
        try plant(summary: "90天累积摘要", updatedAgo: 90_000)
        try store.exec("ALTER TABLE conversation_memory RENAME TO conversation_memory_hidden")
        let prior = store.conversationMemoryRead("peer")
        XCTAssertEqual(
            ConversationMemoryUpdater.memoryRebuildDecision(prior: prior,
                                                            stalenessSeconds: 1800,
                                                            now: Date()),
            .skipUnreadable,
            "陈旧 + 读不到 ⇒ 不重建：合并的输入就是这份旧摘要，而写是整列覆盖")
    }

    func testReadableStaleMemoryStillRebuilds() throws {
        try plant(summary: "90天累积摘要", updatedAgo: 90_000)
        XCTAssertEqual(
            ConversationMemoryUpdater.memoryRebuildDecision(
                prior: store.conversationMemoryRead("peer"),
                stalenessSeconds: 1800, now: Date()),
            .rebuild, "正对照：读得到的陈旧记忆还是要重建，否则这条旗子等于永不更新")
    }

    func testReadableFreshMemoryIsStillRateLimited() throws {
        try plant(summary: "刚更新过", updatedAgo: 5)
        XCTAssertEqual(
            ConversationMemoryUpdater.memoryRebuildDecision(
                prior: store.conversationMemoryRead("peer"),
                stalenessSeconds: 1800, now: Date()),
            .skipFresh)
    }

    /// The row survives a skipped round: the guard is 「这轮不动」, not 「这轮清掉」.
    func testSkippedRoundLeavesTheStoredSummaryIntact() throws {
        try plant(summary: "90天累积摘要", updatedAgo: 90_000)
        try store.exec("ALTER TABLE conversation_memory RENAME TO conversation_memory_hidden")
        XCTAssertEqual(ConversationMemoryUpdater.memoryRebuildDecision(
            prior: store.conversationMemoryRead("peer"),
            stalenessSeconds: 1800, now: Date()), .skipUnreadable)
        try store.exec("ALTER TABLE conversation_memory_hidden RENAME TO conversation_memory")
        XCTAssertEqual(try storedSummary(), "90天累积摘要")
    }
}
