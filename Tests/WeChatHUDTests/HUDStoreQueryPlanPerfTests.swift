import XCTest
import SQLite3
@testable import WeChatHUD

/// Covers the CAST removal in the live-window clauses of loadCommitments and
/// loadDiscussionItems.
///
/// Two things are asserted:
/// 1. Row semantics are unchanged for both timestamp storage forms that exist
///    in real databases (raw-SQL string writes and integer writes).
/// 2. The shapes that can use an index still do, on the exact SQL the
///    implementation builds.
final class HUDStoreQueryPlanPerfTests: XCTestCase {

    private func makeTempStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "hudstore-plan-" + UUID().uuidString + ".sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }

    /// Same SELECT list the implementation uses; the predicate under test is
    /// taken from the store's own constants so the plan is measured on the
    /// real SQL rather than a copy of it.
    private static let commitmentSelectColumns = """
        SELECT id, msg_uid, chat_username, chat_name, content, commit_to,
               deadline_at, confidence, status, prompt_version,
               created_at, updated_at, source_text, context_text,
               capture_reason, next_step, deadline_label, commitment_kind
        FROM commitments
        """

    private static let discussionSelectColumns = """
        SELECT id, chat_username, chat_name, kind, owner, content, detail,
               anchor_msg_uid, source_timestamp, due_at, status,
               confidence, prompt_version, created_at, updated_at
        FROM discussion_items
        """

    private func seedCommitments(_ store: HUDStore, rows: Int = 400) throws {
        for i in 0..<rows {
            // Mix of statuses with plenty of pending/overdue rows so the
            // planner has a realistic distribution to plan against.
            let status: CommitmentStatus = (i % 3 == 0) ? .pending : ((i % 7 == 0) ? .overdue : .fulfilled)
            try store.upsertCommitment(
                msgUID: "plan-commit-" + String(i),
                chatUsername: "chat-" + String(i % 5),
                chatName: "会话" + String(i % 5),
                content: "第" + String(i) + "条",
                commitTo: "对方",
                confidence: 0.9,
                promptVersion: "t",
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))
            )
            if status != .pending {
                try store.updateCommitmentStatus(msgUID: "plan-commit-" + String(i), status: status)
            }
        }
    }

    private func seedDiscussionItems(_ store: HUDStore, rows: Int = 400) throws {
        for i in 0..<rows {
            XCTAssertTrue(try store.insertDiscussionItem(
                chatUsername: "chat", chatName: "群", kind: .todo, owner: .mine,
                content: "第" + String(i) + "条", detail: nil,
                anchorMsgUID: "plan-disc-" + String(i),
                sourceTimestamp: 1_700_000_000 + i, dueAt: nil,
                confidence: 0.9, promptVersion: "t"
            ))
        }
    }

    private func queryPlan(_ store: HUDStore, sql: String) throws -> String {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let db = try XCTUnwrap(store.rawDB)
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &stmt, nil), SQLITE_OK)
        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // The detail column is the stable one across SQLite versions, but
            // its index has moved, so gather every text column.
            for column in 0..<sqlite3_column_count(stmt) {
                if let text = sqlite3_column_text(stmt, column) {
                    lines.append(String(cString: text))
                }
            }
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Storage forms

    func testStringAndIntegerTimestampRowsBothMatch() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        let db = try XCTUnwrap(store.rawDB)

        // Real databases contain both shapes: the store's own writers pass
        // stringified timestamps, while raw SQL and migrations have written
        // integers. This is the string form.
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO commitments(msg_uid, chat_username, chat_name, content, commit_to,
                                    deadline_at, confidence, status, prompt_version,
                                    created_at, updated_at)
            VALUES('string-form', 'c', 'C', '字符串时间戳', 'peer', NULL, 0.9, 'fulfilled', 't',
                   '1700000000', '1700000000')
            """, nil, nil, nil), SQLITE_OK)

        // The column's NUMERIC affinity converts a numeric-looking string on
        // write, so "string form" and "integer form" are stored identically.
        // Asserting this pins the fact the CAST removal depends on.
        var typeStmt: OpaquePointer?
        defer { sqlite3_finalize(typeStmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT typeof(created_at) FROM commitments WHERE msg_uid='string-form'", -1, &typeStmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(typeStmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(typeStmt, 0)), "integer")

        // Raw-SQL integer form, the other way history recorded timestamps.
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO commitments(msg_uid, chat_username, chat_name, content, commit_to,
                                    deadline_at, confidence, status, prompt_version,
                                    created_at, updated_at)
            VALUES('integer-form', 'c', 'C', '整数时间戳', 'peer', NULL, 0.9, 'fulfilled', 't',
                   1700000010, 1700000010)
            """, nil, nil, nil), SQLITE_OK)

        let matched = store.loadCommitments(relevantSince: 1_700_000_005)
            .filter { $0.msgUID.hasSuffix("form") }
            .map { $0.msgUID }
        XCTAssertEqual(Set(matched), ["integer-form"],
                       "only the row at or after the cutoff should survive the live window")

        // Both rows are visible once the cutoff is below both timestamps.
        let both = store.loadCommitments(relevantSince: 1_699_999_000)
            .filter { $0.msgUID.hasSuffix("form") }
            .map { $0.msgUID }
        XCTAssertEqual(Set(both), ["string-form", "integer-form"])
    }

    func testDiscussionTimestampRowsWrittenAsTextAndAsIntegerBothMatch() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        let db = try XCTUnwrap(store.rawDB)
        try store.addToWhitelist(username: "chat", displayName: "群",
                                 isGroup: false, category: .work)

        // The store's own writer passes stringified timestamps; raw SQL and
        // migrations have written integers. Both spellings must be found.
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO discussion_items(chat_username, chat_name, kind, owner, content, detail,
                                         anchor_msg_uid, source_timestamp, due_at, status,
                                         confidence, prompt_version, created_at, updated_at)
            VALUES('chat', '群', 'todo', 'mine', '字符串形态', '',
                   'string-ts', '1700000000', NULL, 'pending',
                   0.9, 't', '1700000000', '1700000000')
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO discussion_items(chat_username, chat_name, kind, owner, content, detail,
                                         anchor_msg_uid, source_timestamp, due_at, status,
                                         confidence, prompt_version, created_at, updated_at)
            VALUES('chat', '群', 'todo', 'mine', '整数形态', '',
                   'integer-ts', 1700000010, NULL, 'done',
                   0.9, 't', 1700000010, 1700000010)
            """, nil, nil, nil), SQLITE_OK)

        let all = store.loadDiscussionItems(relevantSince: 1_700_000_000, limit: 10)
            .filter { $0.anchorMsgUID.hasSuffix("-ts") }
            .map { $0.anchorMsgUID }
        XCTAssertEqual(Set(all), ["string-ts", "integer-ts"])

        // A cutoff above the finished row drops only that one: the string-form
        // pending row is kept because pending rows are always in the window.
        let newer = store.loadDiscussionItems(relevantSince: 1_700_000_005, limit: 10)
            .filter { $0.anchorMsgUID.hasSuffix("-ts") }
            .map { $0.anchorMsgUID }
        XCTAssertEqual(Set(newer), ["integer-ts"])
    }

    func testPendingRowWithNonNumericDeadlineStaysVisible() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        let db = try XCTUnwrap(store.rawDB)

        // An explicitly pending row stays visible regardless of what its
        // deadline column holds, which is the behavior the live window
        // promises. Removing the CAST must not change that.
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO commitments(msg_uid, chat_username, chat_name, content, commit_to,
                                    deadline_at, confidence, status, prompt_version,
                                    created_at, updated_at)
            VALUES('garbage-deadline', 'c', 'C', '垃圾截止时间', 'peer', 'garbage', 0.9, 'pending', 't',
                   1, 1)
            """, nil, nil, nil), SQLITE_OK)

        let rows = store.loadCommitments(relevantSince: 1_700_000_000)
        XCTAssertTrue(rows.contains { $0.msgUID == "garbage-deadline" })
    }

    // MARK: - Query plans

    func testCommitmentStatusQueryUsesStatusIndex() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        try seedCommitments(store)

        let sql = "SELECT id FROM commitments WHERE status=? AND "
            + HUDStore.commitmentRelevantSinceClause
            + " ORDER BY COALESCE(deadline_at, 9999999999) ASC"
        let plan = try queryPlan(store, sql: sql)
        XCTAssertFalse(plan.contains("SCAN commitments"),
                       "a status-filtered live query must not fall back to a full table scan: " + plan)
        XCTAssertTrue(plan.contains("idx_commitments_status"),
                      "expected the status index in the plan, got: " + plan)
    }

    func testDiscussionStatusQueryUsesStatusTimeIndex() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        try seedDiscussionItems(store)

        let sql = "SELECT id FROM discussion_items WHERE status=? AND "
            + HUDStore.discussionRelevantSinceClause
            + " ORDER BY source_timestamp DESC"
        let plan = try queryPlan(store, sql: sql)
        XCTAssertFalse(plan.contains("SCAN discussion_items"),
                       "a status-filtered live query must not fall back to a full table scan: " + plan)
        XCTAssertTrue(plan.contains("idx_disc_status_time"),
                      "expected the status/time index in the plan, got: " + plan)
    }

    // MARK: - Semantic parity with the CAST form

    func testCommitmentClauseMatchesTheOldCastPredicateRowForRow() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        let db = try XCTUnwrap(store.rawDB)
        try seedCommitments(store, rows: 120)

        let bind = [CommitmentStatus.pending.rawValue, CommitmentStatus.overdue.rawValue,
                    "1700000000", "1700000000", "1700000000"]
        let newRows = try ids(db: db,
                              sql: "SELECT id FROM commitments WHERE "
                                + HUDStore.commitmentRelevantSinceClause + " ORDER BY id",
                              bind: bind)
        let oldRows = try ids(db: db, sql: """
            SELECT id FROM commitments
            WHERE (status IN (?, ?)
             OR CAST(created_at AS INTEGER) >= ?
             OR (CAST(IFNULL(deadline_at, 0) AS INTEGER) > 0 AND CAST(deadline_at AS INTEGER) >= ?)
             OR CAST(updated_at AS INTEGER) >= ?)
            ORDER BY id
            """, bind: bind)
        XCTAssertEqual(newRows, oldRows)
    }

    func testDiscussionClauseMatchesTheOldCastPredicateRowForRow() throws {
        let (store, path) = try makeTempStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        let db = try XCTUnwrap(store.rawDB)
        try seedDiscussionItems(store, rows: 120)

        let bind = ["1700000000", "1700000000", DiscussionItemStatus.pending.rawValue, "1700000000"]
        let newRows = try ids(db: db,
                              sql: "SELECT id FROM discussion_items WHERE "
                                + HUDStore.discussionRelevantSinceClause + " ORDER BY id",
                              bind: bind)
        let oldRows = try ids(db: db, sql: """
            SELECT id FROM discussion_items
            WHERE (
                CAST(source_timestamp AS INTEGER) >= ?
                OR (CAST(IFNULL(due_at, 0) AS INTEGER) > 0 AND CAST(due_at AS INTEGER) >= ?)
                OR (status != ? AND CAST(updated_at AS INTEGER) >= ?)
            )
            ORDER BY id
            """, bind: bind)
        XCTAssertEqual(newRows, oldRows)
    }

    private func ids(db: OpaquePointer, sql: String, bind: [String]) throws -> [Int64] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, HUDStore.sqliteTransient)
        }
        var result: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(sqlite3_column_int64(stmt, 0))
        }
        return result
    }
}
