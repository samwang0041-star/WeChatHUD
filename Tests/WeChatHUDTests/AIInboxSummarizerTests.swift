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

    func testGenericSummaryFallsBackToReadableMessageText() async throws {
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: "发来一条消息要你看",
            model: "actual-provider-model"
        )

        let summarizer = AIInboxSummarizer(store: store, aiService: makeAIService())
        let summary = await summarizer.summarize(makeContext(text: "带老婆小孩在武汉家里"))

        XCTAssertEqual(summary, "带老婆小孩在武汉家里")
        let audit = try XCTUnwrap(store.loadRecentAIAudit(role: .summarizer).first)
        XCTAssertEqual(audit.outputText, AIAuditPrivacy.persistableText("带老婆小孩在武汉家里"))
    }

    func testUnreadableMessageDoesNotCallModelOrEchoParserFailure() async throws {
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: "大姑多次发送空白消息，内容无法显示",
            model: "actual-provider-model"
        )

        let summarizer = AIInboxSummarizer(store: store, aiService: makeAIService())
        let summary = await summarizer.summarize(makeContext(text: "内容无法显示"))

        XCTAssertEqual(summary, CompanionInteractionCopy.analysisNoMessages)
        XCTAssertTrue(URLRequestRecorder.capturedRequests.isEmpty)
        let audit = try XCTUnwrap(store.loadRecentAIAudit(role: .summarizer).first)
       XCTAssertEqual(audit.outputText, AIAuditPrivacy.persistableText(CompanionInteractionCopy.analysisNoMessages))
   }

    func testUnreadableSenderRoleDoesNotBecomeAcquaintanceInPrompt() async throws {
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: "等你发方案",
            model: "actual-provider-model"
        )
        let summarizer = AIInboxSummarizer(store: store, aiService: makeAIService())
        _ = await summarizer.summarize(makeContext(senderRole: nil))
        let req = try XCTUnwrap(URLRequestRecorder.capturedRequests.first)
        let body = requestBody(req)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("unknown"), text)
        XCTAssertFalse(text.contains("acquaintance"), "unreadable role must not be written as 熟人")
    }

   private func makeAIService() -> AIService {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "requested-model",
            apiKey: "sk-test"
        )
        cfg.summaryEnabled = true
        return AIService(config: cfg)
    }

    private func makeContext(text: String = "方案明天能发我吗？", senderRole: ContactRole? = .colleague) -> InboxContext {
       let now = Int(Date().timeIntervalSince1970)
        let trigger = MessageInfo(
            id: "msg-inbox",
            chatUsername: "chat1",
            chatName: "项目群",
            senderUsername: "wxid_peer",
            senderName: "张三",
            text: text,
            baseType: 1,
            subType: 0,
            createTime: now
        )
        return InboxContext(
            triggerMessage: trigger,
            triggerMessageText: trigger.text,
            recentMessages: [trigger],
            taggedTranscript: "张三: \(text)",
            myLastReply: nil,
            myLastReplyText: nil,
           timeSinceMyLastReply: nil,
            senderRole: senderRole,
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
            mediaAnalysisText: nil,
            mediaContextMessages: [],
            linkTitle: nil,
            linkDescription: nil,
           linkURL: nil,
           linkBodyText: nil
       )
   }

    private func requestBody(_ req: URLRequest) -> Data {
        if let data = req.httpBody { return data }
        if let stream = req.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = Data()
            let chunk = 4096
            var tmp = [UInt8](repeating: 0, count: chunk)
            while stream.hasBytesAvailable {
                let n = stream.read(&tmp, maxLength: chunk)
                if n <= 0 { break }
                buf.append(tmp, count: n)
            }
            return buf
        }
        return Data()
    }
}
