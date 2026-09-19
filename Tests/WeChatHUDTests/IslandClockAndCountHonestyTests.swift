import XCTest
@testable import WeChatHUD

/// 岛与洞察页上「读不到却印成一个值」的三处收尾。
///
/// 共同形态：一个可选值 / 一个负数差值落进了唯一的显示分支，于是界面替算法
/// 许了一个它没有做过的测量。
final class IslandClockAndCountHonestyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 时钟回拨（唤醒 / NTP 校正）会让"回拨之前盖的时间戳"落在未来。
    /// 旧实现 `diff < 60 ⇒ 「刚刚」` 把负差值和"30 秒前"读成同一件事：
    /// 「刚刚同步」正好在最不该保证新鲜度的时候保证新鲜度。
    func testFutureTimestampIsNotReportedAsJustNow() {
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(7_200), now: now),
                       "时间待定", "两小时后的水印不是「刚刚」")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-30), now: now),
                       "刚刚", "正对照：30 秒前仍是刚刚")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-90), now: now),
                       "1 分钟前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-7_200), now: now),
                       "2 小时前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-200_000), now: now),
                       "2 天前")
    }

    /// 「时间待定同步」不是一句话：未知的那个东西就是全部信息。
    func testSuffixDoesNotStackOnTheUnknownClock() {
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(
            now.addingTimeInterval(600), suffix: "同步", now: now), "时间待定")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(
            now.addingTimeInterval(-3), suffix: "同步", now: now), "刚刚同步")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(
            now.addingTimeInterval(-3 * 3600), suffix: "同步", now: now), "3 小时前同步")
    }

    /// 横幅的 arrival 走同一套词汇，也要在同一处收敛。
    func testBannerArrivalUsesTheSameHonestLabel() {
        XCTAssertEqual(CompanionProductCopy.arrivalLabel(now.addingTimeInterval(600), now: now),
                       "时间待定")
    }

    /// 列表封顶 6 条时，徽标不许只报被截断后的那个数。
    func testRadarBadgeStatesTheTruncationItApplied() {
        XCTAssertEqual(InsightRadarBadge.text(shown: 6, total: 6), "6 条提醒")
        XCTAssertEqual(InsightRadarBadge.text(shown: 6, total: 9), "显示 6 · 共 9 条提醒")
        XCTAssertEqual(InsightRadarBadge.text(shown: 3, total: 9), "显示 3 · 共 9 条提醒")
        XCTAssertEqual(InsightRadarBadge.visibleLimit, 6, "封顶值只有一个来源")
        XCTAssertEqual(InsightRadarBadge.text(shown: 0, total: 0), "", "空态由页面自己说，徽标不占位")
    }

    /// 「还没算」和「算出来是 0」必须是两个字符串。
    func testPendingOverviewIsNotZeroOverview() {
        XCTAssertNotEqual(InsightOverviewCounts.text(for: nil),
                          InsightOverviewCounts.text(activeChats: 0, totalMessages: 0),
                          "两个答案塌成一个 = 把没算过说成没有")
        XCTAssertEqual(InsightOverviewCounts.text(for: nil), InsightOverviewCounts.pending)
        XCTAssertEqual(InsightOverviewCounts.text(activeChats: 0, totalMessages: 0),
                       "0 个活跃对话 · 0 条消息", "真零仍然照实报，不能一起藏掉")
    }

    /// 「本周推进了 N 件事」说的是一个时间点，而这份存储里承诺事项
    /// 根本没有完成时刻（只有来源消息时间与到期时间）。
    func testWeeklyCopyStopsClaimingACompletionTime() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/DailyReportTabView.swift")
        let page = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(page.contains("本周推进了"),
                       "没有 completed_at 就不许说事是本周推进的")
        XCTAssertTrue(page.contains("本周相关的事里，已完成"),
                       "换成能兑现的那句")
    }
    /// The 指挥中心 deadline column is the same vocabulary question as the island
    /// clock, and it had the same hole one layer down: a deadline 30 seconds old
    /// printed 「0 分钟前到期」. A zero where a measurement should be reads as
    /// "just now, no rush" on the one row whose job is to say how late it is.
    func testDeadlineColumnNeverPrintsAZeroForASubMinuteGap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DailyReportCommandCenterView.deadlineText(now.addingTimeInterval(-30), now: now),
                       "刚到期")
        XCTAssertEqual(DailyReportCommandCenterView.deadlineText(now.addingTimeInterval(30), now: now),
                       "即将到期")
        // Positive control: the buckets either side still do arithmetic.
        XCTAssertEqual(DailyReportCommandCenterView.deadlineText(now.addingTimeInterval(-120), now: now),
                       "2 分钟前到期")
        XCTAssertEqual(DailyReportCommandCenterView.deadlineText(now.addingTimeInterval(120), now: now),
                       "2 分钟后")
    }
}
