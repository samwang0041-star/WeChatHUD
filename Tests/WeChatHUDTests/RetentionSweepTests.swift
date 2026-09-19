import XCTest
@testable import WeChatHUD

/// Retention in a process that is never restarted.
///
/// Every window below was declared in code — 14 天审计、45 天日报状态、72 小时
/// 分析缓存 —— and enforced only from a startup migration. For a notch overlay
/// that runs for weeks, "runs at launch" is not a behaviour: the rows just grow,
/// and `analysis_cache` holds the full text of every AI result the app ever
/// produced. `runRetentionSweep` is the periodic half, and these tests are the
/// evidence it actually deletes.
final class RetentionSweepTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!

    override func setUp() async throws {
        tmpPath = NSTemporaryDirectory() + "hud_retention_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try store.open()
    }

    override func tearDown() async throws {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    private func audit(_ model: String, ageDays: Double) throws {
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(timeIntervalSinceNow: -ageDays * 86400), role: .classifier,
            model: model, promptVersion: "v1", inputText: model, outputText: model,
            latencyMs: 1, status: .ok, errorMessage: nil
        ))
    }

    func testSweepRemovesAuditRowsPastTheDeclaredWindow() throws {
        try audit("old", ageDays: 30)
        try audit("fresh", ageDays: 1)
        XCTAssertEqual(Set(store.loadRecentAIAudit(limit: 50).map(\.model)), ["old", "fresh"],
                       "前提：清理前两侧都在，否则这条判据什么都没扫到")
        store.runRetentionSweep()
        XCTAssertEqual(store.loadRecentAIAudit(limit: 50).map(\.model), ["fresh"],
                       "14 天的窗口必须真的被周期性执行，不只是启动时一次")
    }

    /// The interesting one: an expired cache row is *also* deleted lazily when
    /// the same key is looked up again — but the key hashes the message window,
    /// which changes with every new message, so a stale row is essentially never
    /// revisited. The read at a past instant is what distinguishes "expired and
    /// swept" from "expired and still sitting there with its AI text".
    func testSweepRemovesExpiredCacheRowsThatNoLookupWillEverFind() throws {
        let written = Date(timeIntervalSinceNow: -2 * 86400)
        try store.writeAnalysisCache(
            chatUsername: "wxid_peer", analysisType: "summary", inputHash: "hash-stale",
            result: "这段文本按 72 小时的承诺早该不在了", ttlHours: 1, now: written)
        let insideWindow = written.addingTimeInterval(1800)
        let decodeDate = Date(timeIntervalSinceNow: -3600)
        XCTAssertNotNil(
            store.loadAnalysisCache(
                chatUsername: "wxid_peer", analysisType: "summary",
                inputHash: "hash-stale", now: insideWindow),
            "前提：那一行确实还在，否则下面的断言是空判")
        store.runRetentionSweep(now: decodeDate)
        XCTAssertNil(
            store.loadAnalysisCache(
                chatUsername: "wxid_peer", analysisType: "summary",
                inputHash: "hash-stale", now: insideWindow),
            "过期行要被扫掉，而不是等同一个哈希再被查到")
    }

    func testSweepKeepsRowsThatHaveNotExpired() throws {
        try store.writeAnalysisCache(
            chatUsername: "wxid_peer", analysisType: "summary", inputHash: "hash-live",
            result: "仍在有效期内", ttlHours: 24)
        store.runRetentionSweep()
        XCTAssertEqual(
            store.loadAnalysisCache(
                chatUsername: "wxid_peer", analysisType: "summary", inputHash: "hash-live"),
            "仍在有效期内", "清理不许顺手把有效缓存删光，那会把每次刷新变成一次 AI 请求")
    }

    /// Wiring, with a coverage floor: a sweep that is never called is exactly as
    /// good as no sweep, and a sweep whose DELETEs got lost in a refactor still
    /// reads green from the call site alone.
    func testSweepIsWiredToTheHeartbeatAndStillDeletes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let monitor = try String(
            contentsOf: root.appendingPathComponent("Services/ChatMonitor.swift"), encoding: .utf8)
        XCTAssertTrue(monitor.contains("self.store.runRetentionSweep()"),
                      "心跳要调它，否则窗口仍然只在启动时执行一次")
        let cadence = try XCTUnwrap(
            monitor.components(separatedBy: "windowElapsed(since: self.lastRetentionSweepAt").last
        ).components(separatedBy: "await").first ?? ""
        XCTAssertTrue(cadence.contains("Self.retentionSweepInterval"),
                      "要先记时间戳再看窗口？这里必须用的是那条共用的窗口判据")
        let declared = try XCTUnwrap(
            monitor.components(separatedBy: "static let retentionSweepInterval: TimeInterval =").last)
        let interval = String(declared.drop { !$0.isNumber }.prefix { $0.isNumber })
        XCTAssertEqual(interval, "3600", "间隔被改掉要经过这里的讨论，不是随手一个数")

        let store = try String(
            contentsOf: root.appendingPathComponent("Data/HUDStore.swift"), encoding: .utf8)
        let body = try XCTUnwrap(
            store.components(separatedBy: "func runRetentionSweep(now: Date = Date()) {").last
        ).components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertFalse(body.isEmpty, "切片为空则这条判据什么都没看")
        let deletions = body.components(separatedBy: "DELETE FROM").count - 1
            + body.components(separatedBy: "pruneAIAudit(").count - 1
            + body.components(separatedBy: "gcDailyReportState(").count - 1
        XCTAssertGreaterThanOrEqual(deletions, 4,
                                    "扫描至少要有四处清理（审计/日报/缓存/记忆），少一处就是漏")
        // The startup pass must stay (first launch after an upgrade), but it is
        // no longer the only one.
        XCTAssertEqual(store.components(separatedBy: "pruneAIAudit(olderThanDays: 14)").count - 1, 2,
                       "启动那一次和周期那一次都要在，少一次就退回旧行为")
    }
}
