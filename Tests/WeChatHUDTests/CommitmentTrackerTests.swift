import XCTest
@testable import WeChatHUD

final class CommitmentTrackerTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_commit_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
        URLRequestRecorder.install()
    }

    override func tearDown() {
        URLRequestRecorder.uninstall()
        store.close()
        super.tearDown()
    }

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

    func testAuditUsesProviderReturnedModel() async throws {
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: """
            {"is_commitment":true,"content":"明天发方案","commit_to":"张三","deadline_extracted":"明天","confidence":0.92}
            """,
            model: "actual-provider-model"
        )

        let tracker = CommitmentTracker(store: store, aiService: makeAIService())
        let result = await tracker.analyze(
            yourMessage: MessageInfo(
                id: "m1", chatUsername: "chat1", chatName: "项目群",
                senderUsername: "me", senderName: "我",
                text: "好的，我明天发方案",
                baseType: 1, subType: 0, createTime: Int(Date().timeIntervalSince1970)
            ),
            contextMessages: [],
            recipientName: "张三",
            recipientRole: .colleague
        )

        XCTAssertEqual(result?.content, "明天发方案")
        let audit = try XCTUnwrap(store.loadRecentAIAudit(role: .commitmentTracker).first)
        XCTAssertEqual(audit.model, "actual-provider-model")
    }

    private func makeAIService() -> AIService {
        var cfg = AIConfig()
        cfg.cloudProvider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "requested-model",
            apiKey: "sk-test"
        )
        cfg.activeMode = .cloud
        return AIService(config: cfg)
    }
}
