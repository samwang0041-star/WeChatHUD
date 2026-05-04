import XCTest
@testable import WeChatHUD

final class AIInboxSummarizerTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_inbox_summary_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
        URLRequestRecorder.install()
    }

    override func tearDown() {
        URLRequestRecorder.uninstall()
        store.close()
        super.tearDown()
    }

    func testAuditUsesProviderReturnedModel() async throws {
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: "等你发方案",
            model: "actual-provider-model"
        )

        let summarizer = AIInboxSummarizer(store: store, aiService: makeAIService())
        let summary = await summarizer.summarize(makeContext())

        XCTAssertEqual(summary, "等你发方案")
        let audit = try XCTUnwrap(store.loadRecentAIAudit(role: .summarizer).first)
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
        cfg.summaryEnabled = true
        return AIService(config: cfg)
    }

    private func makeContext() -> InboxContext {
        let now = Int(Date().timeIntervalSince1970)
        let trigger = MessageInfo(
            id: "msg-inbox",
            chatUsername: "chat1",
            chatName: "项目群",
            senderUsername: "wxid_peer",
            senderName: "张三",
            text: "方案明天能发我吗？",
            baseType: 1,
            subType: 0,
            createTime: now
        )
        return InboxContext(
            triggerMessage: trigger,
            triggerMessageText: trigger.text,
            recentMessages: [trigger],
            taggedTranscript: "张三: 方案明天能发我吗？",
            myLastReply: nil,
            myLastReplyText: nil,
            timeSinceMyLastReply: nil,
            senderRole: .colleague,
            senderAttentionLevel: .whitelist,
            senderReplyWindow: 120,
            isOverdue: false,
            overdueMinutes: 0,
            weeklyInteractionCount: 1,
            weeklyTrend: .stable,
            avgResponseTimeMinutes: 0,
            pendingCommitments: [],
            pendingAsks: [],
            isGroupChat: true,
            mentionedMe: false,
            groupRecentContext: nil,
            hasUrgentKeyword: false,
            hasAskSignal: true,
            inboundCountSinceMyLastReply: 1,
            mediaType: nil,
            mediaFilePath: nil,
            mediaContextMessages: [],
            linkTitle: nil,
            linkDescription: nil,
            linkURL: nil,
            linkBodyText: nil
        )
    }
}
