import XCTest
import SQLite3
@testable import WeChatHUD

final class DiscussionSourceWindowTests: XCTestCase {
    private let prefix = "message/message_0.db/Msg_synthetic/"
    private func message(_ id: Int, time: Int = 1000, prefix: String? = nil) -> MessageInfo {
        MessageInfo(id: (prefix ?? self.prefix) + String(id), localId: id, chatUsername: "peer", chatName: "同事",
                    senderUsername: "peer", senderName: "同事", text: "合成原文\(id)",
                    baseType: 1, subType: 0, createTime: time)
    }

    func testSQLUpperCursorIncludesAnchorButExcludesLaterSameSecondRows() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE messages (local_id INTEGER PRIMARY KEY, create_time INTEGER)", nil, nil, nil), SQLITE_OK)
        for id in 1...100 {
            let timestamp = id == 1 ? 100 : 1000
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO messages VALUES (\(id), \(timestamp))", nil, nil, nil), SQLITE_OK)
        }
        let sql = "SELECT local_id FROM messages" + WeChatReader.messageQuerySuffix(
            limit: 40, beforeCursor: (1000, 10))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(Int(sqlite3_column_int64(statement, 0))) }
        XCTAssertEqual(ids, Array((1...10).reversed()))
        XCTAssertTrue(ids.contains(1), "Slow discussion evidence older than ten minutes must remain reachable")
    }

    func testVerifiedWindowRequiresExactFullAnchorIdentity() {
        XCTAssertNil(DiscussionSourceWindow.verified([message(2)], anchorUID: prefix + "3", chatUsername: "peer", timestamp: 1000))
        XCTAssertNil(DiscussionSourceWindow.verified([message(3, prefix: "message/other.db/Msg_synthetic/")],
                                                    anchorUID: prefix + "3", chatUsername: "peer", timestamp: 1000))
        XCTAssertNil(DiscussionSourceWindow.verified([message(3, time: 999)], anchorUID: prefix + "3", chatUsername: "peer", timestamp: 1000))
    }

    func testVerifiedWindowDefensivelyExcludesFutureAndKeepsChronology() throws {
        let result = try XCTUnwrap(DiscussionSourceWindow.verified(
            [message(4), message(3), message(2), message(1, time: 100)],
            anchorUID: prefix + "3", chatUsername: "peer", timestamp: 1000))
        XCTAssertEqual(result.map(\.localId), [1, 2, 3])
    }

    func testInvalidAnchorCannotFallBackToLatestMessages() {
        XCTAssertNil(DiscussionSourceWindow.anchorCursor(uid: "unrecognized", timestamp: 1000))
        XCTAssertNil(DiscussionSourceWindow.anchorCursor(uid: prefix + "not-a-row", timestamp: 1000))
        XCTAssertNil(DiscussionSourceWindow.anchorCursor(uid: prefix + "0", timestamp: 1000))
    }
}
