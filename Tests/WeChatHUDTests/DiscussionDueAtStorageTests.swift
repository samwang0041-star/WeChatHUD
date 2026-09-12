import XCTest
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

    private func makeStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("due-at-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: dir.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        return store
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
