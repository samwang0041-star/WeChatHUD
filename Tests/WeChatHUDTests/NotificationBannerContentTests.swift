import XCTest
@testable import WeChatHUD

/// The notification banner's copy rules.
///
/// The banner itself is only measurable (see `NotificationBannerLayoutTests`),
/// so every string it renders is derived by `NotificationBannerContent` and
/// asserted here: what is shown, what is deliberately left out, and how the
/// message text is presented.
final class NotificationBannerContentTests: XCTestCase {

    private func makeNotification(
        chatName: String = "项目协作群",
        senderName: String = "林晓",
        snippet: String = "明天下午评审，能否确认待办责任人的展示方案？",
        kind: HUDNotificationKind = .groupAt,
        isAtMention: Bool = true,
        timestamp: Date = Date()
    ) -> HUDNotification {
        HUDNotification(
            chatUsername: "wxid-fixture",
            chatName: chatName,
            senderUsername: "wxid-sender",
            senderName: senderName,
            attentionLevel: .vip,
            messageID: "content-\(UUID().uuidString)",
            rawText: snippet,
            snippet: snippet,
            isAtMention: isAtMention,
            timestamp: timestamp,
            kind: kind
        )
    }

    // MARK: - Identity line

    func testGroupMentionShowsSenderMentionAndConversation() {
        let content = NotificationBannerContent(notification: makeNotification())
        XCTAssertEqual(content.sender, "林晓")
        XCTAssertTrue(content.showsMention)
        XCTAssertEqual(content.conversation, "项目协作群")
    }

    /// A private chat's `chatName` is the contact's name: printing both would
    /// say the same thing twice on the one line the banner has.
    func testPrivateChatDoesNotRepeatTheNameAndDropsTheMentionChip() {
        let content = NotificationBannerContent(notification: makeNotification(
            chatName: "林晓", senderName: "林晓", kind: .privateChat, isAtMention: false
        ))
        XCTAssertEqual(content.sender, "林晓")
        XCTAssertNil(content.conversation)
        XCTAssertFalse(content.showsMention)
    }

    func testGroupWithoutWhitespaceNameFallsBackToSenderOnly() {
        let content = NotificationBannerContent(notification: makeNotification(chatName: "   "))
        XCTAssertNil(content.conversation)
    }

    /// Some scan paths carry no display name for the sender. A blank identity
    /// line would leave the banner unable to say who it is about, so the app's
    /// usual fallback applies — while the group is still named.
    func testMissingSenderNameFallsBackWithoutLosingTheConversation() {
        let blank = NotificationBannerContent(notification: makeNotification(senderName: "  "))
        XCTAssertEqual(blank.sender, "未知发送者")
        XCTAssertEqual(blank.conversation, "项目协作群")

        let totallyUnknown = NotificationBannerContent(notification: makeNotification(
            chatName: "", senderName: ""
        ))
        XCTAssertEqual(totallyUnknown.sender, "未知发送者")
        XCTAssertNil(totallyUnknown.conversation)
    }

    /// `.groupAt` means "the user was @-mentioned"; the chip must not depend on
    /// a flag that some scan paths set independently of the kind.
    func testGroupAtKeepsTheChipEvenWhenTheFlagIsUnset() {
        let content = NotificationBannerContent(notification: makeNotification(
            kind: .groupAt, isAtMention: false
        ))
        XCTAssertTrue(content.showsMention)
    }

    /// A plain group message (no mention) is information, not a summons: no
    /// mint chip, but the conversation is still named.
    func testPlainGroupMessageNamesTheGroupWithoutTheChip() {
        let content = NotificationBannerContent(notification: makeNotification(
            kind: .groupMessage, isAtMention: false
        ))
        XCTAssertFalse(content.showsMention)
        XCTAssertEqual(content.conversation, "项目协作群")
    }

    // MARK: - Arrival stamp

    func testArrivalUsesTheRelativeStampForAFreshMessage() {
        let now = Date()
        let content = NotificationBannerContent(
            notification: makeNotification(timestamp: now.addingTimeInterval(-120)),
            now: now
        )
        XCTAssertEqual(content.arrival, "2 分钟前")
    }

    // MARK: - The message itself

    /// Hard line breaks in the source message must not eat the three-line
    /// budget; a blank line would cost a whole line of the only content the
    /// banner has.
    func testMessageFoldsWhitespaceIntoOneFlowingBlock() {
        XCTAssertEqual(
            NotificationBannerContent.heroMessage("好的\n\n那明天见\t\t上午 10 点"),
            "好的 那明天见 上午 10 点"
        )
        XCTAssertEqual(
            NotificationBannerContent.heroMessage("  前后有空白  \n"),
            "前后有空白"
        )
    }

    func testMessageIsNeverRewrittenBeyondWhitespace() {
        let raw = "@我 老师您好，行业选金融类-银行 还是 其他？"
        XCTAssertEqual(NotificationBannerContent.heroMessage(raw), raw)
    }

    /// Media-only messages carry no text. An empty hero line would leave a card
    /// with nothing to read on the surface that exists to be read.
    func testMediaOnlyMessageSaysSoInsteadOfRenderingEmpty() {
        XCTAssertEqual(NotificationBannerContent.heroMessage(""), "收到一条新消息")
        XCTAssertEqual(NotificationBannerContent.heroMessage("\n \t"), "收到一条新消息")
        let content = NotificationBannerContent(notification: makeNotification(snippet: ""))
        XCTAssertEqual(content.message, "收到一条新消息")
    }

    // MARK: - Body action

    /// The body click has no visible label any more, so the words it reports
    /// have to match what the click actually does: a group mention opens the
    /// in-place briefing, everything else opens the conversation.
    func testOpenLabelMatchesWhatTheBodyClickDoes() {
        XCTAssertEqual(NotificationBannerContent(notification: makeNotification()).openLabel, "看看前后文")
        XCTAssertEqual(
            NotificationBannerContent(notification: makeNotification(
                chatName: "林晓", senderName: "林晓", kind: .privateChat, isAtMention: false
            )).openLabel,
            "打开对话"
        )
        XCTAssertEqual(
            NotificationBannerContent(notification: makeNotification(
                kind: .groupMessage, isAtMention: false
            )).openLabel,
            "打开对话"
        )
    }
}
