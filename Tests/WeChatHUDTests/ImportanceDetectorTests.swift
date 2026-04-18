import XCTest
@testable import WeChatHUD

final class ImportanceDetectorTests: XCTestCase {

    // MARK: - Signal detection

    func testMoneySignal() {
        XCTAssertTrue(ImportanceDetector.hasMoney("预算30万"))
        XCTAssertTrue(ImportanceDetector.hasMoney("费用 1,200 元"))
        XCTAssertTrue(ImportanceDetector.hasMoney("¥500"))
        XCTAssertTrue(ImportanceDetector.hasMoney("RMB 800"))
        XCTAssertFalse(ImportanceDetector.hasMoney("明天见"))
        XCTAssertFalse(ImportanceDetector.hasMoney("第3季度"))  // no amount unit
    }

    func testTimeSignal() {
        XCTAssertTrue(ImportanceDetector.hasTimeMarker("明天下午过来"))
        XCTAssertTrue(ImportanceDetector.hasTimeMarker("周五之前搞定"))
        XCTAssertTrue(ImportanceDetector.hasTimeMarker("ddl 下周"))
        XCTAssertFalse(ImportanceDetector.hasTimeMarker("你好吗"))
    }

    func testDecisionSignal() {
        XCTAssertTrue(ImportanceDetector.hasDecisionMarker("你看要不要做这个"))
        XCTAssertTrue(ImportanceDetector.hasDecisionMarker("选A还是选B"))
        XCTAssertFalse(ImportanceDetector.hasDecisionMarker("天气不错"))
    }

    func testCommitmentReferenceSignal() {
        XCTAssertTrue(ImportanceDetector.hasCommitmentMarker("上次说的那个事"))
        XCTAssertTrue(ImportanceDetector.hasCommitmentMarker("你答应过帮忙"))
        XCTAssertFalse(ImportanceDetector.hasCommitmentMarker("明天联系"))
    }

    func testSignalsMulti() {
        let matches = ImportanceDetector.signals("明天之前发30万预算")
        XCTAssertTrue(matches.contains("时间"))
        XCTAssertTrue(matches.contains("金额"))
    }

    // MARK: - Ack detection

    func testAckCommonReplies() {
        XCTAssertTrue(ImportanceDetector.isAckOnly("嗯"))
        XCTAssertTrue(ImportanceDetector.isAckOnly("嗯嗯"))
        XCTAssertTrue(ImportanceDetector.isAckOnly("好的！"))
        XCTAssertTrue(ImportanceDetector.isAckOnly("收到"))
        XCTAssertTrue(ImportanceDetector.isAckOnly("OK"))
        XCTAssertTrue(ImportanceDetector.isAckOnly("  ok  "))
        XCTAssertTrue(ImportanceDetector.isAckOnly(""))
    }

    func testAckNotForRealReplies() {
        XCTAssertFalse(ImportanceDetector.isAckOnly("明天 3 点我们开会"))
        XCTAssertFalse(ImportanceDetector.isAckOnly("我同意这个方案"))
        XCTAssertFalse(ImportanceDetector.isAckOnly("好的，我看一下然后回你"))  // has more content
    }

    // MARK: - Verdict

    private func msg(text: String, t: Int = 1_700_000_000) -> MessageInfo {
        MessageInfo(
            id: "m-\(t)-\(text.hashValue)",
            chatUsername: "peer", chatName: "C",
            senderUsername: "peer", senderName: "P",
            text: text, baseType: 1, subType: 0, createTime: t
        )
    }

    func testVerdictUnsubstantive() {
        let peer = msg(text: "预算30万，周五之前确认一下", t: 1000)
        let ackReply = msg(text: "嗯嗯", t: 1100)

        let result = ImportanceDetector.evaluate(
            peerMessage: peer,
            subsequentSelfMessages: [ackReply]
        )
        guard case let .unsubstantiveReply(signals) = result else {
            return XCTFail("expected unsubstantiveReply, got \(result)")
        }
        XCTAssertTrue(signals.contains("金额"))
        XCTAssertTrue(signals.contains("时间"))
    }

    func testVerdictAnsweredWhenSubstantiveReply() {
        let peer = msg(text: "预算 30 万", t: 1000)
        let realReply = msg(text: "我觉得可以，先按 25 走", t: 1100)

        let result = ImportanceDetector.evaluate(
            peerMessage: peer,
            subsequentSelfMessages: [realReply]
        )
        guard case .answered = result else {
            return XCTFail("expected answered, got \(result)")
        }
    }

    func testVerdictNotImportantForCasualMessage() {
        let peer = msg(text: "哈喽在吗", t: 1000)
        let result = ImportanceDetector.evaluate(
            peerMessage: peer,
            subsequentSelfMessages: [msg(text: "在", t: 1100)]
        )
        guard case .notImportant = result else {
            return XCTFail("expected notImportant, got \(result)")
        }
    }

    func testVerdictNotImportantWhenNoReply() {
        // No reply should fall through to the reply-debt pipeline,
        // not our detector's concern.
        let peer = msg(text: "要不要周五开会定方案", t: 1000)
        let result = ImportanceDetector.evaluate(
            peerMessage: peer,
            subsequentSelfMessages: []
        )
        guard case .notImportant = result else {
            return XCTFail("expected notImportant when no reply, got \(result)")
        }
    }
}
