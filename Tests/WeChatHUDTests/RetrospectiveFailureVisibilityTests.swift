import XCTest
@testable import WeChatHUD

/// A retrospective run that crashed leaves `status='failed'` in the database,
/// and `latestCompletedRun()` filters those rows out. Only the live job carried
/// the failure, so after a relaunch the page rendered an OLDER period under
/// 「已完成」 — the user read today's review as already done and never saw that
/// it died.
final class RetrospectiveFailureVisibilityTests: XCTestCase {

    private var root: String!
    private var store: HUDStore!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "review-fail-\(UUID())"
        try FileManager.default.createDirectory(atPath: root!, withIntermediateDirectories: true)
        store = HUDStore(dbPath: root! + "/hud.sqlite3")
        try store.open()
    }

    override func tearDown() {
        store?.close()
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func day(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    /// One finished run, then a newer one that died.
    private func seedCompletedThenCrashed() throws -> (completed: Int, crashed: Int) {
        let older = try XCTUnwrap(
            store.insertReviewRun(rangeStart: day(0), rangeEnd: day(86_400), chatCount: 2))
        try store.exec("UPDATE review_runs SET status='completed' WHERE id=\(older)")
        let crashed = try XCTUnwrap(
            store.insertReviewRun(rangeStart: day(86_400), rangeEnd: day(172_800), chatCount: 2))
        try store.exec("UPDATE review_runs SET status='failed' WHERE id=\(crashed)")
        return (older, crashed)
    }

    func testFailedRunIsStillTheNewestRun() throws {
        let (older, crashed) = try seedCompletedThenCrashed()
        XCTAssertEqual(store.latestCompletedRun()?.id, older,
                       "this is exactly the row the page falls back to displaying")
        let newest = try XCTUnwrap(store.latestReviewRunAnyStatus())
        XCTAssertEqual(newest.id, crashed)
        XCTAssertEqual(newest.status, .failed)
    }

    func testStatusLineDoesNotClaimCompletionOverADeadRun() throws {
        let (older, crashed) = try seedCompletedThenCrashed()
        let done = try XCTUnwrap(store.runByID(older))
        let dead = try XCTUnwrap(store.runByID(crashed))

        let line = RetrospectiveTabView.statusLine(
            isRunning: false, runningText: "正在生成回顾", errorText: nil,
            abandoned: dead, latest: done
        )
        XCTAssertTrue(line.contains("没有完成"), line)
        XCTAssertFalse(line.contains("已完成"), "\(line) 仍在承诺一次没发生的回顾")

        let clean = RetrospectiveTabView.statusLine(
            isRunning: false, runningText: "正在生成回顾", errorText: nil,
            abandoned: nil, latest: done
        )
        XCTAssertTrue(clean.contains("已完成"), clean)

        let reportedLive = RetrospectiveTabView.statusLine(
            isRunning: false, runningText: "正在生成回顾", errorText: "本次失败说明",
            abandoned: dead, latest: done
        )
        XCTAssertFalse(reportedLive.contains("没有完成"),
                       "页面已经横幅报过一次，状态行不能再报一遍")
    }

    /// The store can see the dead run; the view has to read it from the
    /// database rather than only from this session's job.
    func testRefreshReadsTheFailureFromTheDatabase() throws {
        let source = try Self.read(
            "Sources/WeChatHUD/Views/Retrospective/RetrospectiveTabView.swift")
        let refresh = Self.slice(source, from: "private func refreshLatestRun", max: 500)
        XCTAssertTrue(refresh.contains("latestReviewRunAnyStatus()"),
                      "刷新必须从库里读到那次没跑完的回顾")
        XCTAssertTrue(refresh.contains("abandonedRun"), refresh)
    }

    // MARK: - Source reading

    private static func read(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<2 { dir = dir.deletingLastPathComponent() }
        let url = dir.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func slice(_ text: String, from anchor: String, max: Int) -> String {
        guard let start = text.range(of: anchor) else {
            XCTFail("anchor missing: \(anchor)")
            return ""
        }
        return String(text[start.lowerBound...].prefix(max))
    }
}
