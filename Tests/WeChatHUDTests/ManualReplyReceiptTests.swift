import XCTest
@testable import WeChatHUD

final class ManualReplyReceiptTests: XCTestCase {
    private func message(_ id: String, sender: String, time: Int, text: String) -> MessageInfo {
        MessageInfo(id: id, localId: Int(id.dropFirst()) ?? 0, chatUsername: "peer",
                    chatName: "同事", senderUsername: sender, senderName: sender,
                    text: text, baseType: 1, subType: 0, createTime: time)
    }

    func testNewMatchingOutgoingMessageConfirms() {
        let messages = [message("new", sender: "me", time: 1001, text: " 收到 ")]
        XCTAssertTrue(ManualReplyReceipt.confirms(messages: messages, previousIDs: ["old"],
            chatUsername: "peer", expectedText: "收到", startedAt: 1000,
            myUsername: "me", myDisplayName: "我", mySelfNames: []))
    }

    func testBaselineIDOtherSenderOrOldTimestampDoesNotConfirm() {
        let messages = [
            message("old", sender: "me", time: 1001, text: "收到"),
            message("other", sender: "peer", time: 1001, text: "收到"),
            message("late", sender: "me", time: 997, text: "收到")
        ]
        XCTAssertFalse(ManualReplyReceipt.confirms(messages: messages, previousIDs: ["old"],
            chatUsername: "peer", expectedText: "收到", startedAt: 1000,
            myUsername: "me", myDisplayName: "我", mySelfNames: []))
    }
}
