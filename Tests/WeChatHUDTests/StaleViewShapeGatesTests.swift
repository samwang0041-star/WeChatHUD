import XCTest

/// Gates for the one bug class the view layer cannot prove behaviorally: a view
/// that keeps a value it derived once from something that changes underneath it.
/// None of these three surfaces has a test seam — hosting a `View` and driving
/// `@State` from an XCTest is not possible here — so the shape is pinned at the
/// source instead, because each one is a user-visible wrong fact rather than a
/// cosmetic stale frame.
final class StaleViewShapeGatesTests: XCTestCase {

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (try? String(contentsOfFile: root + "/Sources/WeChatHUD/" + relative, encoding: .utf8)) ?? ""
    }

    /// 「这件事从哪里来」 stays mounted while the 待办 selection changes under it
    /// (row click, range pill, search, or a scan auto-completing the open item).
    /// An un-keyed `.task` left the previous item's chat window on screen under
    /// the new item's title.
    func testSourcePaneKeysItsLoadToTheItemItDisplays() {
        let file = source("Views/DiscussionSourceView.swift")
        XCTAssertFalse(file.isEmpty, "DiscussionSourceView not found")
        XCTAssertTrue(
            file.contains(".task(id: item.id)"),
            "the source window must reload when the item changes under a mounted view"
        )
        XCTAssertFalse(
            file.contains(".task {"),
            "an un-keyed task here is the stale-source bug coming back"
        )
    }

    /// The sidebar's per-day counts are computed by a walk that takes one read
    /// per chat, so a fast date switch can land the older result last; and a
    /// chat with zero messages that day must not fall back to the *window*
    /// count, which is a different question.
    func testSidebarDayStatsGuardTheirOwnRequest() {
        let file = source("Views/Analytics/InsightSidebarView.swift")
        XCTAssertFalse(file.isEmpty, "InsightSidebarView not found")
        XCTAssertTrue(
            file.contains("guard key == dayStatsTaskID"),
            "the async write must drop a result whose request is no longer current"
        )
        XCTAssertTrue(
            file.contains("dayStatsByChat[username]?.messageCount ?? 0"),
            "a day with no record has to read as zero, not as the window total"
        )
    }

    /// The 周报 roll-up counts a catalog snapshot; without a live trigger it
    /// kept yesterday's numbers across a scan and across an account switch.
    func testWeeklyReportFollowsTheLiveDiscussionList() {
        let file = source("Views/DailyReportTabView.swift")
        XCTAssertFalse(file.isEmpty, "DailyReportTabView not found")
        XCTAssertTrue(
            file.contains("onChange(of: monitor.discussionItems"),
            "the weekly catalog must be re-read when the rows it counts change"
        )
    }
}
