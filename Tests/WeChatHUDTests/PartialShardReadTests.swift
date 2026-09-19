import XCTest
@testable import WeChatHUD

/// A page that skipped an unreadable shard used to be indistinguishable from a
/// complete one.
///
/// The shard loop records per-shard errors and only *throws* when every shard
/// failed, so one bad shard plus one good one returned a short page and
/// `ScanEngine` persisted a watermark advanced past the rows it never saw —
/// those messages then fell behind the cursor permanently. Shard failure is not
/// exotic: WeChat merges `message_N.db` into the main file while this process
/// holds a cached mapping that still names the old shard, which is exactly why
/// the merge loop dedups by content key.
final class PartialShardReadTests: XCTestCase {
    private let chat = "wxid_partial_shard"

    private func fixture(shards: [Int: [SyntheticShardedScanFixture.MessageRow]]) throws
        -> SyntheticShardedScanFixture {
        try SyntheticShardedScanFixture(chatUsername: chat, shards: shards)
    }

    private func healthyRead(_ f: SyntheticShardedScanFixture) throws -> [String] {
        try f.reader.getMessages(chatUsername: chat, limit: 10).map(\.text)
    }

    /// The premise, measured rather than assumed: an unreadable shard does not
    /// hide the healthy shard's rows, and it does not throw either.
    func testUnreadableShardSilentlyShortensThePage() throws {
        let f = try fixture(shards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "可读消息")],
            2: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "读不到的那片")]
        ])
        defer { f.cleanup() }
        try f.corruptShard(2)
        XCTAssertEqual(try healthyRead(f), ["可读消息"])
    }

    func testCorruptShardMarksTheChatAsPartial() throws {
        let f = try fixture(shards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "可读消息")],
            2: [.init(localId: 1, createTime: 1_000, senderId: 1, text: "读不到的那片")]
        ])
        defer { f.cleanup() }
        XCTAssertFalse(f.reader.didReadPartially(chatUsername: chat),
                       "前提：两片都读到了就不该标记")
        try f.corruptShard(2)
        _ = try healthyRead(f)
        XCTAssertTrue(f.reader.didReadPartially(chatUsername: chat),
                      "短页必须被记下来，否则调用方会把「没读到」当「没有」")
    }

    func testMissingKeyedShardMarksTheChatAsPartial() throws {
        let f = try fixture(shards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "可读消息")]
        ])
        defer { f.cleanup() }
        try f.addKeyForMissingShard(9)
        XCTAssertEqual(try healthyRead(f), ["可读消息"])
        XCTAssertTrue(f.reader.didReadPartially(chatUsername: chat))
    }

    /// Marks are per-scan facts. A stale mark would hold the watermark down
    /// forever and turn a healed shard into a permanently un-advancing chat.
    func testMarksAreClearedPerScanAndDoNotStick() throws {
        let rows = SyntheticShardedScanFixture.MessageRow
            .init(localId: 1, createTime: 1_000, senderId: 1, text: "坏片")
        let f = try fixture(shards: [
            0: [.init(localId: 1, createTime: 2_000, senderId: 1, text: "可读消息")],
            2: [rows]
        ])
        defer { f.cleanup() }
        try f.corruptShard(2)
        _ = try healthyRead(f)
        XCTAssertTrue(f.reader.didReadPartially(chatUsername: chat))

        // WeChat finishes the shard: same key, readable bytes again.
        try f.rewriteShard(2, rows: [rows])
        _ = try f.reader.refreshIfChanged(relPath: "message/message_2.db")
        f.reader.clearPartialReadMarks()
        XCTAssertFalse(f.reader.didReadPartially(chatUsername: chat))
        XCTAssertEqual(try healthyRead(f), ["可读消息", "坏片"],
                       "前提： healed 的分片真的要被读到，否则下面那条断言是空判")
        XCTAssertFalse(f.reader.didReadPartially(chatUsername: chat),
                       "全部读到的一轮之后不许留着标记，否则水位永远不动")
    }

    /// Wiring, with a floor: two cursor-writing feeds, both must consult the
    /// mark. Only one of them had a behaviour fixture, so this is the only thing
    /// standing between a refactor and a silent message-loss regression.
    func testBothScanFeedsHoldTheWatermarkOnAPartialPage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let scan = try String(
            contentsOf: root.appendingPathComponent("Services/ScanEngine.swift"), encoding: .utf8)
        let reads = scan.components(separatedBy: "didReadPartially(chatUsername:").count - 1
        XCTAssertGreaterThanOrEqual(reads, 2,
                                    "两条投递/水位路径都要问「这一页读全了没有」，现在只数到 \(reads)")
        // Whitelist feed: the mark has to be inside the `backlogComplete`
        // expression, because that is what both watermark writes are gated on.
        let backlog = (scan.components(separatedBy: "backlogComplete = ").last ?? "")
            .components(separatedBy: "\n").prefix(8).joined(separator: "\n")
        XCTAssertTrue(backlog.contains("everyShardAnswered"),
                      "没并进水位的「追平」定义里 = 等于没拦")
        // Autopilot feed: skipping must precede any cursor write.
        let feed = (scan.components(separatedBy: "if case .unreadable = store.autopilotCursorRead").last ?? "")
            .components(separatedBy: "getAutopilotCursor").first ?? ""
        XCTAssertTrue(feed.contains("didReadPartially"), "第二条投递路径漏了这道检查")
        XCTAssertTrue(feed.contains("continue"))
    }

    /// The hourly sweep deletes on `expires_at`; without the index that is a full
    /// scan of a table with one row per AI call, on the main actor.
    func testRetentionSweepHasItsIndex() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Data/HUDStore.swift")
        let store = try String(contentsOf: root, encoding: .utf8)
        XCTAssertEqual(
            store.components(separatedBy: "idx_analysis_cache_expires").count - 1, 1,
            "清理谓词上要有索引，且只建一次")
    }
}
