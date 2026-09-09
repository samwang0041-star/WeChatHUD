import XCTest
@testable import WeChatHUD

final class VIPAggregatorTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_vipagg_\(UUID().uuidString).sqlite3"
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
        XCTAssertNoThrow(try loader.load(version: "vip_aggregator_v1"))
    }

    func testTraceCapture() {
        for i in 0..<5 {
            try! store.insertVIPTrace(
                vipUsername: "boss1", vipName: "王总",
                chatUsername: "group\(i % 2)", chatName: "群\(i % 2)",
                msgUID: "msg\(i)", rawText: "text\(i)", msgTime: 1000 + i * 60
            )
        }
        let unbatched = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        XCTAssertEqual(unbatched.count, 5)
    }

    func testBatchMarking() {
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g1", chatName: "群1",
            msgUID: "m1", rawText: "t1", msgTime: 1000
        )
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g2", chatName: "群2",
            msgUID: "m2", rawText: "t2", msgTime: 1060
        )
        let traces = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        try! store.markVIPTracesBatched(ids: traces.map(\.id), batchID: "batch_001")
        XCTAssertEqual(store.loadUnbatchedVIPTraces(vipUsername: "boss1").count, 0)
    }

    func testAggregateReturnsNilWithoutTraces() {
        let agg = VIPAggregator(store: store, aiService: AIService())
        let semaphore = DispatchSemaphore(value: 0)
        var result: VIPAggregator.AggregateResult?
        Task {
            result = await agg.aggregate(
                vipUsername: "nobody", vipName: "无", vipRole: .boss,
                userNameVariants: [], recentMoodHistory: "",
                lastInteraction: "", commitmentCount: 0
            )
            semaphore.signal()
        }
        semaphore.wait()
        XCTAssertNil(result) // no traces = nil
    }

    func testAuditUsesProviderReturnedModel() async throws {
        try store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g1", chatName: "产品群",
            msgUID: "m-ai", rawText: "预算这周要定", msgTime: 2_000
        )
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(
            content: """
            {"summary":"王总在推进预算","involves_user":true,"involve_detail":"需要你跟进","mood":"focused","mood_evidence":"催预算","mood_trend_analysis":"稳定","urgency":"medium","urgency_reason":"本周要定","recommended_action":"跟进预算","action_timing":"今天","key_topics":["预算"]}
            """,
            model: "actual-provider-model"
        )

        let agg = VIPAggregator(store: store, aiService: makeAIService())
        let result = await agg.aggregate(
            vipUsername: "boss1",
            vipName: "王总",
            vipRole: .boss,
            userNameVariants: ["我"],
            recentMoodHistory: "",
            lastInteraction: "",
            commitmentCount: 0
        )

        XCTAssertEqual(result?.summary, "王总在推进预算")
        let audit = try XCTUnwrap(store.loadRecentAIAudit(role: .vipAggregator).first)
        XCTAssertEqual(audit.model, "actual-provider-model")
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

    func testDisabledMoodDoesNotExposeModelMoodButKeepsUsefulFacts() async throws {
        var config = store.loadAIConfig()
        config.moodDetectionEnabled = false
        try store.setSettingJSON("ai", value: config)
        try store.insertVIPTrace(vipUsername: "boss1", vipName: "测试联系人", chatUsername: "g1", chatName: "测试群",
                                 msgUID: "m-disabled", rawText: "周五确认预算", msgTime: 2000)
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: """
        {"summary":"周五确认预算","involves_user":true,"involve_detail":"待确认","mood":"angry","mood_evidence":"模型推测","mood_trend_analysis":"变差","urgency":"routine","urgency_reason":"周五","recommended_action":"确认预算","action_timing":"this_week","key_topics":["预算"]}
        """)
        let aggregator = VIPAggregator(store: store, aiService: makeAIService())
        let result = await aggregator.aggregate(vipUsername: "boss1", vipName: "测试联系人", vipRole: .boss,
                                               userNameVariants: [], recentMoodHistory: "历史", lastInteraction: "", commitmentCount: 0)
        XCTAssertEqual(result?.summary, "周五确认预算")
        XCTAssertEqual(result?.mood, "")
        XCTAssertEqual(result?.moodEvidence, "")
        XCTAssertEqual(result?.moodTrendAnalysis, "")
        XCTAssertEqual(result?.recommendedAction, "确认预算")
    }

    func testNoHistoryCannotProduceMoodTrend() {
        let result = VIPAggregator.AggregateResult(summary: "摘要", involvesUser: false, involveDetail: nil,
            mood: "neutral", moodEvidence: "原文", moodTrendAnalysis: "伪造趋势", urgency: "routine",
            urgencyReason: "", recommendedAction: "", actionTiming: "no_action", keyTopics: [])
        XCTAssertEqual(result.applyingMoodPreference(enabled: true, hasHistory: false).moodTrendAnalysis, "")
        XCTAssertEqual(result.applyingMoodPreference(enabled: true, hasHistory: false).mood, "neutral")
    }
}
