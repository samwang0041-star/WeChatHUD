import XCTest
import SQLite3
@testable import WeChatHUD

/// The visibility window is decided twice: SQL narrows the rows it hands back
/// (`discussionRelevantSinceClause`) and Swift re-checks each one
/// (`DiscussionLiveWindow.contains`). Only the intersection is ever seen, so
/// the SQL may not be stricter than the Swift rule — a row SQL drops never
/// reaches the recheck that would have kept it.
///
/// The two disagreed for a long time without anyone noticing, because the
/// disagreement was hidden by another bug: `due_at` was stored as an empty
/// string, which compares as greater than every number, so the clause matched
/// every row regardless. Fixing that bug exposed this one — 13 live items were
/// about to disappear. This suite keeps the two rules in step.
final class DiscussionVisibilityInvariantTests: XCTestCase {

    private var dbPath = ""

    private func makeStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: dbPath)
        try store.open()
        return store
    }

    /// Writes the pre-fix storage shape straight into the file: the fixed
    /// writer can no longer produce it, and production gains no test-only API
    /// for it.
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

    /// An item whose source is old, whose deadline is absent, but which was
    /// extracted inside the window: the exact shape SQL used to drop.
    func testFreshlyExtractedOldMessageSurvivesTheWindow() throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        let twentyDaysAgo = now - 20 * 86_400
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .question, owner: .theirs,
            content: "很久以前问的事，今天才整理出来", detail: nil, anchorMsgUID: "W1",
            sourceTimestamp: twentyDaysAgo, dueAt: nil, confidence: 0.9, promptVersion: "test"
        )
        let cutoff = DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays)
        let loaded = try store.loadDiscussionItems(relevantSince: cutoff)
        XCTAssertEqual(loaded.count, 1, "a row the Swift rule keeps must not be filtered out by SQL")
        XCTAssertEqual(loaded.first?.anchorMsgUID, "W1")
    }

    func testFreshlyExtractedOldMessageSurvivesTheLegacyStorageShapeToo() throws {
        // Same item, but with the pre-fix `due_at` (empty string) still in the
        // row: the fix must not depend on which storage shape a row carries.
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        _ = try store.insertDiscussionItem(
            chatUsername: "c", chatName: "林晓", kind: .question, owner: .theirs,
            content: "legacy shape", detail: nil, anchorMsgUID: "W2",
            sourceTimestamp: now - 20 * 86_400, dueAt: nil, confidence: 0.9, promptVersion: "test"
        )
        try writeLegacyEmptyDueAt(anchor: "W2")
        let cutoff = DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays)
        let legacyCutoff = DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays)
        XCTAssertEqual(try store.loadDiscussionItems(relevantSince: legacyCutoff).count, 1)
        // And the normalize pass must not change that.
        store.normalizeDiscussionDueDates()
        XCTAssertEqual(
            try store.loadDiscussionItems(relevantSince: legacyCutoff).count, 1,
            "normalizing storage must not make a visible row invisible"
        )
    }

    func testSQLIsNeverStricterThanTheSwiftRule() throws {
        // Property check across the shapes the window reasons about.
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        let cutoff = DiscussionLiveWindow.cutoff(days: DiscussionLiveWindow.pendingDays)
        let shapes: [(String, Int, Date?, DiscussionItemStatus, Int)] = [
            ("old source, fresh extract", now - 30 * 86_400, nil, .pending, now - 60),
            ("old source, dated soon", now - 30 * 86_400, Date(timeIntervalSince1970: Double(now + 3_600)), .pending, now - 60),
            ("old source, old extract", now - 30 * 86_400, nil, .pending, now - 30 * 86_400),
            ("fresh source", now - 60, nil, .pending, now - 60),
            ("fresh source, no deadline", now - 60, nil, .pending, now - 60)
        ]
        var expectedVisible = 0
        for (index, shape) in shapes.enumerated() {
            let (label, source, due, status, _) = shape
            _ = try store.insertDiscussionItem(
                chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
                content: label, detail: nil, anchorMsgUID: "P\(index)",
                sourceTimestamp: source, dueAt: due, confidence: 0.9, promptVersion: "test"
            )
            let item = DiscussionItem(
                id: Int64(index), chatUsername: "c", chatName: "林晓", kind: .todo, owner: .mine,
                content: label, detail: nil, anchorMsgUID: "P\(index)",
                sourceTimestamp: source, dueAt: due, status: status,
                confidence: 0.9, promptVersion: "test",
                createdAt: Date(timeIntervalSince1970: TimeInterval(now - 60)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(now - 60))
            )
            if DiscussionLiveWindow.contains(item, cutoff: cutoff) { expectedVisible += 1 }
        }
        let fromSQL = try store.loadDiscussionItems(relevantSince: cutoff)
        // Every row SQL returns must also pass the Swift rule — and no row the
        // Swift rule keeps may be missing from SQL's answer.
        XCTAssertEqual(
            fromSQL.count, expectedVisible,
            "SQL returned \(fromSQL.count) rows but the Swift rule keeps \(expectedVisible)"
        )
    }
}
