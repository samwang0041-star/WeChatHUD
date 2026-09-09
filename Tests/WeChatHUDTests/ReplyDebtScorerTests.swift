import XCTest
@testable import WeChatHUD

final class ReplyDebtScorerTests: XCTestCase {
    func testPrivateChatWithoutReplyCreatesDebtEvenWhenRead() {
        let item = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 0,
                    latestInbound: 500,
                    latestInboundText: "方案你定了吗？",
                    latestOutbound: 100,
                    now: 560
                )
            ],
            config: ReplyDebtConfig()
        ).first

        XCTAssertEqual(item?.chatUsername, "alice")
        XCTAssertEqual(item?.priority, .p0)
        XCTAssertTrue(item?.reasons.contains(where: { $0.code == .privateChat }) == true)
    }

    func testDebtContextKeepsExactLatestInboundIdentityAndFullText() {
        let text = "方案你定了吗？" + String(repeating: " 请给我完整上下文。", count: 12)
        let item = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 0,
                    latestInbound: 500,
                    latestInboundText: text,
                    latestOutbound: 100,
                    now: 560
                )
            ],
            config: ReplyDebtConfig()
        ).first

        XCTAssertEqual(item?.contextNotification?.messageID, "alice-in")
        XCTAssertEqual(item?.contextNotification?.rawText, text)
        XCTAssertEqual(item?.contextNotification?.timestamp, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(item?.contextNotification?.senderName, "Bob")
    }

    func testUnsubstantiveReplyContextUsesTheInboundSourceMessage() {
        let inboundText = "明天什么时候签？请确认最终日期。"
        let item = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 500,
                    latestInboundText: inboundText,
                    latestOutbound: 600,
                    now: 660
                )
            ],
            config: ReplyDebtConfig()
        ).first

        XCTAssertEqual(item?.reasons.first?.code, .unsubstantiveReply)
        XCTAssertEqual(item?.contextNotification?.messageID, "alice-in")
        XCTAssertEqual(item?.contextNotification?.rawText, inboundText)
        XCTAssertEqual(item?.contextNotification?.timestamp, Date(timeIntervalSince1970: 500))
    }

    func testLatestOutboundClearsDebt() {
        let items = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 200,
                    latestInboundText: "你看下",
                    latestOutbound: 300,
                    now: 360
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testAtMentionGroupBeatsNormalPrivateChat() {
        let group = makeSeed(
            username: "team@chatroom",
            chatName: "项目群",
            isGroup: true,
            unreadCount: 1,
            latestInbound: 300,
            latestInboundText: "@yuri 马上确认一下时间？",
            latestOutbound: 100,
            inboundCountSinceLastOutbound: 2,
            isAtMention: true,
            now: 360
        )
        let privateChat = makeSeed(
            username: "alice",
            chatName: "Alice",
            isGroup: false,
            unreadCount: 0,
            latestInbound: 320,
            latestInboundText: "你看下？",
            latestOutbound: 100,
            now: 360
        )

        let items = ReplyDebtScorer.build(seeds: [privateChat, group], config: ReplyDebtConfig())

        XCTAssertEqual(items.first?.chatUsername, "team@chatroom")
        XCTAssertEqual(items.first?.priority, .p0)
        XCTAssertEqual(items.dropFirst().first?.chatUsername, "alice")
    }

    func testSilencedDebtStaysHiddenUntilNewerInbound() {
        let hidden = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 200,
                    latestInboundText: "你看下？",
                    latestOutbound: 100,
                    chatAction: .init(silencedAt: 250, snoozedUntil: 0),
                    now: 300
                )
            ],
            config: ReplyDebtConfig()
        )
        let reopened = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 300,
                    latestInboundText: "你看下？",
                    latestOutbound: 100,
                    chatAction: .init(silencedAt: 250, snoozedUntil: 0),
                    now: 360
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(reopened.first?.chatUsername, "alice")
    }

    func testSnoozedDebtIsHiddenUntilExpiry() {
        let hidden = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 200,
                    latestInboundText: "你看下？",
                    latestOutbound: 100,
                    chatAction: .init(silencedAt: 0, snoozedUntil: 400),
                    now: 300
                )
            ],
            config: ReplyDebtConfig()
        )
        let visible = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 500,
                    latestInboundText: "你看下？",
                    latestOutbound: 100,
                    chatAction: .init(silencedAt: 0, snoozedUntil: 550),
                    now: 600
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(visible.first?.chatUsername, "alice")
    }

    func testOldActionableAskDoesNotDisappearAfterTwoHours() {
        let items = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 1_000,
                    latestInboundText: "麻烦确认一下合同可以签吗？",
                    latestOutbound: 100,
                    now: 1_000 + 8_000
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertEqual(items.first?.chatUsername, "alice")
        XCTAssertTrue(items.first?.reasons.contains(where: { $0.code == .askSignal }) == true)
    }

    func testOldSubstantiveTimeAskDoesNotDisappearAfterTwoHours() {
        let items = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 0,
                    latestInbound: 1_000,
                    latestInboundText: "明天三点方便",
                    latestOutbound: 100,
                    now: 1_000 + 8_000
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertEqual(items.first?.chatUsername, "alice")
        XCTAssertTrue(items.first?.reasons.contains(where: { $0.code == .privateChat }) == true)
    }

    func testSameSecondOutboundBeforeInboundDoesNotClearDebt() {
        let items = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 1_000,
                    latestInboundText: "你看下这个方案？",
                    latestOutbound: 1_000,
                    inboundLocalId: 12,
                    outboundLocalId: 11,
                    now: 1_060
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertEqual(items.first?.chatUsername, "alice")
    }

    func testSameSecondOutboundAfterInboundClearsDebt() {
        let items = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 1,
                    latestInbound: 1_000,
                    latestInboundText: "你看下这个方案？",
                    latestOutbound: 1_000,
                    inboundLocalId: 11,
                    outboundLocalId: 12,
                    now: 1_060
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testOldLowSignalFollowupCanNaturallyEnd() {
        let items = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 0,
                    latestInbound: 1_000,
                    latestInboundText: "哈哈",
                    latestOutbound: 100,
                    now: 1_000 + 8_000
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertTrue(items.isEmpty)
    }

    private func makeSeed(
        username: String = "alice",
        chatName: String = "Alice",
        isGroup: Bool = false,
        unreadCount: Int,
        latestInbound: Int,
        latestInboundText: String,
        latestOutbound: Int?,
        inboundLocalId: Int = 0,
        outboundLocalId: Int = 0,
        inboundCountSinceLastOutbound: Int = 1,
        isWhitelisted: Bool = true,
        isVIP: Bool = false,
        isAtMention: Bool = false,
        chatAction: HUDStore.ChatActionState? = nil,
        now: Int
    ) -> ReplyDebtScorer.Seed {
        ReplyDebtScorer.Seed(
            session: SessionInfo(
                username: username,
                isGroup: isGroup,
                unreadCount: unreadCount,
                lastTimestamp: latestInbound
            ),
            chatName: chatName,
            isWhitelisted: isWhitelisted,
            isVIP: isVIP,
            latestInbound: MessageInfo(
                id: "\(username)-in",
                localId: inboundLocalId,
                chatUsername: username,
                chatName: chatName,
                senderUsername: isGroup ? "bob" : username,
                senderName: "Bob",
                text: latestInboundText,
                baseType: 1,
                subType: 0,
                createTime: latestInbound
            ),
            latestOutbound: latestOutbound.map {
                MessageInfo(
                    id: "\(username)-out",
                    localId: outboundLocalId,
                    chatUsername: username,
                    chatName: chatName,
                    senderUsername: "me",
                    senderName: "Me",
                    text: "收到",
                    baseType: 1,
                    subType: 0,
                    createTime: $0
                )
            },
            inboundCountSinceLastOutbound: inboundCountSinceLastOutbound,
            isAtMention: isAtMention,
            chatAction: chatAction,
            now: Date(timeIntervalSince1970: Double(now)),
            contactReplyWindowMinutes: nil
        )
    }
}
