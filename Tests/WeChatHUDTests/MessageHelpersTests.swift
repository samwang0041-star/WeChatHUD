import XCTest
@testable import WeChatHUD

final class MessageHelpersTests: XCTestCase {

    func testResolveDeadlineUsesProvidedAnchor() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = MessageHelpers.resolveDeadline("+2h", relativeTo: anchor)

        XCTAssertEqual(deadline?.timeIntervalSince1970, anchor.addingTimeInterval(7200).timeIntervalSince1970)
    }

    func testReadableAIContentRejectsParserPlaceholders() {
        XCTAssertFalse(MessageHelpers.isReadableAIContent(""))
        XCTAssertFalse(MessageHelpers.isReadableAIContent("[消息]"))
        XCTAssertFalse(MessageHelpers.isReadableAIContent("发送消息"))
        XCTAssertFalse(MessageHelpers.isReadableAIContent("内容无法显示"))
        XCTAssertFalse(MessageHelpers.isReadableAIContent("大姑多次发送空白消息，内容无法显示"))
        XCTAssertTrue(MessageHelpers.isReadableAIContent("收到确认"))
        XCTAssertTrue(MessageHelpers.isReadableAIContent("文档内容无法显示了，帮看下"))
    }

    func testReadableAIContentMediaPlaceholderRequiresOptIn() {
        XCTAssertFalse(MessageHelpers.isReadableAIContent("[图片]"))
        XCTAssertTrue(MessageHelpers.isReadableAIContent("[图片]", allowMediaPlaceholder: true))
    }

    // MARK: - isAtMe

    func testIsAtMeWithUsername() {
        XCTAssertTrue(MessageHelpers.isAtMe("请@wxid_abc 看看", myUsername: "wxid_abc"))
        XCTAssertFalse(MessageHelpers.isAtMe("请@wxid_abc 看看", myUsername: "wxid_xyz"))
    }

    func testIsAtMeAllChinese() {
        XCTAssertTrue(MessageHelpers.isAtMe("@所有人 下午开会", myUsername: ""))
    }

    func testIsAtMeAllEnglish() {
        XCTAssertTrue(MessageHelpers.isAtMe("@ALL check this", myUsername: ""))
        XCTAssertTrue(MessageHelpers.isAtMe("@all please review", myUsername: ""))
    }

    func testIsAtMeNoMatch() {
        XCTAssertFalse(MessageHelpers.isAtMe("普通消息", myUsername: "wxid_abc"))
    }

    func testIsAtMeEmptyUsername() {
        // Empty username should only match @所有人 and @all
        XCTAssertFalse(MessageHelpers.isAtMe("@wxid_abc hello", myUsername: ""))
        XCTAssertTrue(MessageHelpers.isAtMe("@所有人", myUsername: ""))
    }

    // WeChat stores @mentions in message text as "@DisplayName<space>"
    // (ordinary space or U+2005), NOT the wxid. Pre-fix: detection
    // failed because `isAtMe` only checked the wxid.
    func testIsAtMeMatchesDisplayName() {
        XCTAssertTrue(MessageHelpers.isAtMe(
            "@张三 明天几点到？", myUsername: "wxid_abc", myDisplayName: "张三"))
    }

    func testIsAtMeMatchesDisplayNameWithU2005() {
        // U+2005 FOUR-PER-EM SPACE — WeChat's canonical @mention terminator.
        let text = "大家好 @张三\u{2005}请看一下这个"
        XCTAssertTrue(MessageHelpers.isAtMe(text, myUsername: "wxid_abc", myDisplayName: "张三"))
    }

    func testIsAtMeMatchesLearnedAlias() {
        // Group nickname that WeChatReader learned via realSenderId==0 fallback.
        XCTAssertTrue(MessageHelpers.isAtMe(
            "@老王 帮我看下", myUsername: "wxid_abc",
            myDisplayName: "王大明", mySelfNames: ["老王", "Wang"]))
    }

    func testIsAtMeBoundaryPreventsPartialMatch() {
        // Short display name like "大" must not match inside "@大家好".
        XCTAssertFalse(MessageHelpers.isAtMe(
            "@大家好 开会啦", myUsername: "", myDisplayName: "大"))
    }

    func testIsAtMeBoundaryAtEndOfString() {
        // "@张三" at end of string (no trailing space) should still match.
        XCTAssertTrue(MessageHelpers.isAtMe(
            "点名 @张三", myUsername: "", myDisplayName: "张三"))
    }

    func testIsAtMeNoFalsePositiveOnOthers() {
        // @someone_else — must NOT match.
        XCTAssertFalse(MessageHelpers.isAtMe(
            "@李四 来一下", myUsername: "wxid_abc", myDisplayName: "张三"))
    }

    func testIsAtMeIgnoresEmptyDisplayNameDefault() {
        // Empty display name + empty self-aliases ⇒ never a bare "@" match.
        XCTAssertFalse(MessageHelpers.isAtMe("@ hello", myUsername: "wxid_abc"))
    }

    // MARK: - isFromSelf

    private func makeMsg(
        id: String = "m1",
        chatUsername: String = "peer",
        senderUsername: String = "wxid_me",
        text: String = "hi"
    ) -> MessageInfo {
        MessageInfo(
            id: id, chatUsername: chatUsername, chatName: "Chat",
            senderUsername: senderUsername, senderName: "Me",
            text: text, baseType: 1, subType: 0, createTime: 1700000000
        )
    }

    func testIsFromSelfDirectMatch() {
        let msg = makeMsg(senderUsername: "wxid_me")
        XCTAssertTrue(MessageHelpers.isFromSelf(msg, chatUsername: "peer", myUsername: "wxid_me"))
    }

    func testIsFromSelfNoMatch() {
        let msg = makeMsg(senderUsername: "wxid_other")
        XCTAssertFalse(MessageHelpers.isFromSelf(msg, chatUsername: "wxid_other", myUsername: "wxid_me"))
    }

    func testIsFromSelfPrivateChatFallback() {
        // In 1-on-1 chat, sender != peer → must be self
        let msg = makeMsg(chatUsername: "peer", senderUsername: "wxid_unknown")
        XCTAssertTrue(MessageHelpers.isFromSelf(msg, chatUsername: "peer", myUsername: ""))
    }

    func testIsFromSelfGroupChatNoFallback() {
        // In group chat, don't use the 1-on-1 fallback
        let msg = makeMsg(chatUsername: "room@chatroom", senderUsername: "wxid_other")
        XCTAssertFalse(MessageHelpers.isFromSelf(msg, chatUsername: "room@chatroom", myUsername: "wxid_me"))
    }

    func testIsFromSelfEmptySenderNoAssumption() {
        // Empty sender username → don't assume self
        let msg = makeMsg(senderUsername: "")
        XCTAssertFalse(MessageHelpers.isFromSelf(msg, chatUsername: "peer", myUsername: "wxid_me"))
    }

    // WeChatReader learns group-chat nicknames as self-aliases when
    // name2id lookup fails and realSenderId==0. Callers that don't
    // forward `mySelfNames` used to mis-classify these as "from peer".
    func testIsFromSelfGroupAlias() {
        let msg = makeMsg(chatUsername: "room@chatroom", senderUsername: "老王")
        // Without aliases → misclassified as peer.
        XCTAssertFalse(MessageHelpers.isFromSelf(
            msg, chatUsername: "room@chatroom", myUsername: "wxid_me"))
        // With the learned alias → correctly self.
        XCTAssertTrue(MessageHelpers.isFromSelf(
            msg, chatUsername: "room@chatroom", myUsername: "wxid_me",
            mySelfNames: ["老王"]))
    }

    // MARK: - unreadStatus

    func testUnreadStatusAnswered() {
        let status = MessageHelpers.unreadStatus(
            replied: true, timestamp: Date(), isVIP: false,
            thresholds: UnreadThresholds()
        )
        XCTAssertEqual(status, .answered)
    }

    func testUnreadStatusPending() {
        let status = MessageHelpers.unreadStatus(
            replied: false, timestamp: Date(), isVIP: false,
            thresholds: UnreadThresholds()
        )
        XCTAssertEqual(status, .pending)
    }

    func testUnreadStatusOverdue() {
        let oldTime = Date(timeIntervalSinceNow: -200 * 60)  // 200 min ago
        let status = MessageHelpers.unreadStatus(
            replied: false, timestamp: oldTime, isVIP: false,
            thresholds: UnreadThresholds(vipMinutes: 30, normalMinutes: 120)
        )
        XCTAssertEqual(status, .overdue)
    }

    func testUnreadStatusVIPOverdueFaster() {
        let recent = Date(timeIntervalSinceNow: -60 * 60)  // 60 min ago
        let normalStatus = MessageHelpers.unreadStatus(
            replied: false, timestamp: recent, isVIP: false,
            thresholds: UnreadThresholds(vipMinutes: 30, normalMinutes: 120)
        )
        let vipStatus = MessageHelpers.unreadStatus(
            replied: false, timestamp: recent, isVIP: true,
            thresholds: UnreadThresholds(vipMinutes: 30, normalMinutes: 120)
        )
        XCTAssertEqual(normalStatus, .pending)
        XCTAssertEqual(vipStatus, .overdue)
    }

    // MARK: - isIgnoredSender

    func testIsIgnoredSenderMatch() {
        let msg = makeMsg(chatUsername: "room@chatroom", senderUsername: "wxid_alice")
        let map: [String: Set<String>] = [
            "room@chatroom": ["username:wxid_alice"]
        ]
        XCTAssertTrue(MessageHelpers.isIgnoredSender(msg, ignoredSenderMap: map))
    }

    func testIsIgnoredSenderNoMatch() {
        let msg = makeMsg(chatUsername: "room@chatroom", senderUsername: "wxid_bob")
        let map: [String: Set<String>] = [
            "room@chatroom": ["username:wxid_alice"]
        ]
        XCTAssertFalse(MessageHelpers.isIgnoredSender(msg, ignoredSenderMap: map))
    }

    func testIsIgnoredSenderEmptyMap() {
        let msg = makeMsg()
        XCTAssertFalse(MessageHelpers.isIgnoredSender(msg, ignoredSenderMap: [:]))
    }

    // MARK: - resolveDeadline

    func testResolveDeadlineMinutes() {
        let deadline = MessageHelpers.resolveDeadline("+30m")
        XCTAssertNotNil(deadline)
        let diff = deadline!.timeIntervalSince(Date())
        XCTAssertTrue(diff > 1700 && diff < 1900)  // ~30 min ± margin
    }

    func testResolveDeadlineHours() {
        let deadline = MessageHelpers.resolveDeadline("+2h")
        XCTAssertNotNil(deadline)
        let diff = deadline!.timeIntervalSince(Date())
        XCTAssertTrue(diff > 7000 && diff < 7400)
    }

    func testResolveDeadlineDays() {
        let deadline = MessageHelpers.resolveDeadline("+1d")
        XCTAssertNotNil(deadline)
        let diff = deadline!.timeIntervalSince(Date())
        XCTAssertTrue(diff > 86000 && diff < 87000)
    }

    func testResolveDeadlineWeeks() {
        let deadline = MessageHelpers.resolveDeadline("+1w")
        XCTAssertNotNil(deadline)
        let diff = deadline!.timeIntervalSince(Date())
        XCTAssertTrue(diff > 600000 && diff < 610000)
    }

    func testResolveDeadlineInvalid() {
        XCTAssertNil(MessageHelpers.resolveDeadline(""))
        XCTAssertNil(MessageHelpers.resolveDeadline("30m"))  // missing +
        XCTAssertNil(MessageHelpers.resolveDeadline("+0m"))  // zero
        XCTAssertNil(MessageHelpers.resolveDeadline("+30x")) // unknown unit
        XCTAssertNil(MessageHelpers.resolveDeadline("+m"))   // no number
    }

    func testResolveDeadlineWhitespace() {
        XCTAssertNotNil(MessageHelpers.resolveDeadline("  +30m  "))
    }
}
