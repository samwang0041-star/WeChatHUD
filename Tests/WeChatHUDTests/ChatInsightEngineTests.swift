import XCTest
@testable import WeChatHUD

final class ChatInsightEngineTests: XCTestCase {

    private let selfUsername = "wxid_me"

    private func msg(_ sender: String, _ text: String, _ time: Int) -> MessageInfo {
        MessageInfo(
            id: UUID().uuidString,
            chatUsername: "test_chat@chatroom",
            chatName: "Test",
            senderUsername: sender,
            senderName: sender,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: time
        )
    }

    // MARK: - Message counts

    func testBasicStats_countsMessages() {
        let messages = [
            msg("wxid_me", "hello", 1000),
            msg("wxid_a", "hi", 1001),
            msg("wxid_b", "hey", 1002),
            msg("wxid_me", "sup", 1003),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test_chat@chatroom", chatName: "Test", isGroup: true, category: .work
        )
        XCTAssertEqual(stats.messageCount, 4)
        XCTAssertEqual(stats.myMessageCount, 2)
        XCTAssertEqual(stats.participantCount, 3)
    }

    // MARK: - Messages by hour

    func testMessagesByHour_correctSlots() {
        let base = 1713000000
        let hour10 = base - (base % 86400) + 10 * 3600
        let hour14 = base - (base % 86400) + 14 * 3600
        let messages = [
            msg("wxid_a", "morning", hour10),
            msg("wxid_a", "morning2", hour10 + 60),
            msg("wxid_b", "afternoon", hour14),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .work
        )
        XCTAssertEqual(stats.messagesByHour.reduce(0, +), 3)
    }

    // MARK: - Top senders

    func testTopSenders_sortedByCount() {
        let messages = [
            msg("wxid_a", "1", 1000), msg("wxid_a", "2", 1001), msg("wxid_a", "3", 1002),
            msg("wxid_b", "4", 1003), msg("wxid_b", "5", 1004),
            msg("wxid_c", "6", 1005),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: true, category: .work
        )
        XCTAssertEqual(stats.topSenders[0].name, "wxid_a")
        XCTAssertEqual(stats.topSenders[0].count, 3)
        XCTAssertEqual(stats.topSenders[1].name, "wxid_b")
        XCTAssertEqual(stats.topSenders[1].count, 2)
    }

    // MARK: - Symmetry ratio

    func testSymmetry_balanced() {
        let messages = [
            msg("wxid_me", "hi", 1000),
            msg("wxid_a", "hey", 1001),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "wxid_a", chatName: "Test", isGroup: false, category: .life
        )
        XCTAssertEqual(stats.symmetryRatio, 1.0, accuracy: 0.01)
    }

    func testSymmetry_imbalanced() {
        let messages = [
            msg("wxid_me", "1", 1000), msg("wxid_me", "2", 1001), msg("wxid_me", "3", 1002),
            msg("wxid_a", "4", 1003),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "wxid_a", chatName: "Test", isGroup: false, category: .life
        )
        XCTAssertEqual(stats.symmetryRatio, 0.333, accuracy: 0.01)
    }

    // MARK: - Empty input

    func testEmptyMessages_returnsZeros() {
        let stats = ChatInsightEngine.computeStats(
            messages: [], selfUsername: selfUsername,
            chatUsername: "wxid_a", chatName: "Test", isGroup: false, category: .other
        )
        XCTAssertEqual(stats.messageCount, 0)
        XCTAssertEqual(stats.myMessageCount, 0)
        XCTAssertEqual(stats.symmetryRatio, 1.0)
        XCTAssertEqual(stats.avgResponseTimeSeconds, 0)
    }

    func testDetailMessageStats_useLocalCountsWhenAIHasNoTopics() throws {
        let stats = ChatInsightEngine.computeStats(
            messages: [msg(selfUsername, "only message", 1000)],
            selfUsername: selfUsername,
            chatUsername: "wxid_a", chatName: "Test", isGroup: false, category: .other
        )
        let aiResult = try JSONDecoder().decode(
            ChatInsightResult.self,
            from: Data("""
            {"headline":"","topics":[],"decisions":[],"action_items":[],"mentions_me":0,"waiting_for_me":[],"my_commitments":[],"needs_my_attention":false,"overall_mood":"","signal_noise_ratio":0,"decision_efficiency":"","importance_to_me":{"level":"","reason":""},"cross_chat_topics":null,"insight":"","suggestion":""}
            """.utf8)
        )

        let projected = ChatInsightMessageStats(stats: stats, result: aiResult)

        XCTAssertEqual(projected.total, 1)
        XCTAssertEqual(projected.mine, 1)
        XCTAssertEqual(projected.others, 0)
        XCTAssertEqual(projected.myRatio, 1.0, accuracy: 0.001)
    }

    // MARK: - Response time

    func testAvgResponseTime_calculated() {
        let messages = [
            msg("wxid_a", "question", 1000),
            msg("wxid_me", "answer", 1060),
            msg("wxid_a", "followup", 1200),
            msg("wxid_me", "reply", 1320),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "wxid_a", chatName: "Test", isGroup: false, category: .work
        )
        XCTAssertEqual(stats.avgResponseTimeSeconds, 90, accuracy: 0.1)
    }

    // MARK: - Silence detection

    func testDetectSilence_findsAbnormallySilent() {
        let historical: [String: Int] = ["wxid_a": 10, "wxid_b": 2]
        let todayCounts: [String: Int] = ["wxid_a": 1, "wxid_b": 2]
        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical, todayCounts: todayCounts
        )
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent[0].name, "wxid_a")
        XCTAssertEqual(silent[0].usualDaily, 10)
        XCTAssertEqual(silent[0].today, 1)
    }

    func testDetectSilence_normalActivityNotFlagged() {
        let historical: [String: Int] = ["wxid_a": 10]
        let todayCounts: [String: Int] = ["wxid_a": 8]
        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical, todayCounts: todayCounts
        )
        XCTAssertTrue(silent.isEmpty)
    }

    func testDetectSilence_completelySilent() {
        let historical: [String: Int] = ["wxid_a": 5]
        let todayCounts: [String: Int] = [:]
        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical, todayCounts: todayCounts
        )
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent[0].today, 0)
    }

    // MARK: - Ignored message detection

    func testDetectIgnored_findsUnrepliedMessages() {
        let messages = [
            msg("wxid_a", "我觉得方案一更好", 1000),
            msg("wxid_b", "今天天气不错", 1200),
            msg("wxid_c", "确实", 1300),
            msg("wxid_b", "明天开会", 1400),
        ]
        let ignored = ChatInsightEngine.detectIgnored(messages: messages, windowSeconds: 600)
        XCTAssertEqual(ignored.count, 1)
        XCTAssertEqual(ignored[0].sender, "wxid_a")
        XCTAssertEqual(ignored[0].text, "我觉得方案一更好")
    }

    func testDetectIgnored_repliedNotFlagged() {
        let messages = [
            msg("wxid_a", "方案一如何", 1000),
            msg("wxid_b", "我同意", 1100),
        ]
        let ignored = ChatInsightEngine.detectIgnored(messages: messages, windowSeconds: 600)
        XCTAssertTrue(ignored.isEmpty)
    }

    func testDetectIgnored_lastMessageNotFlagged() {
        let messages = [
            msg("wxid_a", "有人在吗", 1000),
        ]
        let ignored = ChatInsightEngine.detectIgnored(messages: messages, windowSeconds: 600)
        XCTAssertTrue(ignored.isEmpty)
    }

    // MARK: - Sorting score

    func testSortingScore_workHigherThanLife() {
        let workStats = ChatStatsData(
            chatUsername: "w", chatName: "Work", isGroup: true, category: .work,
            messageCount: 10, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            messagesByWeekday: [], typeCounts: [:],
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: [],
            selfInitiated: false, earliestTs: 0, latestTs: 0
        )
        let lifeStats = ChatStatsData(
            chatUsername: "l", chatName: "Life", isGroup: true, category: .life,
            messageCount: 10, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            messagesByWeekday: [], typeCounts: [:],
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: [],
            selfInitiated: false, earliestTs: 0, latestTs: 0
        )
        XCTAssertGreaterThan(
            ChatInsightEngine.sortingScore(workStats, hasActionForMe: false),
            ChatInsightEngine.sortingScore(lifeStats, hasActionForMe: false)
        )
    }

    func testSortingScore_actionBoostsScore() {
        let stats = ChatStatsData(
            chatUsername: "t", chatName: "Test", isGroup: true, category: .other,
            messageCount: 1, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            messagesByWeekday: [], typeCounts: [:],
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: [],
            selfInitiated: false, earliestTs: 0, latestTs: 0
        )
        let withAction = ChatInsightEngine.sortingScore(stats, hasActionForMe: true)
        let withoutAction = ChatInsightEngine.sortingScore(stats, hasActionForMe: false)
        XCTAssertGreaterThan(withAction, withoutAction)
    }

    // MARK: - AI cache fingerprint

    func testInsightInputHash_changesWhenMessageContentChanges() {
        let first = AIChatInsight.stableInsightInputHash(
            chatUsername: "chat",
            chatType: "group",
            category: "work",
            selfName: "哆啦",
            selfAliases: ["yuriwong", "哆啦"],
            timeRange: "今天",
            messages: [
                (sender: "a", body: "明天十点开会", time: 1000),
                (sender: "b", body: "收到", time: 1001),
            ],
            recalledMessages: [],
            memory: "项目 A",
            recentContext: ""
        )
        let second = AIChatInsight.stableInsightInputHash(
            chatUsername: "chat",
            chatType: "group",
            category: "work",
            selfName: "哆啦",
            selfAliases: ["yuriwong", "哆啦"],
            timeRange: "今天",
            messages: [
                (sender: "a", body: "今晚十点开会", time: 1000),
                (sender: "b", body: "收到", time: 1001),
            ],
            recalledMessages: [],
            memory: "项目 A",
            recentContext: ""
        )

        XCTAssertNotEqual(first, second)
    }

    func testInsightInputHash_isStableForSameEvidence() {
        let messages = [
            (sender: "a", body: "排期定了吗", time: 1000),
            (sender: "me", body: "我晚点给", time: 1001),
        ]
        let first = AIChatInsight.stableInsightInputHash(
            chatUsername: "chat",
            chatType: "private",
            category: "work",
            selfName: "哆啦",
            selfAliases: ["yuriwong", "哆啦"],
            timeRange: "今天",
            messages: messages,
            recalledMessages: [(sender: "a", content: "旧方案撤回")],
            memory: "上周讨论过",
            recentContext: ""
        )
        let second = AIChatInsight.stableInsightInputHash(
            chatUsername: "chat",
            chatType: "private",
            category: "work",
            selfName: "哆啦",
            selfAliases: ["yuriwong", "哆啦"],
            timeRange: "今天",
            messages: messages,
            recalledMessages: [(sender: "a", content: "旧方案撤回")],
            memory: "上周讨论过",
            recentContext: ""
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }

    func testAIChatInsightNormalizesSelfAliasesInOutput() async throws {
        let tmp = NSTemporaryDirectory() + "test_chat_insight_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: tmp)
        try store.open()
        defer { store.close() }
        URLRequestRecorder.install()
        defer { URLRequestRecorder.uninstall() }
        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: """
        {
          "headline": "yuriwong 已配合推进排期",
          "topics": [{
            "name": "排期",
            "message_count": 2,
            "participant_count": 2,
            "summary": "张三问 yuriwong 排期",
            "status": "讨论中",
            "my_involvement": "yuriwong 承诺晚点给",
            "attitudes": {"yuriwong": "表面配合"},
            "cross_chats": []
          }],
          "decisions": [],
          "action_items": [{"what": "给排期", "who": "yuriwong", "deadline": null}],
          "mentions_me": 1,
          "waiting_for_me": [{"source": "张三", "what": "等 yuriwong 给排期", "waiting_hours": 0}],
          "my_commitments": ["yuriwong 晚点给"],
          "needs_my_attention": true,
          "overall_mood": "正式",
          "mood_shift": null,
          "attitudes": [{"person": "yuriwong", "topic": "排期", "attitude": "表面配合", "evidence": "yuriwong: 我晚点给"}],
          "tone_changes": [],
          "signal_noise_ratio": 0.8,
          "decision_efficiency": "正常",
          "importance_to_me": {"level": "中", "reason": "张三在等 yuriwong"},
          "participants": [{"name": "yuriwong", "message_count": 1, "role": "执行者", "doing": "给排期", "attitude_toward": {"排期": "表面配合"}}],
          "relationship_signal": "平稳",
          "symmetry": 0.5,
          "cross_chat_topics": [],
          "insight": "yuriwong 被点名后没有立即给排期",
          "suggestion": "yuriwong 应回复张三"
        }
        """)

        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "requested-model",
            apiKey: "sk-test"
        )
        cfg.summaryEnabled = true

        let insight = AIChatInsight(store: store, aiService: AIService(config: cfg))
        let result = await insight.analyzeChat(
            chatUsername: "chat",
            chatName: "项目群",
            chatType: "group",
            category: "work",
            selfName: "哆啦",
            selfAliases: ["yuriwong", "哆啦"],
            timeRange: "今天",
            messages: [
                (sender: "张三", body: "@yuriwong 排期定了吗", time: 1000),
                (sender: "我（哆啦）", body: "我晚点给", time: 1001),
            ],
            recalledMessages: [],
            memory: ""
        )

        XCTAssertEqual(result?.actionItems.first?.who, "我")
        XCTAssertTrue(result?.headline.contains("yuriwong") == false)
        XCTAssertTrue(result?.suggestion.contains("我 应") == true)
    }
}
