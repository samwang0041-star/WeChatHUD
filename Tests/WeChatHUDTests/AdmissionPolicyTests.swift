import XCTest
@testable import WeChatHUD

/// The admission decision is the product contract for "谁的消息会提醒我".
/// It is a pure function precisely so every ordering rule can be pinned here
/// instead of being inferred from behaviour at runtime.
final class AdmissionPolicyTests: XCTestCase {

    private func context(
        mode: AdmissionMode = .whitelistOnly,
        isGroup: Bool = false,
        chatIsFollowed: Bool = false,
        chatIsVIP: Bool = false,
        senderIsVIP: Bool = false,
        senderIsWatchedMember: Bool = false,
        senderIsMuted: Bool = false,
        isAtMention: Bool = false
    ) -> AdmissionPolicy.Context {
        AdmissionPolicy.Context(
            mode: mode,
            isGroup: isGroup,
            chatIsFollowed: chatIsFollowed,
            chatIsVIP: chatIsVIP,
            senderIsVIP: senderIsVIP,
            senderIsWatchedMember: senderIsWatchedMember,
            senderIsMuted: senderIsMuted,
            isAtMention: isAtMention
        )
    }

    // MARK: - The narrow mode

    func testNarrowModeDropsSomeoneNobodySelected() {
        let decision = AdmissionPolicy.decide(context())

        XCTAssertEqual(decision, .suppress(.notFollowed))
        XCTAssertFalse(decision.isAdmitted)
    }

    func testNarrowModeAdmitsFollowedConversation() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(chatIsFollowed: true)),
            .admit(.followed)
        )
    }

    /// Following a room means "watch it for me", not "read me every line".
    /// Admitting on the follow alone would bury the inbox under busy groups.
    func testFollowedGroupDoesNotAdmitEveryMessage() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(isGroup: true, chatIsFollowed: true)),
            .suppress(.notFollowed)
        )
    }

    func testFollowedGroupStillAdmitsThePeopleSingledOutInIt() {
        XCTAssertEqual(
            AdmissionPolicy.decide(
                context(isGroup: true, chatIsFollowed: true, isAtMention: true)
            ),
            .admit(.atMention)
        )
        XCTAssertEqual(
            AdmissionPolicy.decide(
                context(isGroup: true, chatIsFollowed: true, senderIsWatchedMember: true)
            ),
            .admit(.watchedMember)
        )
    }

    /// A VIP room is an explicit "this whole room matters" instruction, so its
    /// messages keep surfacing the way they always have.
    func testVIPGroupAdmitsItsMessages() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(isGroup: true, chatIsVIP: true)),
            .admit(.vip)
        )
    }

    // MARK: - The wide mode

    func testWideModeAdmitsEverything() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(mode: .all)),
            .admit(.everyChat)
        )
    }

    /// Widening the net must not disable muting — a person the user muted stays
    /// muted, or the mute would look broken exactly when the inbox got noisy.
    func testWideModeStillHonoursMuting() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(mode: .all, senderIsMuted: true)),
            .suppress(.mutedPerson)
        )
    }

    // MARK: - Singled out

    func testVIPSenderIsAdmittedEvenInAnUnfollowedGroup() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(isGroup: true, senderIsVIP: true)),
            .admit(.vip)
        )
    }

    func testAtMentionIsAdmittedEvenInAnUnfollowedGroup() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(isGroup: true, isAtMention: true)),
            .admit(.atMention)
        )
    }

    func testWatchedMemberIsAdmittedInTheirGroup() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(isGroup: true, senderIsWatchedMember: true)),
            .admit(.watchedMember)
        )
    }

    /// The reason reported matters as much as the verdict: the row has to be
    /// able to say why it is on screen.
    func testSpecificReasonOutranksGenericFollow() {
        XCTAssertEqual(
            AdmissionPolicy.decide(context(chatIsFollowed: true, isAtMention: true)),
            .admit(.atMention)
        )
        XCTAssertEqual(
            AdmissionPolicy.decide(context(chatIsFollowed: true, senderIsVIP: true)),
            .admit(.vip)
        )
    }

    // MARK: - Muting wins

    /// A mute is the more recent and more specific instruction. Letting an
    /// older VIP flag override it is how a mute appears not to work.
    func testMutedPersonBeatsEveryAdmissionReason() {
        let cases: [AdmissionPolicy.Context] = [
            context(chatIsFollowed: true, senderIsMuted: true),
            context(chatIsVIP: true, senderIsMuted: true),
            context(senderIsVIP: true, senderIsMuted: true),
            context(senderIsWatchedMember: true, senderIsMuted: true),
            context(senderIsMuted: true, isAtMention: true),
            context(mode: .all, senderIsMuted: true),
        ]
        for context in cases {
            XCTAssertEqual(
                AdmissionPolicy.decide(context),
                .suppress(.mutedPerson),
                "muting must outrank every other reason"
            )
        }
    }

    // MARK: - Banners

    func testSuppressedMessageNeverRaisesABanner() {
        XCTAssertFalse(
            AdmissionPolicy.shouldRaiseBanner(
                decision: .suppress(.notFollowed),
                chatUsername: "g1@chatroom",
                isAtMention: true,
                atMutedGroups: []
            )
        )
    }

    /// Turning off @s for a noisy group must not throw the message away — the
    /// user still needs to find it. It just stops interrupting.
    func testMutedGroupKeepsTheMessageButDropsTheBanner() {
        let decision = AdmissionPolicy.decide(context(isGroup: true, isAtMention: true))
        XCTAssertTrue(decision.isAdmitted)
        XCTAssertFalse(
            AdmissionPolicy.shouldRaiseBanner(
                decision: decision,
                chatUsername: "noisy@chatroom",
                isAtMention: true,
                atMutedGroups: ["noisy@chatroom"]
            )
        )
    }

    func testMutedGroupStillBannersForSomeoneTheUserFollows() {
        let decision = AdmissionPolicy.decide(
            context(isGroup: true, senderIsWatchedMember: true)
        )
        XCTAssertTrue(
            AdmissionPolicy.shouldRaiseBanner(
                decision: decision,
                chatUsername: "noisy@chatroom",
                isAtMention: false,
                atMutedGroups: ["noisy@chatroom"]
            ),
            "the @ mute must not also silence the members the user singled out"
        )
    }

    // MARK: - Config decoding

    func testAdmissionConfigDefaultsToTheNarrowMode() {
        XCTAssertEqual(AdmissionConfig().mode, .whitelistOnly)
        XCTAssertTrue(AdmissionConfig().atMutedGroups.isEmpty)
    }

    /// A config written before a field existed must still decode, or an upgrade
    /// would reset the user's rules.
    func testAdmissionConfigToleratesOlderStoredShape() throws {
        let legacy = Data("{}".utf8)
        let config = try JSONDecoder().decode(AdmissionConfig.self, from: legacy)

        XCTAssertEqual(config.mode, .whitelistOnly)
        XCTAssertTrue(config.atMutedGroups.isEmpty)
    }

    func testAdmissionConfigRoundTrips() throws {
        let original = AdmissionConfig(mode: .all, atMutedGroups: ["a@chatroom"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdmissionConfig.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Deciding a whole conversation

    private func message(
        _ text: String,
        sender: String,
        name: String = "某人",
        chat: String = "peer"
    ) -> MessageInfo {
        MessageInfo(
            id: "m-\(text)-\(sender)",
            localId: 0,
            chatUsername: chat,
            chatName: chat,
            senderUsername: sender,
            senderName: name,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: 1_700_000_000
        )
    }

    private func rules(
        mode: AdmissionMode = .whitelistOnly,
        followed: Set<String> = [],
        vipChats: Set<String> = [],
        vipPeople: Set<String> = [],
        watched: [String: Set<String>] = [:],
        perChatMuted: [String: Set<String>] = [:],
        globalMuted: Set<String> = []
    ) -> AdmissionRules {
        AdmissionRules(
            config: AdmissionConfig(mode: mode),
            followedChats: followed,
            vipChats: vipChats,
            vipPeople: vipPeople,
            watchedMembers: watched,
            perChatMuted: perChatMuted,
            globalMuted: globalMuted
        )
    }

    private func decide(
        _ rules: AdmissionRules,
        messages: [MessageInfo],
        chat: String = "peer",
        isGroup: Bool = false,
        me: String = "me"
    ) -> AdmissionPolicy.Decision {
        rules.decision(
            chatUsername: chat,
            isGroup: isGroup,
            messages: messages,
            isFromSelf: { $0.senderUsername == me },
            isAtMe: { $0.text.contains("@me") }
        )
    }

    /// The newest line in a busy room is rarely the @ that matters. Admission
    /// has to look across the window, or a group @ would be missed the moment
    /// somebody else sent one more message.
    func testGroupAtIsFoundEvenWhenNewerTrafficFollowsIt() {
        let decision = decide(
            rules(),
            messages: [
                message("知道了", sender: "chatty"),
                message("在吗 @me 帮看下", sender: "boss"),
                message("路过", sender: "chatty"),
            ],
            chat: "team@chatroom",
            isGroup: true
        )

        XCTAssertEqual(decision, .admit(.atMention))
    }

    func testFollowedGroupWithNoReasonToSurfaceIsSuppressed() {
        let decision = decide(
            rules(followed: ["team@chatroom"]),
            messages: [message("今天天气不错", sender: "chatty")],
            chat: "team@chatroom",
            isGroup: true
        )

        XCTAssertEqual(decision, .suppress(.notFollowed))
    }

    func testFollowedPrivateChatIsAdmitted() {
        let decision = decide(
            rules(followed: ["peer"]),
            messages: [message("方案发你了", sender: "peer")]
        )

        XCTAssertEqual(decision, .admit(.followed))
    }

    /// The mode switch has to change this gate, because the inbox is built from
    /// reply debt — not from the unread list.
    func testWideModeAdmitsAConversationNobodyFollows() {
        let decision = decide(
            rules(mode: .all),
            messages: [message("你好", sender: "stranger")]
        )

        XCTAssertEqual(decision, .admit(.everyChat))
    }

    func testNarrowModeSuppressesAConversationNobodyFollows() {
        let decision = decide(
            rules(),
            messages: [message("你好", sender: "stranger")]
        )

        XCTAssertEqual(decision, .suppress(.notFollowed))
    }

    func testWatchedMemberSurfacesTheirGroup() {
        let decision = decide(
            rules(watched: ["team@chatroom": ["boss"]]),
            messages: [message("这版我确认了", sender: "boss", name: "老板")],
            chat: "team@chatroom",
            isGroup: true
        )

        XCTAssertEqual(decision, .admit(.watchedMember))
    }

    /// A muted sender must not drag a conversation in through the back door —
    /// even when they are the only one who spoke.
    func testOnlyMessagesFromAMutedSenderDoNotSurfaceTheChat() {
        let decision = decide(
            rules(followed: ["peer"], globalMuted: ["username:loud"]),
            messages: [message("在吗", sender: "loud", name: "很吵")]
        )

        XCTAssertEqual(decision, .suppress(.mutedPerson))
    }

    func testMutedSenderIsSkippedButOthersStillSurfaceTheChat() {
        let decision = decide(
            rules(followed: ["team@chatroom"], globalMuted: ["username:loud"]),
            messages: [
                message("在吗", sender: "loud", name: "很吵"),
                message("帮看下 @me", sender: "boss", name: "老板"),
            ],
            chat: "team@chatroom",
            isGroup: true
        )

        XCTAssertEqual(decision, .admit(.atMention))
    }

    func testOwnMessagesAloneDoNotSurfaceAConversation() {
        let decision = decide(
            rules(),
            messages: [message("我发的", sender: "me", name: "我")],
            chat: "stranger"
        )

        XCTAssertEqual(decision, .suppress(.notFollowed))
    }

    func testNoMessagesMeansNothingSurfaces() {
        XCTAssertEqual(decide(rules(mode: .all), messages: []), .suppress(.notFollowed))
    }
}
