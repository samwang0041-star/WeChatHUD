import XCTest
@testable import WeChatHUD

final class MessageHelpersTests: XCTestCase {

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
