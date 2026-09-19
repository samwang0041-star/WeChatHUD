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

    /// The retention sweep's delete predicate needs its index (see §191): without
    /// it the hourly pass is a full scan of a table with one row per AI call.
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

    /// 举报：跨分片游标会永久漏行 —— 判阴，但这条判据是它成立的前提。
    ///
    /// `messageQuerySuffix` 的 `afterCursor` 是 `(create_time > cT) OR
    /// (create_time = cT AND local_id > cL)`，而 `local_id` **只在单个分片内有序**
    /// （每个 `message_N.db` 从头编号）。这条谓词是按分片各自执行的，所以一旦扫描
    /// 用 `afterCursor` 做增量，另一片里同秒、localId 更小的真实消息会被 SQL 直接
    /// 挡掉 —— 内存里那条「跨片同秒要放行」的规则再也看不见它。
    ///
    /// 今天不成立是因为扫描链路根本不传 `afterCursor`（它每次取最新 N 条，再在内存里
    /// 按基线过滤），且那条放行规则有行为测试钉住（`ScanBacklogPagingTests`
    /// 「same-second row in another shard must not be filtered by localId」）。
    /// 这条判据守的是那个前提：把水位过滤下推进 SQL 的那一刻，就会重新变成永久漏消息。
    func testScanPathsNeverFilterByCursorInSQL() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/ScanEngine.swift")
        let scan = try String(contentsOf: root, encoding: .utf8)
        let uses = scan.components(separatedBy: "afterCursor:").count - 1
        let explicitNil = scan.components(separatedBy: "afterCursor: nil").count - 1
        XCTAssertGreaterThanOrEqual(uses, 1, "锚点：扫描里那处显式 `afterCursor: nil` 要被数到")
        XCTAssertEqual(uses, explicitNil,
                       "扫描一旦用 afterCursor 做增量，跨分片同秒的行会被 SQL 挡在页外，内存规则救不回来")
        XCTAssertEqual(
            scan.components(separatedBy: "!baselineShard.isEmpty && $0.shardRelPath != baselineShard").count - 1,
            2, "两条投递路径各有一份跨片同秒放行，少一处就是那条路径漏行")
        // The admission needs the shard identity on the row to compare against.
        XCTAssertTrue(scan.contains("lastShard: messages.first?.shardRelPath"),
                      "水位要记下这一行来自哪一片，否则下一轮无从比较")
    }
    /// The mark is written inside the reader's lock by whichever thread drove the
    /// read, and read from the scan path. `WeChatReaderActor` is only a facade —
    /// every caller builds its own actor instance over the same reader — so the
    /// lock is the sole barrier, and an unsynchronized `Set` here is a
    /// simultaneous-access trap in a process that never restarts.
    func testPartialReadMarkIsLockGuarded() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Data/WeChatReader.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for name in ["func didReadPartially(chatUsername: String) -> Bool {",
                     "func clearPartialReadMarks() {"] {
            let body = (source.components(separatedBy: name).last ?? "")
                .components(separatedBy: "\n    }\n").first ?? ""
            XCTAssertFalse(body.isEmpty, "切片为空则这条判据什么都没看：\(name)")
            XCTAssertTrue(body.contains("lock.lock()"), "\(name) 必须取读库那把锁")
            XCTAssertTrue(body.contains("lock.unlock()"))
        }
        XCTAssertFalse(source.contains("private(set) var partialReadChats"),
                       "对外可见的裸 Set = 任何人都能不经锁读它")
        XCTAssertTrue(source.contains("private var partialReadChats"))
    }
}
