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

    /// The chip is a group affordance. A private chat can set `isAtMention`
    /// (the flag is computed from the text whatever the chat type), but nobody
    /// @-mentions you in a one-to-one chat, so the banner must not claim it.
    func testPrivateChatNeverShowsTheMentionChip() {
        let content = NotificationBannerContent(notification: makeNotification(
            chatName: "林晓", senderName: "林晓", kind: .privateChat, isAtMention: true
        ))
        XCTAssertFalse(content.showsMention)
    }

    func testGroupAtShowsTheMentionChip() {
        let content = NotificationBannerContent(notification: makeNotification(kind: .groupAt))
        XCTAssertTrue(content.showsMention)
        XCTAssertFalse(content.mentionIsBroadcast)
    }

    /// `@所有人` is a broadcast and `isAtMention` is true for it — that flag
    /// answers "does this concern me", which is why it interrupts. Rendering it
    /// as a personal "@你" would tell the user they were singled out when the
    /// whole group was addressed, and the mention token itself is stripped from
    /// the snippet, so nothing else on the card would correct that reading.
    func testBroadcastMentionIsReportedAsBroadcastNotAsAPersonalMention() {
        for text in [
            "@所有人 明天上午十点全员大会",
            "@All 明天上午十点全员大会",
            "@all 明天上午十点全员大会"
        ] {
            let content = NotificationBannerContent(notification: makeNotification(
                snippet: text, kind: .groupAt
            ))
            XCTAssertTrue(content.showsMention, "\(text): a broadcast still concerns the reader")
            XCTAssertTrue(content.mentionIsBroadcast, "\(text): must be reported as a broadcast")
        }
    }

    /// The mention is read from `rawText`, because the scan strips the leading
    /// token out of `snippet` before the banner ever sees it.
    func testBroadcastIsDetectedFromRawTextNotTheStrippedSnippet() {
        let notification = HUDNotification(
            chatUsername: "wxid-broadcast",
            chatName: "项目协作群",
            senderUsername: "wxid-peer",
            senderName: "王磊",
            attentionLevel: .vip,
            messageID: "broadcast-\(UUID().uuidString)",
            rawText: "@所有人 明天上午十点全员大会",
            snippet: "明天上午十点全员大会",
            isAtMention: true,
            timestamp: Date(),
            kind: .groupAt
        )
        let content = NotificationBannerContent(notification: notification)
        XCTAssertTrue(content.mentionIsBroadcast)
        XCTAssertFalse(content.message.contains("@所有人"), "the token itself is stripped upstream")
    }

    /// A personal @ must not be mistaken for a broadcast just because the text
    /// happens to mention a group of people.
    func testPersonalMentionIsNotReportedAsBroadcast() {
        for text in ["@我 麻烦看下这个", "明天上午十点全员大会", "@所有人以外的各位"] {
            let content = NotificationBannerContent(notification: makeNotification(
                snippet: text, kind: .groupAt
            ))
            XCTAssertFalse(content.mentionIsBroadcast, "\(text): this is not @所有人")
        }
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

    /// A group whose name happens to equal a member's name still names itself:
    /// the "would only repeat the sender" rule exists for private chats, and
    /// dropping the chat name here would leave the banner unable to say which
    /// group it came from.
    func testGroupNamedAfterAPersonStillNamesTheGroup() {
        let content = NotificationBannerContent(notification: makeNotification(
            chatName: "张三", senderName: "张三", kind: .groupAt
        ))
        XCTAssertEqual(content.conversation, "张三")
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

    /// An empty body is a parse failure, not a media message: every media type
    /// already arrives as its own placeholder (`[图片]`, `[语音]`, …) from the
    /// parser, so those reach the banner as text. The copy must not report a
    /// message it could not read as a normal arrival.
    func testUnreadableMessageSaysSoInsteadOfRenderingEmpty() {
        XCTAssertEqual(NotificationBannerContent.heroMessage(""), "内容无法显示")
        XCTAssertEqual(NotificationBannerContent.heroMessage("\n \t"), "内容无法显示")
        let content = NotificationBannerContent(notification: makeNotification(snippet: ""))
        XCTAssertEqual(content.message, "内容无法显示")
    }

    /// …and a real media message is not mistaken for one, because the parser
    /// gives it a placeholder rather than an empty string.
    func testMediaPlaceholdersAreShownAsTheMessage() {
        for placeholder in ["[图片]", "[语音]", "[视频]", "[表情]", "[位置]", "[通话]"] {
            XCTAssertEqual(NotificationBannerContent.heroMessage(placeholder), placeholder)
        }
    }

    // MARK: - Body action

    /// The body click has no visible label any more, so the words it reports
    /// have to match what the click actually does: a group mention opens the
    /// in-place briefing, everything else opens the conversation.
    ///
    /// `openLabel` is one string with two consumers — the tooltip the mouse
    /// user reads and the label VoiceOver announces — so these assertions pin
    /// what both of them say. They used to be written twice with different
    /// wording, which meant the tested string was not always the visible one.
    func testOpenLabelMatchesWhatTheBodyClickDoes() {
        XCTAssertEqual(
            NotificationBannerContent(notification: makeNotification()).openLabel,
            "看看这句话的前后文"
        )
        XCTAssertEqual(
            NotificationBannerContent(notification: makeNotification(
                chatName: "林晓", senderName: "林晓", kind: .privateChat, isAtMention: false
            )).openLabel,
            "打开这段对话"
        )
        XCTAssertEqual(
            NotificationBannerContent(notification: makeNotification(
                kind: .groupMessage, isAtMention: false
            )).openLabel,
            "打开这段对话"
        )
    }
}
