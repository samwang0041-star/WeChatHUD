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
            analysisType: "group_context_briefing_v1:context_window_v2",
            inputHash: notification.briefingKey,
            result: raw,
            ttlHours: 24
        )

        let client = FakeGroupContextLLMClient(response: """
        {"situation":"不该被调用","why_mentioned":"不该被调用","current_status":"不该被调用","next_step":"不该被调用","participants":[],"confidence":0.1}
        """)
        let service = GroupContextBriefingService(
            reader: FakeGroupContextMessageProvider(messages: [
                makeMessage(id: "m-cache", sender: "Bob", text: "@你 今天给个判断", ts: 200)
            ]),
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.situation, cached.situation)
        XCTAssertEqual(result.contextMessages.map(\.id), ["m-cache"])
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    func testMissingSourceDoesNotReuseCachedAIBriefing() async {
        let notification = makeNotification(messageID: "m-evicted", rawText: "@你 看下这个", ts: 210)
        let provider = MutableGroupContextMessageProvider(messages: [
            makeMessage(id: "m-evicted", sender: "Bob", text: "@你 看下这个", ts: 210)
        ])
        let client = FakeGroupContextLLMClient(response: """
        {"situation":"缓存前的真实分析","why_mentioned":"需要你确认","current_status":"等待判断","next_step":"回复","participants":["Bob"],"confidence":0.9}
        """)
        let service = GroupContextBriefingService(reader: provider, store: store, client: client)

        let first = await service.explain(notification: notification)
        XCTAssertEqual(first.briefing.source, .ai)

        provider.messages = []
        let second = await service.explain(notification: notification)

        XCTAssertEqual(second.briefing.source, .fallback)
        XCTAssertTrue(second.errorMessage?.contains("找不到") == true)
        XCTAssertFalse(second.briefing.situation.contains("缓存前的真实分析"))
        XCTAssertTrue(second.contextMessages.isEmpty)
        let calls = await client.callCount
        XCTAssertEqual(calls, 1, "missing source must return before consulting the cached AI result or model")
    }

    func testServiceFallsBackOnInvalidJSONAndWritesParseAudit() async {
        let notification = makeNotification(messageID: "m-invalid", rawText: "@你 这个今天能不能定", ts: 200)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(id: "m1", sender: "Alice", text: "这事还没定", ts: 160),
            makeMessage(id: "m-invalid", sender: "Bob", text: "@你 这个今天能不能定", ts: 200)
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

    func testBareMentionFallbackUsesFYICopy() async {
        let notification = makeNotification(messageID: "m-fyi", rawText: "@你 前面大家在聊示例主题", ts: 200)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(id: "m1", sender: "Alice", text: "大家在聊示例主题", ts: 160),
            makeMessage(id: "m-fyi", sender: "Bob", text: "@你 前面大家在聊示例主题", ts: 200)
        ])
        let client = FakeGroupContextLLMClient(response: "", configured: false)
        let service = GroupContextBriefingService(
            reader: provider,
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .fallback)
        XCTAssertTrue(result.briefing.whyMentioned.contains("同步"))
        XCTAssertTrue(result.briefing.currentStatus.contains("没有明确"))
        XCTAssertFalse(result.briefing.whyMentioned.contains("需要你"))
        XCTAssertFalse(result.briefing.currentStatus.contains("卡点"))
        XCTAssertFalse(result.briefing.nextStep.contains("说明你当前进度"))
    }

    func testNotificationSemanticKeepsBareMentionFYIAndDeepActionOptIn() {
        let bare = makeNotification(messageID: "m-bare", rawText: "@你 前面大家在聊示例主题", ts: 200)
        let ask = makeNotification(messageID: "m-ask", rawText: "@你 看下预算能不能过", ts: 210)
        let privateVIP = HUDNotification(
            chatUsername: "wxid_vip",
            chatName: "老板",
            senderUsername: "wxid_vip",
            senderName: "老板",
            attentionLevel: .vip,
            messageID: "m-vip",
            rawText: "更新一下进展",
            snippet: "更新一下进展",
            isAtMention: false,
            timestamp: Date(timeIntervalSince1970: 220),
            kind: .privateChat
        )

        XCTAssertEqual(bare.presentationSemanticState, .groupMentionFYI)
        XCTAssertFalse(bare.supportsDeepActionContext)
        XCTAssertEqual(ask.presentationSemanticState, .groupMentionFYI)
        XCTAssertTrue(ask.supportsDeepActionContext)
        XCTAssertEqual(privateVIP.presentationSemanticState, .privateVIPRisk)
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
            analysisType: "group_context_briefing_v1:context_window_v2",
            inputHash: notification.briefingKey
        )
        XCTAssertNotNil(cached)
    }

    func testServiceParsesTrailingProseAndRequestsJSONMode() async {
        let notification = makeNotification(messageID: "m-trailing", rawText: "@你 看下预算能不能过", ts: 300)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(id: "m1", sender: "Alice", text: "预算还差你确认", ts: 250),
            makeMessage(id: "m-trailing", sender: "Bob", text: "@你 看下预算能不能过", ts: 300)
        ])
        let client = FakeGroupContextLLMClient(response: """
        {"situation":"群里在确认预算是否通过","why_mentioned":"大家在等你拍板预算","current_status":"预算卡在你的确认","next_step":"直接回预算是否通过或给明确时间","participants":["Alice","Bob"],"confidence":0.93}
        补充说明：以上为模型解释。
        """)
        let service = GroupContextBriefingService(
            reader: provider,
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .ai)
        XCTAssertNil(result.errorMessage)
        let options = await client.optionsSeen
        XCTAssertEqual(options.count, 1)
        XCTAssertTrue(options[0].responseFormatJSON)
        XCTAssertEqual(options[0].thinkingEnabled, nil)
    }

    func testServiceFindsHistoricalTargetBeyondNewestPage() async throws {
        let messages = (0..<60).map { index in
            makeMessage(
                id: "m" + String(index),
                sender: index.isMultiple(of: 2) ? "Alice" : "Bob",
                text: "context-" + String(index),
                ts: 100 + index / 2,
                localId: index + 1
            )
        }
        // The notification timestamp represents a session-level latest time,
        // while the source message itself is much older than the newest page.
        let notification = makeNotification(messageID: "m5", rawText: "@你 看下这个", ts: 160)
        let provider = FakeGroupContextMessageProvider(messages: messages)
        let client = FakeGroupContextLLMClient(response: """
        {"situation":"已按顺序读取","why_mentioned":"需要你确认","current_status":"等待判断","next_step":"回复","participants":["Alice","Bob","Carol"],"confidence":0.9}
        """)
        let service = GroupContextBriefingService(
            reader: provider,
            store: store,
            client: client
        )

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .ai)
        XCTAssertEqual(result.contextMessages.map(\.id), (0...8).map { "m\($0)" })
        let prompt = await client.lastUserPrompt
        XCTAssertTrue(prompt.contains("context-5"), "historical source should be loaded by ID")
        XCTAssertFalse(prompt.contains("context-40"), "window should stay centered on the old source")
        let sameSecondFirst = try XCTUnwrap(prompt.range(of: "context-4")?.lowerBound)
        let sameSecondSecond = try XCTUnwrap(prompt.range(of: "context-5")?.lowerBound)
        XCTAssertLessThan(sameSecondFirst, sameSecondSecond)
    }

    func testSourceTimestampStillIncludesThreeFollowingMessages() async {
        let messages = (0..<12).map { index in
            makeMessage(id: "m\(index)", sender: "Alice", text: "context-\(index)", ts: 100 + index, localId: index + 1)
        }
        let service = GroupContextBriefingService(
            reader: FakeGroupContextMessageProvider(messages: messages),
            store: store,
            client: FakeGroupContextLLMClient(response: "", configured: false)
        )
        let result = await service.explain(notification: makeNotification(messageID: "m5", rawText: "@你 看下这个", ts: 105))
        XCTAssertEqual(result.contextMessages.map(\.id), (0...8).map { "m\($0)" })
    }

    func testMissingSourceFallsBackWithoutUsingNewestMessageAsContext() async {
        let notification = makeNotification(messageID: "missing-source", rawText: "@你 原始提醒", ts: 200)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(id: "latest", sender: "Alice", text: "今天最新的无关消息", ts: 200)
        ])
        let client = FakeGroupContextLLMClient(response: "", configured: false)
        let service = GroupContextBriefingService(reader: provider, store: store, client: client)

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .fallback)
        XCTAssertTrue(result.errorMessage?.contains("找不到") == true)
        XCTAssertTrue(result.briefing.situation.contains("只能确认收到"))
        XCTAssertTrue(result.briefing.currentStatus.contains("未知"))
        XCTAssertTrue(result.briefing.nextStep.contains("暂不直接承诺"))
        XCTAssertFalse(result.briefing.situation.contains("群里最近"))
        XCTAssertFalse(result.briefing.situation.contains("今天最新的无关消息"))
    }

    func testSourceLookupNeverUsesMessageFromAnotherChat() async {
        let notification = makeNotification(messageID: "same-id", rawText: "@你 当前提醒", ts: 200)
        let provider = FakeGroupContextMessageProvider(messages: [
            makeMessage(
                id: "same-id", sender: "Other", text: "其他群的私密上下文", ts: 190,
                chatUsername: "other@chatroom"
            )
        ])
        let client = FakeGroupContextLLMClient(response: "", configured: false)
        let service = GroupContextBriefingService(reader: provider, store: store, client: client)

        let result = await service.explain(notification: notification)

        XCTAssertEqual(result.briefing.source, .fallback)
        XCTAssertTrue(result.errorMessage?.contains("找不到") == true)
        XCTAssertFalse(result.briefing.situation.contains("其他群的私密上下文"))
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
        ts: Int,
        localId: Int = 0,
        chatUsername: String = "room@chatroom"
    ) -> MessageInfo {
        MessageInfo(
            id: id,
            localId: localId,
            chatUsername: chatUsername,
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

private final class MutableGroupContextMessageProvider: GroupContextMessageProvider, @unchecked Sendable {
    var messages: [MessageInfo]

    init(messages: [MessageInfo]) {
        self.messages = messages
    }

    func getMessages(
        chatUsername: String,
        limit: Int,
        sinceLocalId: Int?,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)?,
        oldestFirst: Bool,
        startTime: Int?,
        endTime: Int?,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    ) throws -> [MessageInfo] {
        let filtered = messages.filter { message in
            guard message.chatUsername == chatUsername else { return false }
            if let sinceLocalId, message.localId <= sinceLocalId { return false }
            if let startTime, message.createTime < startTime { return false }
            if let endTime, message.createTime >= endTime { return false }
            if let cursor = afterCursor,
               !(message.createTime > cursor.lastCreateTime
                 || (message.createTime == cursor.lastCreateTime && message.localId > cursor.lastLocalId)) {
                return false
            }
            if let cursor = beforeCursor,
               !(message.createTime < cursor.lastCreateTime
                 || (message.createTime == cursor.lastCreateTime && message.localId <= cursor.lastLocalId)) {
                return false
            }
            return true
        }
        let ordered = filtered.sorted {
            if $0.createTime != $1.createTime {
                return oldestFirst ? $0.createTime < $1.createTime : $0.createTime > $1.createTime
            }
            return oldestFirst ? $0.localId < $1.localId : $0.localId > $1.localId
        }
        return Array(ordered.prefix(limit))
    }
}

private typealias FakeGroupContextMessageProvider = MutableGroupContextMessageProvider

private actor FakeGroupContextLLMClient: GroupContextLLMClient {
    private(set) var callCount = 0
    private(set) var optionsSeen: [CompleteOptions] = []
    private(set) var lastUserPrompt = ""

    let response: String
    let configured: Bool

    init(response: String, configured: Bool = true) {
        self.response = response
        self.configured = configured
    }

    func complete(system: String, user: String) async throws -> String {
        callCount += 1
        lastUserPrompt = user
        return response
    }

    func complete(system: String, user: String, options: CompleteOptions) async throws -> String {
        callCount += 1
        lastUserPrompt = user
        optionsSeen.append(options)
        return response
    }

    func completeWithMetadata(system: String, user: String, options: CompleteOptions) async throws -> AICompletionResult {
        callCount += 1
        lastUserPrompt = user
        optionsSeen.append(options)
        return AICompletionResult(text: response, providerID: "test", model: "test-model")
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
