import XCTest
@testable import WeChatHUD

final class GroupContextBriefingServiceTests: XCTestCase {
    var tmpPath: String!
    var store: HUDStore!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "group_context_briefing_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testContextWindowCentersOnTargetMessage() {
        let messages = [
            makeMessage(id: "m1", sender: "Alice", text: "前文 1", ts: 100),
            makeMessage(id: "m2", sender: "Bob", text: "前文 2", ts: 110),
            makeMessage(id: "m3", sender: "Carol", text: "@你 看下这个方案", ts: 120),
            makeMessage(id: "m4", sender: "Alice", text: "后文 1", ts: 130),
            makeMessage(id: "m5", sender: "Bob", text: "后文 2", ts: 140)
        ]
        let notification = makeNotification(messageID: "m3", rawText: "@你 看下这个方案", ts: 120)

        let window = GroupContextBriefingService.contextWindow(
            messages: messages.sorted { $0.createTime > $1.createTime },
            notification: notification,
            historyCount: 1,
            futureCount: 1
        )

        XCTAssertEqual(window.map(\.id), ["m2", "m3", "m4"])
    }

    func testServiceUsesCachedBriefingWithoutCallingModel() async {
        let notification = makeNotification(messageID: "m-cache", rawText: "@你 今天给个判断", ts: 200)
        let cached = GroupContextBriefing(
            situation: "群里在推进排期。",
            whyMentioned: "现在轮到你拍板。",
            currentStatus: "大家在等你的判断。",
            nextStep: "先明确给结论。",
            participants: ["Alice", "Bob"],
            confidence: 0.92,
            source: .ai,
            generatedAt: Date(timeIntervalSince1970: 100)
        )
        let raw = String(data: try! JSONEncoder().encode(cached), encoding: .utf8)!
        try! store.writeAnalysisCache(
            chatUsername: notification.chatUsername,
            analysisType: "group_context_briefing_v1",
            inputHash: notification.briefingKey,
            result: raw,
            ttlHours: 24
        )

        let client = FakeGroupContextLLMClient(response: """
        {"situation":"不该被调用","why_mentioned":"不该被调用","current_status":"不该被调用","next_step":"不该被调用","participants":[],"confidence":0.1}
        """)
        let service = GroupContextBriefingService(
            reader: FakeGroupContextMessageProvider(messages: []),
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.situation, cached.situation)
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    func testServiceFallsBackOnInvalidJSONAndWritesParseAudit() async {
        let notification = makeNotification(messageID: "m-invalid", rawText: "@你 这个今天能不能定", ts: 200)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(id: "m1", sender: "Alice", text: "这事还没定", ts: 160),
            makeMessage(id: "m2", sender: "Bob", text: "@你 这个今天能不能定", ts: 200)
        ])
        let client = FakeGroupContextLLMClient(response: "not-json")
        let service = GroupContextBriefingService(
            reader: provider,
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .fallback)
        XCTAssertNotNil(result.errorMessage)
        let recent = store.loadRecentAIAudit(
            limit: 5,
            role: .retrospector,
            promptVersionPrefix: "group_context_"
        )
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].status, .parseError)
        XCTAssertEqual(recent[0].outputText, "not-json")
    }

    func testServiceParsesAIBriefingAndCachesIt() async {
        let notification = makeNotification(messageID: "m-ai", rawText: "@你 看下预算能不能过", ts: 300)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(id: "m1", sender: "Alice", text: "预算还差你确认", ts: 250),
            makeMessage(id: "m-ai", sender: "Bob", text: "@你 看下预算能不能过", ts: 300)
        ])
        let client = FakeGroupContextLLMClient(response: """
        ```json
        {"situation":"群里在确认预算是否通过","why_mentioned":"大家在等你拍板预算","current_status":"预算卡在你的确认","next_step":"直接回预算是否通过或给明确时间","participants":["Alice","Bob"],"confidence":0.93}
        ```
        """)
        let service = GroupContextBriefingService(
            reader: provider,
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .ai)
        XCTAssertEqual(result.briefing.participants, ["Alice", "Bob"])
        XCTAssertNil(result.errorMessage)
        let cached = store.loadAnalysisCache(
            chatUsername: notification.chatUsername,
            analysisType: "group_context_briefing_v1",
            inputHash: notification.briefingKey
        )
        XCTAssertNotNil(cached)
    }

    private func makeNotification(
        messageID: String,
        rawText: String,
        ts: TimeInterval
    ) -> HUDNotification {
        HUDNotification(
            chatUsername: "room@chatroom",
            chatName: "项目群",
            senderUsername: "wxid_bob",
            senderName: "Bob",
            attentionLevel: .vip,
            messageID: messageID,
            rawText: rawText,
            snippet: String(rawText.prefix(20)),
            isAtMention: true,
            timestamp: Date(timeIntervalSince1970: ts),
            kind: .groupAt
        )
    }

    private func makeMessage(
        id: String,
        sender: String,
        text: String,
        ts: Int
    ) -> MessageInfo {
        MessageInfo(
            id: id,
            chatUsername: "room@chatroom",
            chatName: "项目群",
            senderUsername: sender.lowercased(),
            senderName: sender,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: ts
        )
    }
}

private struct FakeGroupContextMessageProvider: GroupContextMessageProvider {
    let messages: [MessageInfo]

    func getMessages(chatUsername: String, limit: Int, sinceLocalId: Int?) throws -> [MessageInfo] {
        Array(messages.prefix(limit))
    }
}

private actor FakeGroupContextLLMClient: GroupContextLLMClient {
    private(set) var callCount = 0

    let response: String
    let configured: Bool

    init(response: String, configured: Bool = true) {
        self.response = response
        self.configured = configured
    }

    func complete(system: String, user: String) async throws -> String {
        callCount += 1
        return response
    }

    func isConfigured() async -> Bool {
        configured
    }

    func currentConfig() async -> AIConfig {
        var config = AIConfig()
        config.model = "test-model"
        return config
    }
}
