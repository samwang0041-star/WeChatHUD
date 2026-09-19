import XCTest
@testable import WeChatHUD

/// `create_time` is WeChat's column. When one of its rows is dated ahead of the
/// wall clock and that value is written into a scan watermark, every later REAL
/// message compares as already seen — the chat stops feeding classification,
/// 待办, 承诺 extraction and autopilot, the cursor only moves forward, and a
/// restart doesn't help. Nothing self-heals until wall time catches up.
final class ScanCursorClampTests: XCTestCase {

    private var root: String!
    private var store: HUDStore!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "cursor-\(UUID())"
        try FileManager.default.createDirectory(atPath: root!, withIntermediateDirectories: true)
        store = HUDStore(dbPath: root! + "/hud.sqlite3")
        try store.open()
    }

    override func tearDown() {
        store?.close()
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testFutureCursorsAreCappedAtNowOnEveryWriter() throws {
        let now = Int(Date().timeIntervalSince1970)
        let year3000 = 32_503_680_000

        try store.setWhitelistCursor(username: "chat-a", lastCreateTime: year3000, lastLocalId: 7)
        try store.setAutopilotCursor(username: "chat-a", lastCreateTime: year3000, lastLocalId: 7)
        try store.setBackfillCursor(username: "chat-a", lastCreateTime: year3000, lastLocalId: 7)

        for (name, stored) in [
            ("wl", try XCTUnwrap(store.getWhitelistCursor(username: "chat-a")).lastCreateTime),
            ("ap", try XCTUnwrap(store.getAutopilotCursor(username: "chat-a")).lastCreateTime),
            ("backfill", try XCTUnwrap(store.getBackfillCursor(username: "chat-a")).lastCreateTime),
        ] {
            XCTAssertLessThanOrEqual(stored, now, "\(name) 的水位被推到了未来")
            XCTAssertGreaterThan(stored, now - 120, "\(name) 不该把水位压成 0")
        }
        // The localId still points at the row that was seen, so a real message
        // arriving later is admitted by time and only deduped by id if it is the
        // same row.
        XCTAssertEqual(store.getWhitelistCursor(username: "chat-a")?.lastLocalId, 7)
    }

    func testNormalAndNonsenseValuesRoundTrip() throws {
        let now = Int(Date().timeIntervalSince1970)
        try store.setWhitelistCursor(username: "chat-b", lastCreateTime: now - 600, lastLocalId: 3)
        XCTAssertEqual(store.getWhitelistCursor(username: "chat-b")?.lastCreateTime, now - 600)

        try store.setWhitelistCursor(username: "chat-c", lastCreateTime: -5, lastLocalId: 1)
        XCTAssertNil(store.getWhitelistCursor(username: "chat-c"),
                     "负数不是水位，宁可可重扫也不能当成看过")
    }

    func testClampFunctionTable() {
        XCTAssertEqual(ScanCursorClampTests.clamp(5, now: 10), 5)
        XCTAssertEqual(ScanCursorClampTests.clamp(50, now: 10), 10)
        XCTAssertEqual(ScanCursorClampTests.clamp(-9, now: 10), 0)
        XCTAssertEqual(HUDStore.clampedCursorTime(Int.max, now: 10), 10)
    }

    private static func clamp(_ value: Int, now: Int) -> Int {
        HUDStore.clampedCursorTime(value, now: now)
    }
}
