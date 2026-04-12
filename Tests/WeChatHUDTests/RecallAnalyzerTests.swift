import XCTest
@testable import WeChatHUD

final class RecallAnalyzerTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_recall_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() { store.close(); super.tearDown() }

    func testPromptLoads() {
        let loader = PromptLoader()
        XCTAssertNoThrow(try loader.load(version: "recall_analyzer_v1"))
    }

    func testRecallDBRoundtrip() {
        try! store.insertRecalledMessage(
            msgUID: "r1",
            senderUsername: "wxid_boss", senderName: "王总",
            senderLevel: .vip, senderRole: .boss,
            chatUsername: "group1", chatName: "产品群",
            chatType: .group,
            originalText: "人员调整先不要发",
            sentAt: 1000, recalledAt: 1012
        )
        let msgs = store.loadRecalledMessages(since: 0, limit: 10)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].originalText, "人员调整先不要发")
        XCTAssertEqual(msgs[0].recallDelaySeconds, 12)
        XCTAssertNil(msgs[0].aiReason) // not analyzed yet
    }

    func testUpdateRecallAnalysis() {
        try! store.insertRecalledMessage(
            msgUID: "r2",
            senderUsername: "wxid_boss", senderName: "王总",
            senderLevel: .vip, senderRole: .boss,
            chatUsername: "group1", chatName: "产品群",
            chatType: .group,
            originalText: "预算砍掉",
            sentAt: 2000, recalledAt: 2008
        )
        try! store.updateRecallAnalysis(
            msgUID: "r2", reason: "said_too_much", value: "high",
            detail: "涉及预算决策", shouldNotify: true, notifyLevel: .strong
        )
        let msgs = store.loadRecalledMessages(since: 0, limit: 10)
        XCTAssertEqual(msgs[0].aiReason, "said_too_much")
        XCTAssertEqual(msgs[0].aiIntelligenceValue, "high")
        XCTAssertEqual(msgs[0].aiShouldNotify, true)
    }
}
