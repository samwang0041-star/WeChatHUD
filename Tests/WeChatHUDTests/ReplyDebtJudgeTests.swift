import XCTest
@testable import WeChatHUD

final class ReplyDebtJudgeTests: XCTestCase {
    var tmpPath: String!
    var store: HUDStore!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "reply_debt_judge_test_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testJudgeBuildsCompactPayloadForTopCandidatesOnly() async {
        let client = FakeReplyDebtLLMClient(response: #"{"judgments":[]}"#)
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [
            makeItem(chatUsername: "alice", score: 9, priority: .p0, timestamp: 400),
            makeItem(chatUsername: "bob", score: 6, priority: .p1, timestamp: 380),
            makeItem(chatUsername: "charlie", score: 3, priority: .p2, timestamp: 360)
        ]

        _ = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(
                enabled: true,
                shadowMode: false,
                maxCandidates: 2,
                minRuleScore: 4,
                requestTimeoutSeconds: 1
            ),
            client: client
        )

        let payload = await client.lastUser
        XCTAssertTrue(payload.contains("\"chat_username\":\"alice\""))
        XCTAssertTrue(payload.contains("\"chat_username\":\"bob\""))
        XCTAssertFalse(payload.contains("\"chat_username\":\"charlie\""))
    }

    func testJudgeIgnoresUnknownChatUsernamesInResponse() async {
        let client = FakeReplyDebtLLMClient(
            response: """
            {"judgments":[
                {"chat_username":"unknown","needs_reply":false,"priority_override":"keep","confidence":"high","ai_reason":"忽略"}
            ]}
            """
        )
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [makeItem(chatUsername: "alice", score: 7, priority: .p1, timestamp: 400)]

        let result = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: false, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client
        )

        XCTAssertEqual(result.map(\.chatUsername), ["alice"])
        XCTAssertEqual(result.first?.priority, .p1)
    }

    func testJudgeFallsBackToDeterministicWhenJSONIsInvalid() async {
        let client = FakeReplyDebtLLMClient(response: "not-json")
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [
            makeItem(chatUsername: "alice", score: 8, priority: .p0, timestamp: 400),
            makeItem(chatUsername: "bob", score: 6, priority: .p1, timestamp: 380)
        ]

        let result = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: false, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client
        )

        XCTAssertEqual(result.map(\.chatUsername), ["alice", "bob"])
        XCTAssertEqual(result.map(\.priority), [.p0, .p1])
    }

    func testJudgeInShadowModeDoesNotMutateOrdering() async {
        let client = FakeReplyDebtLLMClient(
            response: """
            {"judgments":[
                {"chat_username":"alice","needs_reply":false,"priority_override":"keep","confidence":"high","ai_reason":"可忽略"},
                {"chat_username":"bob","needs_reply":true,"priority_override":"p0","confidence":"high","ai_reason":"需要升级"}
            ]}
            """
        )
        let logs = LogCollector()
        let judge = ReplyDebtJudge(
            now: Date(timeIntervalSince1970: 500),
            logger: { message in logs.append(message) }
        )
        let items = [
            makeItem(chatUsername: "alice", score: 8, priority: .p0, timestamp: 400),
            makeItem(chatUsername: "bob", score: 6, priority: .p1, timestamp: 380)
        ]

        let result = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: true, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client
        )

        XCTAssertEqual(result.map(\.chatUsername), ["alice", "bob"])
        XCTAssertEqual(result.map(\.priority), [.p0, .p1])
        let entries = logs.messages
        XCTAssertTrue(entries.contains(where: { $0.contains("would suppress Alice") }))
        XCTAssertTrue(entries.contains(where: { $0.contains("would change Bob") }))
    }

    func testJudgeCanSuppressOnlyHighConfidenceFalsePositive() async {
        let client = FakeReplyDebtLLMClient(
            response: """
            {"judgments":[
                {"chat_username":"alice","needs_reply":false,"priority_override":"keep","confidence":"high","ai_reason":"只是同步"},
                {"chat_username":"bob","needs_reply":false,"priority_override":"keep","confidence":"medium","ai_reason":"不够确定"},
                {"chat_username":"carol","needs_reply":true,"priority_override":"p0","confidence":"high","ai_reason":"需要立刻回"}
            ]}
            """
        )
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [
            makeItem(chatUsername: "alice", chatName: "Alice", score: 7, priority: .p1, timestamp: 400),
            makeItem(chatUsername: "bob", chatName: "Bob", score: 6, priority: .p1, timestamp: 390),
            makeItem(chatUsername: "carol", chatName: "Carol", score: 4, priority: .p2, timestamp: 380)
        ]

        let result = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: false, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client
        )

        XCTAssertEqual(result.map(\.chatUsername), ["bob", "carol"])
        XCTAssertEqual(result.map(\.priority), [.p1, .p1])
    }

    func testJudgeClampsPriorityOverrideToSingleBand() async {
        let client = FakeReplyDebtLLMClient(
            response: """
            {"judgments":[
                {"chat_username":"alice","needs_reply":true,"priority_override":"p0","confidence":"high","ai_reason":"升级两档"}
            ]}
            """
        )
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [makeItem(chatUsername: "alice", score: 4, priority: .p2, timestamp: 400)]

        let result = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: false, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client
        )

        XCTAssertEqual(result.first?.priority, .p1)
    }

    func testJudgeWritesShadowAuditEntry() async {
        let client = FakeReplyDebtLLMClient(
            response: """
            {"judgments":[
                {"chat_username":"alice","needs_reply":false,"priority_override":"keep","confidence":"high","ai_reason":"可忽略"}
            ]}
            """
        )
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [makeItem(chatUsername: "alice", score: 8, priority: .p0, timestamp: 400)]

        _ = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: true, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client,
            model: "test-model",
            store: store
        )

        let recent = store.loadRecentAIAudit(limit: 10, role: .ranker, promptVersionPrefix: "reply_debt_")
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].model, "test-model")
        XCTAssertEqual(recent[0].status, .ok)
        XCTAssertTrue(recent[0].errorMessage?.contains("shadow suppress Alice") == true)
    }

    func testJudgeWritesParseErrorAuditEntry() async {
        let client = FakeReplyDebtLLMClient(response: "not-json")
        let judge = ReplyDebtJudge(now: Date(timeIntervalSince1970: 500))
        let items = [makeItem(chatUsername: "alice", score: 8, priority: .p0, timestamp: 400)]

        _ = await judge.apply(
            to: items,
            config: ReplyDebtAIConfig(enabled: true, shadowMode: false, maxCandidates: 4, minRuleScore: 4, requestTimeoutSeconds: 1),
            client: client,
            model: "test-model",
            store: store
        )

        let recent = store.loadRecentAIAudit(limit: 10, role: .ranker, promptVersionPrefix: "reply_debt_")
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].status, .parseError)
        XCTAssertEqual(recent[0].outputText, "not-json")
        XCTAssertNotNil(recent[0].errorMessage)
    }

    private func makeItem(
        chatUsername: String,
        chatName: String? = nil,
        score: Int,
        priority: ReplyDebtPriority,
        timestamp: TimeInterval,
        isGroup: Bool = false
    ) -> ReplyDebtItem {
        ReplyDebtItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName ?? chatUsername.capitalized,
            senderName: "Bob",
            preview: "你看下这个安排？",
            latestOutboundPreview: "我晚上看下",
            timestamp: Date(timeIntervalSince1970: timestamp),
            priority: priority,
            score: score,
            unreadCount: 0,
            isGroup: isGroup,
            isWhitelisted: false,
            isVIP: false,
            isAtMention: false,
            inboundCountSinceLastOutbound: 2,
            reasons: [ReplyDebtReason(code: .privateChat), ReplyDebtReason(code: .repeatedInbound)],
            suggestedReplyMinutes: nil
        )
    }
}

private actor FakeReplyDebtLLMClient: ReplyDebtLLMClient {
    private(set) var lastSystem: String = ""
    private(set) var lastUser: String = ""

    let response: String

    init(response: String) {
        self.response = response
    }

    func complete(system: String, user: String) async throws -> String {
        lastSystem = system
        lastUser = user
        return response
    }
}

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }
}
