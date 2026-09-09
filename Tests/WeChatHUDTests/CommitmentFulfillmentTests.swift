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
        let later = [msg(text: "Q2 方案发你了", t: 2000)]
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

    func testUnrelatedMediaDoesNotFulfillDeliverable() {
        let c = makeCommitment(content: "发文件给你")
        // An arbitrary image cannot prove that this particular file was delivered.
        let later = [msg(text: "", t: 2000, baseType: 3)]
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: c,
            subsequentSelfMessages: later,
            now: Date(timeIntervalSince1970: 3000)
        )
        if case .stillPending = result { /* ok */ } else {
            XCTFail("An attachment alone cannot identify a delivered promise: \(result)")
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
    func testAmbiguousNegativeFutureAndUnrelatedEvidenceRemainPending() {
        for text in ["发你了", "还没完成Q2方案", "Q2方案明天完成", "Q2方案完成了吗？", "Q3方案发你了", "Q2方案如果完成就发你", "Q2方案还差最后一页，其他已完成", "Q2方案第一部分完成了", "你说Q2方案完成了", "Q2方案待完成", "Q2方案完成后发你", "Q2方案正在完成"] {
            let result = CommitmentTracker.evaluateFulfillment(
                commitment: makeCommitment(), subsequentSelfMessages: [msg(text: text, t: 2000)],
                now: Date(timeIntervalSince1970: 3000)
            )
            guard case .stillPending = result else { return XCTFail("False completion for \(text)") }
        }
    }

    func testEvidenceBeforePromiseDoesNotCloseIt() {
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: makeCommitment(), subsequentSelfMessages: [msg(text: "Q2方案发你了", t: 999)]
        )
        guard case .stillPending = result else { return XCTFail("Old evidence cannot close a new promise") }
    }

    func testAmbiguousEvidenceStillAllowsOverdueTransition() {
        let result = CommitmentTracker.evaluateFulfillment(
            commitment: makeCommitment(deadlineAt: Date(timeIntervalSince1970: 1500)),
            subsequentSelfMessages: [msg(text: "还没完成Q2方案", t: 2000)],
            now: Date(timeIntervalSince1970: 3000)
        )
        guard case .overdue = result else { return XCTFail("Unfulfilled promise should become overdue") }
    }

}
