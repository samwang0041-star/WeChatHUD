import XCTest
import SQLite3
@testable import WeChatHUD

final class MessageScanPaginationTests: XCTestCase {
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE messages (local_id INTEGER PRIMARY KEY, create_time INTEGER)", nil, nil, nil), SQLITE_OK)
        // More than two scan windows; many messages share each timestamp.
        for id in 1...257 {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO messages VALUES (\(id), \(1000 + id / 150))", nil, nil, nil), SQLITE_OK)
        }
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
    }

    private func page(after: (lastCreateTime: Int, lastLocalId: Int)?, oldestFirst: Bool = true) throws -> [(Int, Int)] {
        let sql = "SELECT create_time, local_id FROM messages" + WeChatReader.messageQuerySuffix(
            limit: 100, afterCursor: after, oldestFirst: oldestFirst)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("Invalid scan query")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [(Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
        }
        return rows
    }

    func testLargeBacklogDrainsWithoutGapsOrDuplicatesIncludingSameSecond() throws {
        var cursor = (lastCreateTime: 1000, lastLocalId: 0)
        var seen: [Int] = []
        for expectedCount in [100, 100, 57, 0] {
            let rows = try page(after: cursor)
            XCTAssertEqual(rows.count, expectedCount)
            seen += rows.map { $0.1 }
            if let last = rows.last { cursor = last }
        }
        XCTAssertEqual(seen, Array(1...257))
    }

    func testRetryBeforeCursorCommitReturnsSamePage() throws {
        let cursor = (lastCreateTime: 1000, lastLocalId: 100)
        let first = try page(after: cursor).map { $0.1 }
        XCTAssertEqual(try page(after: cursor).map { $0.1 }, first)
        XCTAssertEqual(first, Array(101...200))
    }

    func testNewMessageAtSameSecondAfterEmptyPageIsVisible() throws {
        let cursor = (lastCreateTime: 1001, lastLocalId: 257)
        XCTAssertTrue(try page(after: cursor).isEmpty)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO messages VALUES (258, 1001)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try page(after: cursor).map { $0.1 }, [258])
    }

    func testFirstScanKeepsBoundedRecentHistory() throws {
        let rows = try page(after: nil, oldestFirst: false)
        XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(rows.first?.1, 257)
        XCTAssertEqual(rows.last?.1, 158)
    }
}
