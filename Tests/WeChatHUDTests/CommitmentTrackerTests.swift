import XCTest
@testable import WeChatHUD

final class CommitmentTrackerTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_commit_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() { store.close(); super.tearDown() }

    func testPromptLoads() {
        let loader = PromptLoader()
        XCTAssertNoThrow(try loader.load(version: "commitment_v1"))
    }

    func testHasCommitmentSignal() {
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("好的我明天发你"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("收到"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("没问题，我处理"))
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("哈哈好搞笑"))
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("这个怎么做"))
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("？"))
    }

    func testCommitmentDBRoundtrip() {
        try! store.upsertCommitment(
            msgUID: "c1", chatUsername: "chat1", chatName: "张三",
            content: "明天发方案", commitTo: "张三",
            deadlineAt: Date(timeIntervalSince1970: 5000),
            confidence: 0.9, promptVersion: "commitment_v1"
        )
        let pending = store.loadCommitments(status: .pending)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].content, "明天发方案")

        try! store.updateCommitmentStatus(msgUID: "c1", status: .fulfilled)
        XCTAssertEqual(store.loadCommitments(status: .fulfilled).count, 1)
        XCTAssertEqual(store.loadCommitments(status: .pending).count, 0)
    }
}
