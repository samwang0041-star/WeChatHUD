import XCTest
@testable import WeChatHUD

final class DiscussionCorrectionTests: XCTestCase {
    private var store: HUDStore!

    override func setUpWithError() throws {
        store = HUDStore(dbPath: ":memory:")
        try store.open()
    }

    override func tearDown() {
        store.close()
        super.tearDown()
    }

    private var item: DiscussionItem {
        DiscussionItem(id: 12, chatUsername: "peer", chatName: "同事", kind: .todo,
                       owner: .mine, content: "确认方案", detail: nil, anchorMsgUID: "m1",
                       sourceTimestamp: 100, dueAt: nil, status: .pending, confidence: 0.8,
                       promptVersion: "test", createdAt: Date(timeIntervalSince1970: 100),
                       updatedAt: Date(timeIntervalSince1970: 100))
    }

    func testStatusAndOwnerCorrectionsProduceReviewableFeedback() throws {
        XCTAssertEqual(DiscussionCorrection.feedback(for: item, status: .done)?.feedbackType, .truePositive)
        XCTAssertEqual(DiscussionCorrection.feedback(for: item, status: .done)?.userAction, "marked_done")
        XCTAssertEqual(DiscussionCorrection.feedback(for: item, status: .dismissed)?.feedbackType, .falsePositive)
        XCTAssertNil(DiscussionCorrection.feedback(for: item, status: .pending))

        let ownerFeedback = try XCTUnwrap(DiscussionCorrection.feedback(for: item, correctedOwner: .theirs))
        XCTAssertEqual(ownerFeedback.msgUID, "discussion_item:12")
        XCTAssertEqual(ownerFeedback.userAction, "owner_corrected_theirs")
        XCTAssertTrue(ownerFeedback.originalOutput.contains("\"owner\":\"mine\""))
        XCTAssertTrue(ownerFeedback.originalOutput.contains("\"content\":\"确认方案\""))
        XCTAssertNil(DiscussionCorrection.feedback(for: item, correctedOwner: .mine))
    }

    func testOwnerCorrectionPersistsWithoutChangingStatus() throws {
        let inserted = try store.insertDiscussionItem(
            chatUsername: "peer", chatName: "同事", kind: .todo, owner: .mine,
            content: "确认方案", detail: nil, anchorMsgUID: "m1", sourceTimestamp: 100,
            dueAt: nil, confidence: 0.8, promptVersion: "test"
        )
        XCTAssertTrue(inserted)
        let id = try XCTUnwrap(store.loadDiscussionItems().first?.id)
        let insertedItem = try XCTUnwrap(store.loadDiscussionItems().first)
        try store.writeAIFeedback(try XCTUnwrap(DiscussionCorrection.feedback(for: insertedItem, correctedOwner: .theirs)))
        XCTAssertTrue(try store.updateDiscussionItemOwner(id: id, owner: .theirs))
        let updated = try XCTUnwrap(store.loadDiscussionItems().first)
        XCTAssertEqual(updated.owner, .theirs)
        XCTAssertEqual(updated.status, .pending)
        XCTAssertEqual(store.loadAIFeedback(msgUIDPrefix: "discussion_item:").first?.userAction, "owner_corrected_theirs")
        XCTAssertFalse(try store.updateDiscussionItemOwner(id: 999, owner: .mine))
    }

    func testRuntimeHintOnlyUsesMatchingChatCorrections() {
        func feedback(_ id: Int64, note: String?, action: String) -> AIFeedbackEntry {
            AIFeedbackEntry(id: id, ts: Date(timeIntervalSince1970: TimeInterval(id)),
                            msgUID: "discussion_item:\(id)", feedbackType: .falsePositive,
                            originalOutput: "{}", userAction: action, note: note)
        }
        let entries = [
            feedback(1, note: "other", action: "owner_corrected_theirs"),
            feedback(2, note: nil, action: "marked_done"),
            feedback(3, note: "peer", action: "owner_corrected_theirs"),
            feedback(4, note: "peer", action: "marked_dismissed")
        ]
        XCTAssertEqual(DiscussionCorrection.hint(entries: entries, chatUsername: "peer"), "确认忽略；责任人改为对方")
        XCTAssertEqual(DiscussionCorrection.hint(entries: entries, chatUsername: "missing"), "暂无")
    }
}
