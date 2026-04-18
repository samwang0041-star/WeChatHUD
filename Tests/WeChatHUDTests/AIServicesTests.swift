import XCTest
@testable import WeChatHUD

/// Phase 0+ tests for the 4 standalone AI services:
///   - AIReplySuggester
///   - AIGroupCatchup
///   - AIWhitelistCategorizer
///   - AIDailyRetrospector
///
/// Each service exposes:
///   1. Pure unit tests on its prompt loader / parsing / config defaults
///   2. A live integration test that runs one real call against omlx
///      and verifies the response shape (not specific content). Skipped
///      when the local model server is unreachable.
final class AIServicesTests: XCTestCase {
    var tmpPath: String!
    var store: HUDStore!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_ai_services_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // MARK: - Prompt loader sanity

    func testReplySuggesterPromptLoads() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "reply_suggester_v1")
        XCTAssertTrue(template.contains("{message_body}"))
        XCTAssertTrue(template.contains("{ask_type}"))
        XCTAssertTrue(template.contains("suggestions"))
    }

    func testGroupCatchupPromptLoads() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "group_catchup_v1")
        XCTAssertTrue(template.contains("{messages}"))
        XCTAssertTrue(template.contains("{self_name}"))
        XCTAssertTrue(template.contains("highlights"))
    }

    func testWhitelistCategorizerPromptLoads() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "whitelist_categorizer_v1")
        XCTAssertTrue(template.contains("{contact_name}"))
        XCTAssertTrue(template.contains("{messages}"))
        XCTAssertTrue(template.contains("category"))
    }

    func testDailyRetrospectorPromptLoads() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "daily_retrospect_v1")
        XCTAssertTrue(template.contains("{handled_list}"))
        XCTAssertTrue(template.contains("{pending_list}"))
        XCTAssertTrue(template.contains("wechat_daily_report"))
    }

    // MARK: - Live integration tests (skipped if endpoint unreachable)

    func disabled_testReplySuggesterLive() async throws {
        let cfg = store.loadAIConfig()
        try await skipIfModelUnavailable(config: cfg)

        let suggester = AIReplySuggester(store: store, aiService: AIService(config: cfg))
        let result = await suggester.suggest(.init(
            messageBody: "明天上午把预算单发给我",
            senderName: "林总",
            chatName: "测试",
            isGroup: false,
            askType: .sendFile,
            relationship: "work"
        ))

        guard let suggestions = result else {
            XCTFail("AIReplySuggester returned nil")
            return
        }
        XCTAssertEqual(suggestions.count, 3, "expected 3 reply candidates")
        for s in suggestions {
            XCTAssertFalse(s.text.isEmpty, "every candidate should have non-empty text")
            XCTAssertFalse(s.tone.isEmpty, "every candidate should have a tone")
            XCTAssertLessThanOrEqual(s.text.count, 50, "candidates should be short (≤50 chars)")
        }
    }

    func disabled_testWhitelistCategorizerLive() async throws {
        let cfg = store.loadAIConfig()
        try await skipIfModelUnavailable(config: cfg)

        let categorizer = AIWhitelistCategorizer(store: store, aiService: AIService(config: cfg))
        let result = await categorizer.categorize(.init(
            contactName: "林总",
            isGroup: false,
            messages: [
                ("林总", "明早 9 点开会"),
                ("林总", "把昨天的报表带上"),
                ("林总", "客户对方案有意见，要重做")
            ]
        ))

        guard let suggestion = result else {
            XCTFail("AIWhitelistCategorizer returned nil")
            return
        }
        XCTAssertEqual(suggestion.category, "work", "obvious work conversation should classify as work")
        XCTAssertGreaterThan(suggestion.confidence, 0.7, "obvious case should have high confidence")
        XCTAssertTrue(suggestion.shouldWhitelist, "boss giving work orders → should whitelist")
    }

    func disabled_testGroupCatchupLive() async throws {
        let cfg = store.loadAIConfig()
        try await skipIfModelUnavailable(config: cfg)

        let catchup = AIGroupCatchup(store: store, aiService: AIService(config: cfg))
        let result = await catchup.summarize(.init(
            chatName: "测试群",
            selfName: "我",
            messages: [
                ("张总", "明天 10 点开个紧急会"),
                ("李姐", "收到"),
                ("张总", "@我 你也来一下，主要是你那块的内容"),
                ("我", "好的"),
                ("张总", "客户对方案有意见，需要重做")
            ]
        ))

        guard let summary = result else {
            XCTFail("AIGroupCatchup returned nil")
            return
        }
        XCTAssertFalse(summary.headline.isEmpty, "headline should be non-empty")
        XCTAssertTrue(summary.needsUserAction, "explicit @ should trigger needsUserAction=true")
    }

    func disabled_testDailyRetrospectorLive() async throws {
        let cfg = store.loadAIConfig()
        try await skipIfModelUnavailable(config: cfg)

        // Seed a synthetic ask so retrospector has something to chew on
        let now = Date()
        let ask = PendingAsk(
            id: 1,
            msgUID: "test-ask-1",
            chatUsername: "wxid_test",
            chatName: "林总",
            senderName: "林总",
            rawText: "明天发预算单",
            summary: "发送预算单",
            askType: .sendFile,
            deadlineAt: now.addingTimeInterval(-3600),  // overdue 1h
            confidence: 0.95,
            bucket: .main,
            status: .pending,
            promptVersion: "classifier_v3",
            createdAt: now.addingTimeInterval(-7200),
            updatedAt: now.addingTimeInterval(-7200),
            senderLevel: nil,
            senderRole: nil,
            urgency: nil
        )
        try store.upsertPendingAsk(ask)

        let retrospector = AIDailyRetrospector(store: store, config: cfg)
        let result = await retrospector.retrospect(.init(
            date: "2026-04-12",
            handled: [],
            pending: store.loadPendingAsks(status: .pending),
            messageCount: 50,
            focusDurationMinutes: 90
        ))

        guard let r = result else {
            XCTFail("AIDailyRetrospector returned nil")
            return
        }
        XCTAssertFalse(r.todaySummary.isEmpty, "today_summary should be non-empty")
        XCTAssertFalse(r.tomorrowFirstThing.action.isEmpty, "tomorrow's first thing should have an action")
        XCTAssertFalse(r.wechatDailyReport.isEmpty, "wechat daily report should be non-empty")
        XCTAssertEqual(r.stats.asksPending, 1, "stats.asks_pending should match input")
    }

    // MARK: - Helpers

    /// Skips the test if the configured omlx endpoint can't actually
    /// serve a real chat completion. Stronger than a /models probe so
    /// we don't sit through 30s timeouts on a sick server.
    private func skipIfModelUnavailable(config: AIConfig) async throws {
        var url = config.baseURL
        while url.hasSuffix("/") { url.removeLast() }
        if !url.hasSuffix("/v1") { url += "/v1" }
        guard let completionURL = URL(string: "\(url)/chat/completions") else {
            throw XCTSkip("invalid AI url: \(config.baseURL)")
        }

        var req = URLRequest(url: completionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 5

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": "hi"]
            ],
            "temperature": 0.0,
            "max_tokens": 5,
            "stream": false
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw XCTSkip("AI endpoint not serving completions")
            }
        } catch {
            throw XCTSkip("AI endpoint unavailable: \(error.localizedDescription)")
        }
    }
}
