import XCTest
@testable import WeChatHUD

/// 收尾词（ack）词表必须只有一份。
///
/// 旧代码里 ImportanceDetector.isAckOnly（判断「我的回复是不是纯 ack」）和
/// ReplyDebtScorer.isAckMessage（判断「对方这条值不值得回」）各自维护词表，后者
/// 多了「哈哈/666/👍」等词，于是同一句「哈哈」在两条路径上判定相反：我用「哈哈」
/// 回了实质请求时不会被判成「未实质回应」，而对方发来「哈哈」却被当成正事。
/// 这里锁住共用词表后的行为一致性。
final class AckVocabularyConsistencyTests: XCTestCase {

    func testSharedTokensAreAcksOnBothPaths() {
        let words = ["哈哈", "666", "👍", "嗯嗯", "收到", "ok", "OK", "明白"]
        for word in words {
            XCTAssertTrue(AckVocabulary.isAckToken(word), "\(word) 应被共享词表认作 ack")
            XCTAssertTrue(ImportanceDetector.isAckOnly(word), "\(word) 应在 isAckOnly 里也是 ack")
        }
    }

    func testRealQuestionsAreNotAcksOnEitherPath() {
        for text in ["明天上午能定吗？", "麻烦确认合同", "周三前给我稿子"] {
            XCTAssertFalse(AckVocabulary.isAckToken(text))
            XCTAssertFalse(ImportanceDetector.isAckOnly(text))
        }
    }

    func testHahaFromMeAfterSubstantiveAskIsUnsubstantiveReply() {
        // 「哈哈」现在在两条路径上一致：既算 ack（不构成实质回应），
        // 又会把前面的实质请求报成「未实质回应」。
        let seed = makeSeed(now: 400, unreadCount: 1, timeline: [
            entry("q1", "明天三点前给我确认，谢谢", 100),
            entry("q2", "哈哈", 130, fromSelf: true)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertEqual(items.first?.reasons.first?.code, .unsubstantiveReply)
    }

    func testHahaFromPeerAfterMyEarlierReplyDoesNotCreateDebt() {
        // 对方的一句「哈哈」只是收尾语，不该变成一条要我回的正事。
        let seed = makeSeed(now: 400, unreadCount: 0, timeline: [
            entry("p1", "方案我明天发你", 100, fromSelf: true),
            entry("p2", "哈哈", 130)
        ])

        let items = ReplyDebtScorer.build(seeds: [seed], config: ReplyDebtConfig())

        XCTAssertTrue(items.isEmpty)
    }

    private func makeSeed(
        now: Int,
        unreadCount: Int,
        timeline: [ReplyDebtScorer.TimelineEntry]
    ) -> ReplyDebtScorer.Seed {
        ReplyDebtScorer.Seed(
            session: SessionInfo(
                username: "alice",
                isGroup: false,
                unreadCount: unreadCount,
                lastTimestamp: timeline.map(\.message.createTime).max() ?? 0
            ),
            chatName: "Alice",
            isWhitelisted: true,
            isVIP: false,
            latestInbound: nil,
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
        fromSelf: Bool = false
    ) -> ReplyDebtScorer.TimelineEntry {
        ReplyDebtScorer.TimelineEntry(
            message: MessageInfo(
                id: id,
                chatUsername: "alice",
                chatName: "Alice",
                senderUsername: fromSelf ? "me" : "peer",
                senderName: fromSelf ? "Me" : "Peer",
                text: text,
                baseType: 1,
                subType: 0,
                createTime: ts
            ),
            isFromSelf: fromSelf,
            isAtMe: false
        )
    }
}
