import XCTest
@testable import WeChatHUD

/// One clock for 「多久算超时」.
///
/// The window used to be re-derived in three places — `ReplyDebtScorer`,
/// `InboxContextBuilder`, and `InboxBuilder` (which read a reply-time
/// *suggestion* as if it were the threshold) — so the 超时 badge on a row
/// could disagree with the 超时 reason listed on the same row, and a
/// contact whose window was unset read as "overdue after 0 minutes".
final class OverdueWindowConsistencyTests: XCTestCase {

    // MARK: - The rule itself

    func testUnsetContactWindowFallsBackToTheTierNotToZero() {
        let config = ReplyDebtConfig()
        XCTAssertEqual(
            ReplyDebtConfig.overdueWindow(
                contactWindowMinutes: 0, isGroup: false, isAtMention: false,
                isVIP: false, config: config),
            120
        )
        XCTAssertEqual(
            ReplyDebtConfig.overdueWindow(
                contactWindowMinutes: 0, isGroup: false, isAtMention: false,
                isVIP: true, config: config),
            30
        )
        XCTAssertEqual(
            ReplyDebtConfig.overdueWindow(
                contactWindowMinutes: 0, isGroup: true, isAtMention: true,
                isVIP: false, config: config),
            30
        )
    }

    func testExplicitContactWindowOverridesEveryTier() {
        let config = ReplyDebtConfig()
        XCTAssertEqual(
            ReplyDebtConfig.overdueWindow(
                contactWindowMinutes: 45, isGroup: false, isAtMention: false,
                isVIP: true, config: config),
            45
        )
    }

    func testRuleFollowsAnEditedConfig() {
        var config = ReplyDebtConfig()
        config.normalOverdueMinutes = 240
        XCTAssertEqual(
            ReplyDebtConfig.overdueWindow(
                contactWindowMinutes: 0, isGroup: false, isAtMention: false,
                isVIP: false, config: config),
            240
        )
    }

    func testRolesThatDefaultToUnsetDoNotDefaultToOverdueImmediately() {
        // 0 is the "not set" marker these roles write, so the rule must map
        // it to a real window. If a role ever stops using 0 this test is
        // telling us the marker moved, which is the same bug in new clothing.
        for role in [ContactRole.acquaintance, .groupOnly, .service] {
            XCTAssertEqual(role.defaultReplyWindowMinutes, 0)
            XCTAssertGreaterThan(
                ReplyDebtConfig.overdueWindow(
                    contactWindowMinutes: role.defaultReplyWindowMinutes,
                    isGroup: false, isAtMention: false, isVIP: false,
                    config: ReplyDebtConfig()),
                0
            )
        }
    }

    // MARK: - Scorer

    func testScorerMarksAFreshUnsetWindowMessageNotOverdue() {
        // 89 minutes old, acquaintance-level contact whose window is unset.
        // Before the fix this row was permanently 超时 with a count equal to
        // the message's age.
        let item = ReplyDebtScorer.build(
            seeds: [makeSeed(latestInbound: 500, minutesOld: 89, contactWindowMinutes: 0)],
            config: ReplyDebtConfig()
        ).first

        XCTAssertNotNil(item)
        XCTAssertEqual(item?.overdueThresholdMinutes, 120)
        XCTAssertFalse(item!.reasons.contains { $0.code == .overdue })
    }

    func testScorerPublishesTheVipWindowItUsed() {
        let item = ReplyDebtScorer.build(
            seeds: [makeSeed(latestInbound: 500, minutesOld: 45, isVIP: true)],
            config: ReplyDebtConfig()
        ).first

        XCTAssertEqual(item?.overdueThresholdMinutes, 30)
        XCTAssertTrue(item!.reasons.contains { $0.code == .overdue })
    }

    // MARK: - Scorer → inbox agreement

    func testInboxBadgeMatchesTheReasonTheScorerEmitted() {
        for minutesOld in [10, 90, 119, 120, 121, 240] {
            let debt = ReplyDebtScorer.build(
                seeds: [makeSeed(latestInbound: 500, minutesOld: minutesOld)],
                config: ReplyDebtConfig()
            )
            let now = Date(timeIntervalSince1970: Double(500 + minutesOld * 60))
            let inbox = InboxBuilder.build(
                replyDebtItems: debt,
                notifications: [],
                dismissed: [:],
                now: now
            )
            let row = inbox.active.first
            let item = debt.first!
            let scored = item.reasons.contains { $0.code == .overdue }

            XCTAssertEqual(row?.isOverdue, scored, "\(minutesOld) min old")
            XCTAssertEqual(
                row?.overdueMinutes,
                scored ? minutesOld - item.overdueThresholdMinutes : 0,
                "\(minutesOld) min old"
            )
        }
    }

    func testInboxCountsOverdueFromThePublishedWindow() {
        let debt = ReplyDebtScorer.build(
            seeds: [makeSeed(latestInbound: 500, minutesOld: 150, contactWindowMinutes: 60)],
            config: ReplyDebtConfig()
        )
        let row = InboxBuilder.build(
            replyDebtItems: debt,
            notifications: [],
            dismissed: [:],
            now: Date(timeIntervalSince1970: Double(500 + 150 * 60))
        ).active.first

        XCTAssertEqual(row?.overdueThresholdMinutes, 60)
        XCTAssertEqual(row?.overdueMinutes, 90)
    }

    // MARK: - Helper

    private func makeSeed(
        latestInbound: Int,
        minutesOld: Int,
        contactWindowMinutes: Int? = nil,
        isVIP: Bool = false
    ) -> ReplyDebtScorer.Seed {
        let now = latestInbound + minutesOld * 60
        return ReplyDebtScorer.Seed(
            session: SessionInfo(
                username: "alice", isGroup: false, unreadCount: 1, lastTimestamp: latestInbound
            ),
            chatName: "Alice",
            isWhitelisted: true,
            isVIP: isVIP,
            latestInbound: MessageInfo(
                id: "alice-in", localId: 0, chatUsername: "alice", chatName: "Alice",
                senderUsername: "alice", senderName: "Alice",
                text: "方案你定了吗？", baseType: 1, subType: 0, createTime: latestInbound
            ),
            latestOutbound: nil,
            inboundCountSinceLastOutbound: 1,
            isAtMention: false,
            chatAction: nil,
            now: Date(timeIntervalSince1970: Double(now)),
            contactReplyWindowMinutes: contactWindowMinutes
        )
    }
}
