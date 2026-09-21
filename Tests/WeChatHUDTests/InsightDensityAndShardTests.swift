import XCTest
@testable import WeChatHUD

/// Two algorithm defects in the insight pipeline that both survived every
/// render-level check because the numbers they produce look plausible.
///
/// 1. `bulkMessageStats` assigned per message DB instead of folding, and a
///    `Msg_<md5>` table legitimately lives in several `message_N.db` files — so
///    on a sharded library every overview number described whichever shard was
///    read last.
/// 2. 「近期」 was derived from `latestTs >= now-7d`, which adds a chat's *whole*
///    window history the moment one message lands inside the week. On a 30-day
///    window that pins the ratio near 30/7 ≈ 4.3 regardless of the week's
///    actual traffic, so the card read 「近期更活跃」 out of the length of the
///    range the user had picked.
final class InsightDensityAndShardTests: XCTestCase {

    private func stats(
        _ username: String,
        messages: Int,
        recent: Int,
        earliestTs: Int = 0,
        latestTs: Int = 0,
        selfInitiated: Bool = false
    ) -> ChatStatsData {
        ChatStatsData(
            chatUsername: username, chatName: username, isGroup: false, category: .other,
            messageCount: messages, myMessageCount: 0, participantCount: 2,
            messagesByHour: Array(repeating: 0, count: 24),
            messagesByWeekday: [], typeCounts: [:],
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: [],
            selfInitiated: selfInitiated, earliestTs: earliestTs, latestTs: latestTs,
            recentMessageCount: recent
        )
    }

    private func overview(
        _ allStats: [String: ChatStatsData],
        windowDays: Int
    ) -> ChatInsightEngine.GlobalOverview {
        ChatInsightEngine.computeGlobalOverview(
            allStats: allStats,
            contacts: [],
            commitments: [],
            replyDebtItems: [],
            vipUsernames: [],
            windowDays: windowDays
        )
    }

    // MARK: - 近期 is a span

    /// 300 messages spread evenly over 30 days means 70 in the last seven. The
    /// old formula returned 300/7 ÷ 300/30 ≈ 4.3 and called that "busier
    /// lately"; an even month is by definition not busier lately.
    func testEvenHistoryIsNotRecentActivity() {
        let even = [
            "a": stats("a", messages: 150, recent: 35),
            "b": stats("b", messages: 150, recent: 35),
        ]
        let ratio = overview(even, windowDays: 30).recentDensityRatio

        XCTAssertNotNil(ratio, "a 30-day window can compare a week against itself")
        XCTAssertEqual(ratio ?? 0, 1.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(ratio ?? 100, 1.3, "an even month must not read as 近期更活跃")
    }

    func testQuietWeekReadsAsQuiet() {
        let quiet = ["a": stats("a", messages: 300, recent: 0)]
        XCTAssertEqual(overview(quiet, windowDays: 30).recentDensityRatio ?? 99, 0, accuracy: 0.001)
    }

    func testBusyWeekReadsAsBusy() {
        let busy = ["a": stats("a", messages: 300, recent: 300)]
        XCTAssertEqual(overview(busy, windowDays: 30).recentDensityRatio ?? 0, 4.2857, accuracy: 0.01)
    }

    /// With a 7-day range, "recent" and "overall" are the same span and the
    /// ratio is 1.0 by construction. Reporting that as 节奏正常 would be a
    /// verdict with no evidence behind it.
    func testWindowTooShortToCompareYieldsNoVerdict() {
        let all = ["a": stats("a", messages: 100, recent: 100)]
        XCTAssertNil(overview(all, windowDays: 7).recentDensityRatio)
        XCTAssertNil(overview(all, windowDays: 3).recentDensityRatio)
    }

    // MARK: - Shards fold, they do not replace

    private func shard(
        total: Int,
        selfCount: Int,
        earliestTs: Int,
        latestTs: Int,
        selfInitiated: Bool,
        sender: String,
        recent: Int
    ) -> WeChatReader.BulkChatStats {
        var hourly = Array(repeating: 0, count: 24)
        hourly[9] = total
        var weekday = Array(repeating: 0, count: 7)
        weekday[1] = total
        return WeChatReader.BulkChatStats(
            chatUsername: "chat@chatroom",
            totalCount: total,
            selfCount: selfCount,
            senderCounts: [sender: total],
            hourlyBuckets: hourly,
            weekdayBuckets: weekday,
            typeCounts: [1: total],
            selfInitiated: selfInitiated,
            earliestTs: earliestTs,
            latestTs: latestTs,
            recentCount: recent
        )
    }

    func testSecondShardAddsToTheFirstInsteadOfReplacingIt() {
        let older = shard(total: 40, selfCount: 15, earliestTs: 1_000, latestTs: 2_000, selfInitiated: true, sender: "alice", recent: 5)
        let newer = shard(total: 60, selfCount: 25, earliestTs: 3_000, latestTs: 4_000, selfInitiated: false, sender: "bob", recent: 7)
        let merged = older.merged(with: newer)

        XCTAssertEqual(merged.totalCount, 100, "the whole point: a two-shard chat is not one shard")
        XCTAssertEqual(merged.selfCount, 40)
        XCTAssertEqual(merged.recentCount, 12)
        XCTAssertEqual(merged.earliestTs, 1_000)
        XCTAssertEqual(merged.latestTs, 4_000)
        XCTAssertEqual(merged.hourlyBuckets[9], 100)
        XCTAssertEqual(merged.weekdayBuckets[1], 100)
        XCTAssertEqual(merged.typeCounts[1], 100)
        XCTAssertEqual(merged.senderCounts["alice"], 40)
        XCTAssertEqual(merged.senderCounts["bob"], 60)
    }

    /// `selfInitiated` is "who spoke first in the window". Across shards that is
    /// whoever holds the oldest message, not whoever was read last.
    func testWhoSpokeFirstComesFromTheOldestShard() {
        let older = shard(total: 1, selfCount: 1, earliestTs: 100, latestTs: 100, selfInitiated: true, sender: "me", recent: 0)
        let newer = shard(total: 9, selfCount: 0, earliestTs: 500, latestTs: 900, selfInitiated: false, sender: "them", recent: 0)

        XCTAssertTrue(older.merged(with: newer).selfInitiated)
        XCTAssertTrue(newer.merged(with: older).selfInitiated, "fold order must not change the answer")
    }

    /// Overview rows used to keep only a display name, so tapping 「沉默的人」
    /// assigned that string to `selectedChat` and the detail pane bounced
    /// back to the overview. The engine has to emit the username.
    func testOneWayOverviewRowsKeepTheChatUsername() {
        let quiet = ChatStatsData(
            chatUsername: "wxid_quiet", chatName: "沉默的人", isGroup: false, category: .other,
            messageCount: 40, myMessageCount: 2, participantCount: 2,
            messagesByHour: Array(repeating: 0, count: 24),
            messagesByWeekday: [], typeCounts: [:],
            avgResponseTimeSeconds: 0, symmetryRatio: 0.1, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: [],
            selfInitiated: false, earliestTs: 0, latestTs: 0,
            recentMessageCount: 4
        )
        let o = overview(["wxid_quiet": quiet], windowDays: 30)
        XCTAssertEqual(o.oneWayChats.map(\.chatUsername), ["wxid_quiet"])
        XCTAssertEqual(o.oneWayChats.map(\.name), ["沉默的人"])
        XCTAssertEqual(o.topTimeBlackHoles.first?.chatUsername, "wxid_quiet")
    }
}
