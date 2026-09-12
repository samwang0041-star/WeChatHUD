import XCTest
import SQLite3
@testable import WeChatHUD

/// Covers the prepared-statement cache added to HUDStore's SQL helpers:
/// statements are reused, bindings never leak between calls, the cache stays
/// bounded, and it is emptied before the connection closes.
final class HUDStoreStatementCachePerfTests: XCTestCase {

    private func makeTempStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "hudstore-stmt-cache-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }

    // MARK: - Reuse

    func testRepeatedExecCompilesOnce() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let before = store.statementPrepareCount
        for i in 0..<5 {
            try store.setSetting("cache_probe", value: "v\(i)")
        }
        // Five executions of one SQL string must compile it exactly once.
        XCTAssertEqual(store.statementPrepareCount - before, 1)
        XCTAssertEqual(store.getSetting("cache_probe"), "v4")
    }

    func testRepeatedReadsCompileOnceAndReturnEveryRow() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "群", kind: .todo, owner: .mine,
            content: "甲", detail: nil, anchorMsgUID: "a1",
            sourceTimestamp: 1_700_000_000, dueAt: nil, confidence: 0.9, promptVersion: "t"
        )
        try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "群", kind: .todo, owner: .mine,
            content: "乙", detail: nil, anchorMsgUID: "a2",
            sourceTimestamp: 1_700_000_100, dueAt: nil, confidence: 0.9, promptVersion: "t"
        )

        let before = store.statementPrepareCount
        let first = store.loadDiscussionItems(chatUsername: "chat")
        let second = store.loadDiscussionItems(chatUsername: "chat")
        XCTAssertEqual(store.statementPrepareCount - before, 1)
        // Reuse must reset the cursor: a second call returns the same rows,
        // not an empty tail.
        XCTAssertEqual(first.map(\.content), second.map(\.content))
        XCTAssertEqual(second.count, 2)
    }

    func testDistinctSQLStringsCompilePerString() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        for i in 0..<5 {
            XCTAssertTrue(try store.insertDiscussionItem(
                chatUsername: "chat", chatName: "群", kind: .todo, owner: .mine,
                content: "第\(i)条", detail: nil, anchorMsgUID: "a\(i)",
                sourceTimestamp: 1_700_000_000 + i, dueAt: nil,
                confidence: 0.9, promptVersion: "t"
            ))
        }

        let before = store.statementPrepareCount
        for limit in 1...5 {
            let rows = store.loadDiscussionItems(chatUsername: "chat", limit: limit)
            XCTAssertEqual(rows.count, limit)
        }
        // Each LIMIT is a distinct SQL string, so each needs its own compile —
        // but only one per distinct string.
        XCTAssertEqual(store.statementPrepareCount - before, 5)
    }

    // MARK: - Bindings

    func testReusedStatementDoesNotLeakBindingsBetweenCalls() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat-a", chatName: "甲群", kind: .todo, owner: .mine,
            content: "属于甲", detail: nil, anchorMsgUID: "a1",
            sourceTimestamp: 1_700_000_000, dueAt: nil, confidence: 0.9, promptVersion: "t"
        ))
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat-b", chatName: "乙群", kind: .todo, owner: .mine,
            content: "属于乙", detail: nil, anchorMsgUID: "b1",
            sourceTimestamp: 1_700_000_100, dueAt: nil, confidence: 0.9, promptVersion: "t"
        ))

        // Same SQL string, different binds. A missing clear_bindings would
        // leave the previous username in place and return the wrong chat.
        let first = store.loadDiscussionItems(chatUsername: "chat-a")
        let second = store.loadDiscussionItems(chatUsername: "chat-b")
        XCTAssertEqual(first.map(\.content), ["属于甲"])
        XCTAssertEqual(second.map(\.content), ["属于乙"])

        // A second call with the same bind must not accumulate rows either.
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat-b").count, 1)
    }

    func testReusedWriteStatementBindsFreshValues() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        try store.setSetting("probe", value: "one")
        try store.setSetting("probe", value: "two")
        try store.setSetting("other", value: "three")
        XCTAssertEqual(store.getSetting("probe"), "two")
        XCTAssertEqual(store.getSetting("other"), "three")
    }

    // MARK: - Write accounting

    func testWriteStatementCountCountsExecutionsNotPrepares() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let start = store.writeStatementCount
        for i in 0..<4 {
            try store.setSetting("write_probe", value: "v\(i)")
        }
        // Four executions of the same INSERT OR REPLACE: the statement is
        // prepared once, so the count must be four, not one.
        XCTAssertEqual(store.writeStatementCount - start, 4)
    }

    func testReadOnlyStatementsDoNotCountAsWrites() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        try store.setSetting("read_probe", value: "value")

        let start = store.writeStatementCount
        _ = store.getSetting("read_probe")
        _ = store.loadDrafts()
        _ = store.workspaceDraftCount()
        _ = store.loadCommitments()
        XCTAssertEqual(store.writeStatementCount, start)
    }

    func testWriteCountDistinguishesZeroWritesOnReadOnlyPath() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        // Models the archive-throttle assertion: with nothing stale to
        // archive, a pure read pass must issue no write statements.
        let start = store.writeStatementCount
        _ = store.loadDiscussionItems(status: .pending, relevantSince: 4_000_000_000)
        _ = store.loadCommitments(status: .pending, relevantSince: 4_000_000_000)
        XCTAssertEqual(store.writeStatementCount, start)
    }

    func testInsertAndUpdateThroughCachedHelpersCountAsWrites() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        let start = store.writeStatementCount
        let id = store.executeInsert("INSERT INTO reply_drafts(chat_username, chat_name, text, send_at, created_at) VALUES(?,?,?,?,?)") { stmt in
            sqlite3_bind_text(stmt, 1, "chat", -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 2, "群", -1, HUDStore.sqliteTransient)
            sqlite3_bind_text(stmt, 3, "草稿", -1, HUDStore.sqliteTransient)
            sqlite3_bind_int64(stmt, 4, 0)
            sqlite3_bind_int64(stmt, 5, 1_700_000_000)
        }
        XCTAssertNotNil(id)
        XCTAssertEqual(store.writeStatementCount - start, 1)

        let changed = store.executeUpdate("UPDATE reply_drafts SET text=? WHERE id=?") { stmt in
            sqlite3_bind_text(stmt, 1, "改过", -1, HUDStore.sqliteTransient)
            sqlite3_bind_int64(stmt, 2, Int64(id ?? 0))
        }
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.writeStatementCount - start, 2)
    }

    // MARK: - Bounds and lifecycle

    func testCacheStaysBoundedAcrossStatementChurn() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        for i in 0..<4 {
            XCTAssertTrue(try store.insertDiscussionItem(
                chatUsername: "chat", chatName: "群", kind: .todo, owner: .mine,
                content: "第\(i)条", detail: nil, anchorMsgUID: "a\(i)",
                sourceTimestamp: 1_700_000_000 + i, dueAt: nil,
                confidence: 0.9, promptVersion: "t"
            ))
        }
        // Warm one statement, then churn far more distinct SQL strings than
        // the cache can hold. The eviction policy must drop the warmed one:
        // if it survived, the cache would be growing without bound.
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat", limit: 1).count, 1)
        let warmed = store.statementPrepareCount
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat", limit: 1).count, 1)
        XCTAssertEqual(store.statementPrepareCount, warmed, "the warmed statement must be a cache hit")

        for limit in 2...60 {
            XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat", limit: limit).count,
                           min(limit, 4))
        }

        // The warmed statement was evicted by the churn, so exactly one
        // recompile happens — proof the cache is bounded instead of
        // accumulating every SQL string it has ever seen.
        let beforeRecompile = store.statementPrepareCount
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat", limit: 1).count, 1)
        XCTAssertEqual(store.statementPrepareCount - beforeRecompile, 1,
                       "the evicted statement should recompile exactly once")

        // Statements touched after the churn are cached again, so repeats of
        // either the evicted one or the last churn statement are hits.
        let afterRecovery = store.statementPrepareCount
        for _ in 0..<3 {
            XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat", limit: 1).count, 1)
            XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat", limit: 50).count, 4)
        }
        XCTAssertEqual(store.statementPrepareCount, afterRecovery,
                       "statements re-warmed after eviction must not recompile again")
    }

    func testCloseFinalizesCachedStatementsAndReopenRebuilds() throws {
        let (store, path) = try makeTempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.setSetting("lifecycle", value: "kept")
        _ = store.loadCommitments()

        // close() returns without SQLITE_BUSY only when every cached
        // statement was finalized first; reopening then proves the handle
        // really was released and the cache was reset for the new handle.
        store.close()
        try store.open()
        defer { store.close() }

        XCTAssertEqual(store.getSetting("lifecycle"), "kept")
        let before = store.statementPrepareCount
        try store.setSetting("lifecycle", value: "after-reopen")
        XCTAssertEqual(store.statementPrepareCount - before, 1)
        XCTAssertEqual(store.getSetting("lifecycle"), "after-reopen")
    }

    func testFailedStatementDoesNotPoisonTheCacheOrTheConnection() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }

        // Nonsense SQL must fail exactly as it did before the cache existed:
        // the throwing helper swallows nothing, the non-throwing helpers
        // still report their old neutral values, and no half-prepared handle
        // is left behind to poison later calls.
        XCTAssertThrowsError(try store.execProbeThrowing("SELECT FROM WHERE")) { error in
            guard case HUDStoreError.sqlError = error else {
                return XCTFail("expected sqlError, got \(error)")
            }
        }
        store.execIgnoringError("SELECT FROM WHERE")
        XCTAssertEqual(store.executeUpdate("SELECT FROM WHERE") { _ in }, 0)
        XCTAssertNil(store.queryOne("SELECT FROM WHERE", bind: { _ in }, decode: { _ in 1 }))
        XCTAssertTrue(store.queryAll("SELECT FROM WHERE", bind: { _ in }, decode: { _ in 1 }).isEmpty)

        // The connection is still usable afterwards.
        try store.setSetting("after_error", value: "ok")
        XCTAssertEqual(store.getSetting("after_error"), "ok")
    }
}
