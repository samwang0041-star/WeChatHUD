import XCTest
@testable import WeChatHUD

final class CommitmentFulfillmentTests: XCTestCase {

    private func makeCommitment(
        content: String = "发 Q2 方案给你",
        deadlineAt: Date? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> Commitment {
        Commitment(
            id: 1,
            msgUID: "m1",
            chatUsername: "peer",
            chatName: "Peer",
            content: content,
            commitTo: "Peer",
            deadlineAt: deadlineAt,
            confidence: 0.9,
            status: .pending,
            promptVersion: "commitment_v1",
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func msg(
        text: String,
        t: Int,
        baseType: Int = 1
    ) -> MessageInfo {
        MessageInfo(
            id: "m-\(t)",
            chatUsername: "peer", chatName: "Peer",
            senderUsername: "wxid_me", senderName: "Me",
            text: text, baseType: baseType, subType: 0, createTime: t
        )
    }

    func testFulfilledByKeyword() {
        let c = makeCommitment()
        let later = [msg(text: "发你了", t: 2000)]
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: c,
            subsequentSelfMessages: later,
            now: Date(timeIntervalSince1970: 3000)
        )
        guard case let .fulfilled(reason) = result else {
            return XCTFail("expected fulfilled, got \(result)")
        }
        XCTAssertTrue(reason.contains("发你了"))
    }

    func testFulfilledByFileSendWhenDeliverableMentioned() {
        let c = makeCommitment(content: "发文件给你")
        // baseType 3 = image (file-class in WeChat's encoding). The
        // evaluator should count this as evidence when the
        // commitment involves a deliverable.
        let later = [msg(text: "", t: 2000, baseType: 3)]
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: c,
            subsequentSelfMessages: later,
            now: Date(timeIntervalSince1970: 3000)
        )
        if case .fulfilled = result { /* ok */ } else {
            XCTFail("expected fulfilled by file send, got \(result)")
        }
    }

    func testOverdueWhenDeadlinePassed() {
        let c = makeCommitment(
            content: "我明天给你",
            deadlineAt: Date(timeIntervalSince1970: 2000)
        )
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: c,
            subsequentSelfMessages: [],
            now: Date(timeIntervalSince1970: 3000)
        )
        if case .overdue = result { /* ok */ } else {
            XCTFail("expected overdue, got \(result)")
        }
    }

    func testStillPendingWhenNoSignalAndDeadlineFuture() {
        let c = makeCommitment(
            content: "回头处理一下",
            deadlineAt: Date(timeIntervalSince1970: 5000)
        )
        let later = [msg(text: "稍后", t: 2000)]
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: c,
            subsequentSelfMessages: later,
            now: Date(timeIntervalSince1970: 3000)
        )
        if case .stillPending = result { /* ok */ } else {
            XCTFail("expected stillPending, got \(result)")
        }
    }

    func testNonDeliverableCommitmentDoesntCountFileSend() {
        // "开个会" doesn't mention sending anything — so a file send
        // should NOT count as fulfillment evidence for this kind
        // of commitment.
        let c = makeCommitment(content: "周四给个决定")
        let later = [msg(text: "", t: 2000, baseType: 3)]
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: c,
            subsequentSelfMessages: later,
            now: Date(timeIntervalSince1970: 3000)
        )
        if case .stillPending = result { /* ok */ } else {
            XCTFail("expected stillPending, got \(result)")
        }
    }
}
