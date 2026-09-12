import XCTest
@testable import WeChatHUD

/// 评分锚点：债务应该落在「最近一条还没被实质回应的入站」上。
///
/// 旧实现只看最新一条入站，并让 ack 直接短路整条债务，于是「对方先说正事 →
/// 我用一句『嗯』回完 → 对方再补个『好』收尾」时，前面那条没被回应的正事就消失
/// 了；群聊里「@我 周三前给我稿子」之后有人插一句「收到」，@ 也会被顶掉。
/// 这里同时锁住正例（实质请求在 ack 之前仍然出现）与负例（@ 之后只有闲聊不得
/// 复活、纯 ack 不得复活），避免修复被放宽成误报。
final class ReplyDebtAnchorTests: XCTestCase {

    // MARK: - 正例：ack 只降权，不短路

    func testSubstantiveAskSurvivesTrailingAckAfterMyAckReply() {
        // 对方问正事 → 我回了个「嗯嗯」 → 对方补一句「好」。
        let seed = makeSeed(now: 400, timeline: [
            entry("a1", "周三前把最终稿发我，谢谢", 100),
            entry("a2", "嗯嗯", 130, fromSelf: true),
            entry("a3", "好", 160)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertEqual(items.count, 1, "ack 之后的收尾语不能把没被实质回应的正事抹掉")
        XCTAssertEqual(items.first?.reasons.first?.code, .unsubstantiveReply)
        XCTAssertEqual(items.first?.preview, "周三前把最终稿发我，谢谢")
        XCTAssertEqual(items.first?.latestOutboundPreview, "嗯嗯", "降权后的债务仍应显示我实际回的那句")
    }

    func testAckAfterMentionDoesNotEraseGroupDebt() {
        // 群里：@我 派活 → 我 ack → 另一个人说「收到」。
        let seed = makeSeed(
            username: "team@chatroom", isGroup: true, unreadCount: 2, now: 400,
            timeline: [
                entry("g1", "@我 周三前给我稿子", 100, atMe: true, chat: "team@chatroom"),
                entry("g2", "嗯", 130, fromSelf: true, chat: "team@chatroom"),
                entry("g3", "收到", 160, chat: "team@chatroom")
            ]
        )

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertEqual(items.count, 1, "别人的「收到」不能顶掉我欠的那条 @ 请求")
        XCTAssertTrue(items.first?.isAtMention == true, "债务应仍带着 @ 标记")
        XCTAssertEqual(items.first?.preview, "@我 周三前给我稿子")
    }

    func testNewQuestionAfterEarlierExchangeIsFlaggedWhenOnlyAcked() {
        // 更早还有一段交流，然后是对方的新问题、我用 ack 敷衍：仍然要出现。
        let seed = makeSeed(now: 400, timeline: [
            entry("c0", "在吗", 50),
            entry("c1", "在的", 60, fromSelf: true),
            entry("c2", "明天上午能定吗？", 100),
            entry("c3", "嗯", 130, fromSelf: true)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertEqual(items.first?.reasons.first?.code, .unsubstantiveReply)
        XCTAssertEqual(items.first?.preview, "明天上午能定吗？")
    }

    // MARK: - 负例：不得复活成误报

    func testMentionFollowedByChitChatDoesNotResurrectDebt() {
        // 我真的回答了 @ 请求，后面群里继续闲聊：不得出现债务。
        let seed = makeSeed(
            username: "team@chatroom", isGroup: true, unreadCount: 0, now: 500,
            timeline: [
                entry("g1", "@我 这个方案你看下", 100, atMe: true, chat: "team@chatroom"),
                entry("g2", "看过了，明天给你具体意见", 130, fromSelf: true, chat: "team@chatroom"),
                entry("g3", "那我也等等", 200, chat: "team@chatroom")
            ]
        )

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertTrue(items.isEmpty, "闲聊不能把已经被实质回应的 @ 债务复活")
    }

    func testGroupMessageWithoutMentionIsNotDebtEvenWhenSubstantive() {
        // 群里没有 @我 的实质问题：即使我只回了 ack，也不是欠我的债务。
        let seed = makeSeed(
            username: "team@chatroom", isGroup: true, unreadCount: 1, now: 400,
            timeline: [
                entry("h1", "方案你定了吗？", 100, chat: "team@chatroom"),
                entry("h2", "嗯", 130, fromSelf: true, chat: "team@chatroom")
            ]
        )

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertTrue(items.isEmpty, "群里没点名的消息不该被算成我的债务")
    }

    func testPureAckWindowDoesNotCreateDebt() {
        // 双方都只是「好」「嗯」：没有实质请求，不算债务。
        let seed = makeSeed(now: 400, timeline: [
            entry("d1", "好", 100),
            entry("d2", "嗯", 130, fromSelf: true)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertTrue(items.isEmpty, "纯 ack 往来不该产生债务")
    }

    func testAckAfterRealAnswerClearsDebt() {
        let seed = makeSeed(now: 400, timeline: [
            entry("e1", "方案你定了吗？", 100),
            entry("e2", "定了，明天发你", 130, fromSelf: true),
            entry("e3", "好", 160)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertTrue(items.isEmpty, "我给了实质回复后，对方收尾不该再记债务")
    }

    func testOldAsksStillEndNaturallyAfterLongSilence() {
        // 我实质回过了，之后只有对方一句「好」，两小时后自然结束 —— 保持旧行为。
        let seed = makeSeed(unreadCount: 0, now: 160 + 3 * 3600, timeline: [
            entry("f1", "明天三点方便", 100),
            entry("f2", "具体的我明天发你", 130, fromSelf: true),
            entry("f3", "好", 160)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertTrue(items.isEmpty, "低信号收尾 + 长时间静默仍然自然结束")
    }

    // MARK: - 确定性

    func testDebtOrderIsDeterministicWhenPriorityScoreAndTimestampTie() {
        let now = 400
        let alpha = makeSeed(username: "alpha", now: now, timeline: [
            entry("x1", "周三前给我稿子", 100, chat: "alpha")
        ])
        let zeta = makeSeed(username: "zeta", now: now, timeline: [
            entry("y1", "周三前给我稿子", 100, chat: "zeta")
        ])

        let first = ReplyDebtScorer.build(seeds: [zeta, alpha], config: ReplyDebtConfig())
        let second = ReplyDebtScorer.build(seeds: [alpha, zeta], config: ReplyDebtConfig())

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.map(\.chatUsername), ["alpha", "zeta"], "同分同时间必须有稳定顺序")
        XCTAssertEqual(first.map(\.chatUsername), second.map(\.chatUsername), "输入顺序不能影响结果")
    }

    // MARK: - Fixtures

    private func makeSeed(
        username: String = "alice",
        isGroup: Bool = false,
        unreadCount: Int = 1,
        isWhitelisted: Bool = true,
        isVIP: Bool = false,
        now: Int,
        timeline: [ReplyDebtScorer.TimelineEntry]
    ) -> ReplyDebtScorer.Seed {
        ReplyDebtScorer.Seed(
            session: SessionInfo(
                username: username,
                isGroup: isGroup,
                unreadCount: unreadCount,
                lastTimestamp: timeline.map(\.message.createTime).max() ?? 0
            ),
            chatName: username,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            latestInbound: nil,   // 由评分器从窗口推导，避免和窗口不一致
            latestOutbound: nil,
            inboundCountSinceLastOutbound: 1,
            isAtMention: false,
            chatAction: nil,
            now: Date(timeIntervalSince1970: Double(now)),
            contactReplyWindowMinutes: nil,
            timeline: timeline
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
