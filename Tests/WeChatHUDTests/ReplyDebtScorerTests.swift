import XCTest
@testable import WeChatHUD

final class ReplyDebtScorerTests: XCTestCase {
    func testPrivateChatWithoutReplyCreatesDebtEvenWhenRead() {
        let item = ReplyDebtScorer.build(
            seeds: [
                makeSeed(
                    unreadCount: 0,
                    latestInbound: 200,
                    latestInboundText: "方案你定了吗？",
                    latestOutbound: 100,
                    now: 260
                )
            ],
            config: ReplyDebtConfig()
        ).first

        XCTAssertEqual(item?.chatUsername, "alice")
        XCTAssertEqual(item?.priority, .p1)
        XCTAssertTrue(item?.reasons.contains(where: { $0.code == .privateChat }) == true)
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
                    latestInbound: 200,
                    latestInboundText: "你看下？",
                    latestOutbound: 100,
                    chatAction: .init(silencedAt: 0, snoozedUntil: 250),
                    now: 300
                )
            ],
            config: ReplyDebtConfig()
        )

        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(visible.first?.chatUsername, "alice")
    }

    private func makeSeed(
        username: String = "alice",
        chatName: String = "Alice",
        isGroup: Bool = false,
        unreadCount: Int,
        latestInbound: Int,
        latestInboundText: String,
        latestOutbound: Int?,
        inboundCountSinceLastOutbound: Int = 1,
        isWhitelisted: Bool = false,
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
            now: Date(timeIntervalSince1970: Double(now))
        )
    }
}
