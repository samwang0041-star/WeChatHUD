import XCTest
import SQLite3
@testable import WeChatHUD

/// `due_at` used to be written as an empty string when an item had no
/// deadline, and the column's INTEGER affinity cannot convert "" — so it was
/// stored as TEXT. Every TEXT value sorts after every number in SQLite, which
/// made `due_at > 0` true for **all** rows and `due_at IS NULL` true for
/// none: any "does this have a deadline?" check silently answered yes.
///
/// The bug was latent because the one query that depended on it was already
/// satisfied by its other branch, but the strictness levels filter on dates,
/// so it had to be fixed before they could work.
final class DiscussionDueAtStorageTests: XCTestCase {

    private var dbPath = ""

    private func makeStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("due-at-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: dbPath)
        try store.open()
        return store
    }

    /// Writes a legacy value straight into the file, because the fixed writer
    /// can no longer produce one. A second connection is used on purpose: the
    /// production type gains no test-only entry point for this.
    private func writeLegacyEmptyDueAt(anchor: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "UPDATE discussion_items SET due_at = '' WHERE anchor_msg_uid = ?", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, anchor, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    /// Counts the rows that still hold a TEXT deadline — the shape the old
    /// writer left behind.
    private func textDueAtRowCount() throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM discussion_items WHERE due_at IS NOT NULL AND typeof(due_at) = 'text'"
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func testUndatedItemStoresNullNotEmptyString() throws {
        let store = try makeStore()
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "没有期限的事", detail: nil, anchorMsgUID: "m1",
            sourceTimestamp: 1_700_000_000, dueAt: nil, confidence: 0.9,
            promptVersion: "test"
        )
        let loaded = try XCTUnwrap(store.loadDiscussionItems(chatUsername: "c").first)
        XCTAssertNil(loaded.dueAt, "an undated item must round-trip as nil")
    }

    func testDatedItemRoundTripsTheSameInstant() throws {
        let store = try makeStore()
        let due = Date(timeIntervalSince1970: 1_700_003_600)
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "有期限的事", detail: nil, anchorMsgUID: "m2",
            sourceTimestamp: 1_700_000_000, dueAt: due, confidence: 0.9,
            promptVersion: "test"
        )
        let loaded = try XCTUnwrap(store.loadDiscussionItems(chatUsername: "c").first)
        XCTAssertEqual(loaded.dueAt.map { Int($0.timeIntervalSince1970) }, Int(due.timeIntervalSince1970))
    }

    func testDatedAndUndatedItemsStayDistinguishable() throws {
        // The regression's signature: a predicate that is supposed to select
        // only dated rows returned every row.
        let store = try makeStore()
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "undated", detail: nil, anchorMsgUID: "u1",
            sourceTimestamp: 1_700_000_000, dueAt: nil, confidence: 0.9, promptVersion: "test"
        )
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "dated", detail: nil, anchorMsgUID: "u2",
            sourceTimestamp: 1_700_000_000, dueAt: Date(timeIntervalSince1970: 1_700_003_600),
            confidence: 0.9, promptVersion: "test"
        )
        let all = try store.loadDiscussionItems(chatUsername: "c")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter { $0.dueAt != nil }.count, 1, "exactly the dated row")
        XCTAssertEqual(all.filter { $0.dueAt == nil }.count, 1, "exactly the undated row")
    }

    func testMigrationRewritesLegacyEmptyStringsToNull() throws {
        // Rows written before the fix still hold TEXT "". The reader already
        // treats them as undated, but the stored value must not keep lying to
        // future SQL, so start-up normalizes them.
        let store = try makeStore()
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "legacy", detail: nil, anchorMsgUID: "L1",
            sourceTimestamp: 1_700_000_000, dueAt: nil, confidence: 0.9, promptVersion: "test"
        )
        // Reproduce the old writer's output directly, since the fixed writer
        // can no longer produce it.
        try writeLegacyEmptyDueAt(anchor: "L1")
        XCTAssertEqual(try textDueAtRowCount(), 1, "precondition: a legacy row exists")

        store.normalizeDiscussionDueDates()

        XCTAssertEqual(try textDueAtRowCount(), 0, "no TEXT deadline values remain")
        let loaded = try XCTUnwrap(store.loadDiscussionItems(chatUsername: "c").first)
        XCTAssertNil(loaded.dueAt)
    }

    func testMigrationLeavesRealTimestampsAlone() throws {
        // Scoped to the empty string: a dated row must survive untouched, and a
        // second run must be a no-op.
        let store = try makeStore()
        let due = Date(timeIntervalSince1970: 1_700_003_600)
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "stamped", detail: nil, anchorMsgUID: "S1",
            sourceTimestamp: 1_700_000_000, dueAt: due, confidence: 0.9, promptVersion: "test"
        )
        store.normalizeDiscussionDueDates()
        store.normalizeDiscussionDueDates()
        let loaded = try XCTUnwrap(store.loadDiscussionItems(chatUsername: "c").first)
        XCTAssertEqual(loaded.dueAt.map { Int($0.timeIntervalSince1970) }, Int(due.timeIntervalSince1970))
    }

    func testEditingAnItemToRemoveItsDeadlineClearsIt() throws {
        // The update path wrote the same empty string, so clearing a deadline
        // left a TEXT row behind exactly like the insert path did.
        let store = try makeStore()
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
            content: "先有期限", detail: nil, anchorMsgUID: "e1",
            sourceTimestamp: 1_700_000_000, dueAt: Date(timeIntervalSince1970: 1_700_003_600),
            confidence: 0.9, promptVersion: "test"
        )
        let row = try XCTUnwrap(store.loadDiscussionItems(chatUsername: "c").first)
        _ = try store.updateDiscussionItemCorrection(id: row.id, content: row.content, owner: row.owner, dueAt: nil)
        let updated = try XCTUnwrap(store.loadDiscussionItems(chatUsername: "c").first)
        XCTAssertNil(updated.dueAt, "clearing a deadline must leave no value behind")
    }
}
