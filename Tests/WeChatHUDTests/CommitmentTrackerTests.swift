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
        XCTAssertFalse(CommitmentTracker.hasCommitmentSignal("问一下六七千块钱的报价"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("我去问一下老板再回你"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("无论如何我明天发给你"))
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

    func testAnalyzeParsesProductizedMemoryFields() async throws {
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: """
            {
              "is_commitment": true,
              "content": "明天把深圳演唱会身份证信息发给朋友",
              "commit_to": "朋友",
              "deadline_extracted": "tomorrow",
              "deadline_label": "明天前",
              "commitment_kind": "deliverable",
              "source_text": "好，我明天把身份证信息发你",
              "context_summary": "朋友问是否一起去演唱会并需要身份证买票",
              "capture_reason": "用户明确答应明天发送购票信息",
              "next_step": "把身份证信息发给朋友确认购票",
              "confidence": 0.94
            }
            """,
            model: "actual-provider-model"
        )

        let tracker = CommitmentTracker(store: store, aiService: makeAIService())
        let result = await tracker.analyze(
            yourMessage: MessageInfo(
                id: "m2", chatUsername: "chat1", chatName: "朋友",
                senderUsername: "me", senderName: "我",
                text: "好，我明天把身份证信息发你",
                baseType: 1, subType: 0, createTime: Int(Date().timeIntervalSince1970)
            ),
            contextMessages: [],
            recipientName: "朋友",
            recipientRole: .friend
        )

        XCTAssertEqual(result?.content, "明天把深圳演唱会身份证信息发给朋友")
        XCTAssertEqual(result?.sourceText, "好，我明天把身份证信息发你")
        XCTAssertEqual(result?.contextText, "朋友问是否一起去演唱会并需要身份证买票")
        XCTAssertEqual(result?.nextStep, "把身份证信息发给朋友确认购票")
        XCTAssertEqual(result?.deadlineLabel, "明天前")
        XCTAssertEqual(result?.commitmentKind, "deliverable")
    }

    private func makeAIService() -> AIService {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "requested-model",
            apiKey: "sk-test"
        )
        return AIService(config: cfg)
    }

    func testOutgoingInquiriesAreNotCommitments() async throws {
        let inquiries = [
            "问一下",
            "问一下六七千块钱的报价",
            "问一下六七千块钱的报价/价格情况",
            "问下这个功能怎么用？",
            "请问今天下午几点开会",
            "想问下周五放假吗",
            "这个价格能优惠吗？",
            "什么时候发货呢"
        ]

        let tracker = CommitmentTracker(store: store, aiService: makeAIService())

        for text in inquiries {
            XCTAssertTrue(CommitmentTracker.isLikelyOutgoingInquiry(text), "Should detect inquiry: \(text)")
            XCTAssertFalse(CommitmentTracker.hasCommitmentSignal(text), "Should not have commitment signal: \(text)")

            let result = await tracker.analyze(
                yourMessage: MessageInfo(
                    id: "test_\(UUID().uuidString)", chatUsername: "chat1", chatName: "谢潘",
                    senderUsername: "me", senderName: "我",
                    text: text,
                    baseType: 1, subType: 0, createTime: Int(Date().timeIntervalSince1970)
                ),
                contextMessages: [],
                recipientName: "谢潘",
                recipientRole: ContactRole.colleague
            )

            XCTAssertEqual(result?.isCommitment, false, "Inquiry should not be a commitment: \(text)")
        }
        XCTAssertTrue(URLRequestRecorder.capturedRequests.isEmpty, "inquiries must not call the model")
    }

    func testFollowupAskThenReplyIsNotAnInquiry() {
        XCTAssertFalse(CommitmentTracker.isLikelyOutgoingInquiry("我去问一下老板再回你"))
        XCTAssertFalse(CommitmentTracker.isLikelyOutgoingInquiry("无论如何我明天发给你"))
        XCTAssertTrue(CommitmentTracker.hasCommitmentSignal("我去问一下老板再回你"))
    }

    @MainActor
    func testRepairCancelsPersistedInquiryCommitmentsAndReclassifiesTodos() throws {
        try store.upsertCommitment(
            msgUID: "inq1", chatUsername: "chat1", chatName: "谢潘",
            content: "去问一下六七千块钱的报价/价格情况，之后回复谢潘", commitTo: "谢潘",
            deadlineAt: nil, confidence: 0.9, promptVersion: "commitment_v1",
            sourceText: "问一下六七千块钱的报价/价格情况"
        )
        try store.upsertCommitment(
            msgUID: "real1", chatUsername: "chat1", chatName: "谢潘",
            content: "我去问一下老板再回你", commitTo: "谢潘",
            deadlineAt: nil, confidence: 0.9, promptVersion: "commitment_v1",
            sourceText: "我去问一下老板再回你"
        )
        _ = try store.insertDiscussionItem(
            chatUsername: "chat1", chatName: "谢潘", kind: .todo, owner: .mine,
            content: "去问一下六七千块钱的报价，之后回复谢潘", detail: nil,
            anchorMsgUID: "inq1", sourceTimestamp: 1000, dueAt: nil,
            confidence: 0.9, promptVersion: "discussion_v3"
        )

        let repaired = ChatMonitor.repairInvertedInquiryRecords(store: store)
        XCTAssertEqual(repaired.commitments, 1)
        XCTAssertEqual(repaired.discussions, 1)

        XCTAssertEqual(store.loadCommitments(status: .cancelled).first?.msgUID, "inq1")
        XCTAssertEqual(store.loadCommitments(status: .pending).map(\.msgUID), ["real1"])
        let item = store.loadDiscussionItems(chatUsername: "chat1").first
        XCTAssertEqual(item?.kind, .question)
        XCTAssertEqual(item?.owner, .theirs)
        XCTAssertEqual(item?.content, "问一下六七千块钱的报价")
    }

    @MainActor
    func testRepairDoesNotCancelTaskSummariesThatOnlyContainWhether() throws {
        try store.upsertCommitment(
            msgUID: "real2", chatUsername: "chat1", chatName: "林总",
            content: "确认是否周五前交货", commitTo: "林总",
            deadlineAt: nil, confidence: 0.9, promptVersion: "commitment_v1",
            sourceText: ""
        )
        _ = try store.insertDiscussionItem(
            chatUsername: "chat1", chatName: "林总", kind: .todo, owner: .mine,
            content: "确认是否可以周五交货", detail: nil,
            anchorMsgUID: "real2", sourceTimestamp: 1000, dueAt: nil,
            confidence: 0.9, promptVersion: "discussion_v3"
        )
        let repaired = ChatMonitor.repairInvertedInquiryRecords(store: store)
        XCTAssertEqual(repaired.commitments, 0)
        XCTAssertEqual(repaired.discussions, 0)
        XCTAssertEqual(store.loadCommitments(status: .pending).map(\.msgUID), ["real2"])
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "chat1").first?.owner, .mine)
    }
}
