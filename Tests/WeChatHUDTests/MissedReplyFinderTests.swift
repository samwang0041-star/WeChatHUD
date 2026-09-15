import XCTest
@testable import WeChatHUD

final class MissedReplyFinderTests: XCTestCase {

    func testPrivateUnrepliedInRangeIsListed() {
        let items = MissedReplyFinder.build(seeds: [
            seed(
                username: "alice",
                range: 100...400,
                timeline: [
                    entry("a1", "名单给我一下", 200)
                ]
            )
        ])
        XCTAssertEqual(items.map { $0.preview }, ["名单给我一下"])
        XCTAssertEqual(items.first?.isGroup, false)
        XCTAssertEqual(items.first?.unrepliedCount, 1)
        XCTAssertEqual(items.first?.id, "alice|a1")
        XCTAssertEqual(items.first?.sourceMessageID, "a1")
        XCTAssertEqual(items.first?.sourceText, "名单给我一下")
    }

    func testReplyAfterTheRangeClearsTheMiss() {
        let items = MissedReplyFinder.build(seeds: [
            seed(
                username: "alice",
                range: 100...400,
                timeline: [
                    entry("a1", "名单给我一下", 200),
                    entry("a2", "发你了，下午前到", 500, fromSelf: true)
                ]
            )
        ])
        XCTAssertTrue(items.isEmpty, "range 外的实质回复仍然算回过了")
    }

    func testAckOnlyReplyDoesNotClearTheMiss() {
        let items = MissedReplyFinder.build(seeds: [
            seed(
                username: "alice",
                range: 100...400,
                timeline: [
                    entry("a1", "周三前把最终稿发我", 200),
                    entry("a2", "嗯嗯", 260, fromSelf: true)
                ]
            )
        ])
        XCTAssertEqual(items.first?.preview, "周三前把最终稿发我")
    }

    func testGroupRequiresAtMention() {
        let chatter = seed(
            username: "team@chatroom",
            isGroup: true,
            range: 100...400,
            timeline: [
                entry("g1", "今晚聚餐谁来", 200, chat: "team@chatroom")
            ]
        )
        let mentioned = seed(
            username: "team@chatroom",
            isGroup: true,
            range: 100...400,
            timeline: [
                entry("g2", "@我 评审纪要你来写", 220, atMe: true, chat: "team@chatroom")
            ]
        )
        XCTAssertTrue(MissedReplyFinder.build(seeds: [chatter]).isEmpty)
        XCTAssertEqual(MissedReplyFinder.build(seeds: [mentioned]).first?.isAtMention, true)
    }

    func testLongSilenceDoesNotHideAnUnrepliedAsk() {
        // Live reply-debt ages a quiet thread out after two hours. A
        // missed-reply walk has to keep the original ask.
        let items = MissedReplyFinder.build(seeds: [
            seed(
                username: "alice",
                range: 100...20_000,
                timeline: [
                    entry("a1", "报价单你看了吗？", 200)
                ]
            )
        ])
        XCTAssertEqual(items.first?.preview, "报价单你看了吗？")
    }

    func testInboundOutsideRangeIsIgnored() {
        let items = MissedReplyFinder.build(seeds: [
            seed(
                username: "alice",
                range: 1000...2000,
                timeline: [
                    entry("old", "上周那件事", 50),
                    entry("fresh", "今天这个请回我", 1500)
                ]
            )
        ])
        XCTAssertEqual(items.map { $0.preview }, ["今天这个请回我"])
    }

    func testOldestUnrepliedInboundIsTheRow() {
        let items = MissedReplyFinder.build(seeds: [
            seed(
                username: "alice",
                range: 100...400,
                timeline: [
                    entry("a1", "第一问：名单", 150),
                    entry("a2", "还在吗", 300)
                ]
            )
        ])
        XCTAssertEqual(items.first?.preview, "第一问：名单")
        XCTAssertEqual(items.first?.unrepliedCount, 2)
        XCTAssertEqual(items.first?.id, "alice|a1")
    }

    func testTwoChatsDoNotShareAnIdentity() {
        let items = MissedReplyFinder.build(seeds: [
            seed(username: "alice", range: 100...400, timeline: [entry("a1", "名单给我一下", 200)]),
            seed(username: "bob", range: 100...400, timeline: [entry("b1", "合同你签了吗？", 220, chat: "bob")])
        ])
        XCTAssertEqual(Set(items.map { $0.id }).count, 2)
        XCTAssertTrue(items.contains { $0.id == "alice|a1" })
        XCTAssertTrue(items.contains { $0.id == "bob|b1" })
    }

    func testSuppressedConversationDoesNotSurface() {
        var closed = seed(
            username: "stranger",
            range: 100...400,
            timeline: [entry("s1", "在吗", 200)]
        )
        closed.admission = .suppress(.notFollowed)
        XCTAssertTrue(MissedReplyFinder.build(seeds: [closed]).isEmpty)
    }

    func testLast3DaysCoversTodayAndTwoDaysBack() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-15 06:13 +08
        let bounds = MissedReplyFinder.Window.last3Days.bounds(now: now, calendar: calendar)
        let startDay = calendar.startOfDay(for: bounds.start)
        let expected = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))
        XCTAssertEqual(startDay, expected)
        XCTAssertEqual(bounds.end, now)
    }

    func testCustomRangeSwapsInvertedDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let from = Date(timeIntervalSince1970: 1_700_200_000)
        let to = Date(timeIntervalSince1970: 1_700_000_000)
        let bounds = MissedReplyFinder.Window.custom.bounds(
            now: Date(timeIntervalSince1970: 1_700_300_000),
            calendar: calendar,
            customStart: from,
            customEnd: to
        )
        XCTAssertLessThan(bounds.start, bounds.end)
        XCTAssertEqual(calendar.startOfDay(for: bounds.start), calendar.startOfDay(for: to))
    }

    private func seed(
        username: String,
        isGroup: Bool = false,
        range: ClosedRange<Int>,
        timeline: [ReplyDebtScorer.TimelineEntry]
    ) -> MissedReplyFinder.Seed {
        MissedReplyFinder.Seed(
            session: SessionInfo(
                username: username,
                isGroup: isGroup,
                unreadCount: 1,
                lastTimestamp: timeline.map { $0.message.createTime }.max() ?? 0
            ),
            chatName: username,
            isVIP: false,
            admission: .admit(.followed),
            timeline: timeline,
            rangeStart: Date(timeIntervalSince1970: Double(range.lowerBound)),
            rangeEnd: Date(timeIntervalSince1970: Double(range.upperBound))
        )
    }

    private func entry(
        _ id: String,
        _ text: String,
        _ ts: Int,
        fromSelf: Bool = false,
        atMe: Bool = false,
        chat: String = "alice"
    ) -> ReplyDebtScorer.TimelineEntry {
        ReplyDebtScorer.TimelineEntry(
            message: MessageInfo(
                id: id,
                chatUsername: chat,
                chatName: chat,
                senderUsername: fromSelf ? "me" : "peer",
                senderName: fromSelf ? "Me" : "Peer",
                text: text,
                baseType: 1,
                subType: 0,
                createTime: ts
            ),
            isFromSelf: fromSelf,
            isAtMe: atMe
        )
    }
}
