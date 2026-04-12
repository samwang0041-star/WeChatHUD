import XCTest
@testable import WeChatHUD

final class HUDStoreTests: XCTestCase {
    var store: HUDStore!
    var tmpPath: String!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_test_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testSettingsRoundTrip() throws {
        try store.setSetting("foo", value: "bar")
        XCTAssertEqual(store.getSetting("foo"), "bar")

        try store.setSetting("foo", value: "baz")
        XCTAssertEqual(store.getSetting("foo"), "baz")
    }

    func testSettingsJSONRoundTrip() throws {
        let cfg = AIConfig(baseURL: "http://test:8080/v1", model: "test-model")
        try store.setSettingJSON("ai", value: cfg)
        let loaded = store.getSettingJSON("ai", as: AIConfig.self)
        XCTAssertEqual(loaded?.baseURL, "http://test:8080/v1")
        XCTAssertEqual(loaded?.model, "test-model")
    }

    func testReplyDebtConfigRoundTrip() throws {
        let cfg = ReplyDebtConfig(
            maxSessions: 50,
            normalOverdueMinutes: 90,
            vipOverdueMinutes: 20,
            groupAtOverdueMinutes: 15
        )
        try store.setSettingJSON("replyDebt", value: cfg)
        let loaded = store.getSettingJSON("replyDebt", as: ReplyDebtConfig.self)
        XCTAssertEqual(loaded?.maxSessions, 50)
        XCTAssertEqual(loaded?.normalOverdueMinutes, 90)
        XCTAssertEqual(loaded?.vipOverdueMinutes, 20)
        XCTAssertEqual(loaded?.groupAtOverdueMinutes, 15)
    }

    func testReplyDebtAIConfigRoundTrip() throws {
        let cfg = ReplyDebtAIConfig(
            enabled: true,
            shadowMode: true,
            maxCandidates: 8,
            minRuleScore: 5,
            requestTimeoutSeconds: 15
        )
        try store.setSettingJSON("replyDebtAI", value: cfg)
        let loaded = store.getSettingJSON("replyDebtAI", as: ReplyDebtAIConfig.self)
        XCTAssertEqual(loaded?.enabled, true)
        XCTAssertEqual(loaded?.shadowMode, true)
        XCTAssertEqual(loaded?.maxCandidates, 8)
        XCTAssertEqual(loaded?.minRuleScore, 5)
        XCTAssertEqual(loaded?.requestTimeoutSeconds, 15)
    }

    func testAIFeedbackPrefixFilter() throws {
        try store.writeAIFeedback(AIFeedbackEntry(
            id: 0,
            ts: Date(),
            msgUID: "reply_debt_audit:1",
            feedbackType: .truePositive,
            originalOutput: "{\"audit\":1}",
            userAction: "confirmed_audit",
            note: "ok"
        ))
        try store.writeAIFeedback(AIFeedbackEntry(
            id: 0,
            ts: Date(),
            msgUID: "classifier:msg-1",
            feedbackType: .falsePositive,
            originalOutput: "{\"msg\":\"1\"}",
            userAction: "marked_not_ask",
            note: "classifier"
        ))

        let loaded = store.loadAIFeedback(limit: 10, msgUIDPrefix: "reply_debt_audit:")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].msgUID, "reply_debt_audit:1")
    }

    func testLatestAIFeedbackByMsgUIDKeepsNewestEntry() throws {
        try store.writeAIFeedback(AIFeedbackEntry(
            id: 0,
            ts: Date(timeIntervalSince1970: 100),
            msgUID: "reply_debt_audit:7",
            feedbackType: .falsePositive,
            originalOutput: "{\"audit\":7}",
            userAction: "rejected_audit",
            note: "old"
        ))
        try store.writeAIFeedback(AIFeedbackEntry(
            id: 0,
            ts: Date(timeIntervalSince1970: 200),
            msgUID: "reply_debt_audit:7",
            feedbackType: .truePositive,
            originalOutput: "{\"audit\":7}",
            userAction: "confirmed_audit",
            note: "new"
        ))

        let latest = store.loadLatestAIFeedbackByMsgUID(
            limit: 10,
            msgUIDPrefix: "reply_debt_audit:"
        )
        XCTAssertEqual(latest["reply_debt_audit:7"]?.feedbackType, .truePositive)
        XCTAssertEqual(latest["reply_debt_audit:7"]?.note, "new")
    }

    func testWhitelistCRUD() throws {
        try store.addToWhitelist(
            username: "user1",
            displayName: "Test User",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        XCTAssertTrue(store.isWhitelisted("user1"))
        XCTAssertFalse(store.isWhitelisted("user2"))

        let list = store.getWhitelist()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].displayName, "Test User")
        XCTAssertEqual(list[0].category, .work)
        XCTAssertEqual(list[0].attentionLevel, .watch)

        try store.removeFromWhitelist(username: "user1")
        XCTAssertFalse(store.isWhitelisted("user1"))
    }

    func testWhitelistMutuallyExclusive() throws {
        try store.addToWhitelist(
            username: "user1",
            displayName: "Test",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.addToWhitelist(
            username: "user1",
            displayName: "Test",
            isGroup: false,
            category: .life,
            attentionLevel: .vip
        )
        let list = store.getWhitelist()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].category, .life)
        XCTAssertEqual(list[0].attentionLevel, .vip)
    }

    func testIgnoredSenderRoundTrip() throws {
        try store.ignoreSender(
            chatUsername: "room@chatroom",
            chatName: "项目群",
            senderUsername: "wxid_alice",
            senderName: "Alice"
        )

        XCTAssertTrue(store.isSenderIgnored(
            chatUsername: "room@chatroom",
            senderUsername: "wxid_alice",
            senderName: "Alice"
        ))

        let rules = store.loadIgnoredSenders()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].chatName, "项目群")
        XCTAssertEqual(rules[0].senderName, "Alice")
    }

    func testIgnoredSenderFallsBackToNameWhenUsernameMissing() throws {
        try store.ignoreSender(
            chatUsername: "room@chatroom",
            chatName: "项目群",
            senderUsername: "",
            senderName: "豆包"
        )

        XCTAssertTrue(store.isSenderIgnored(
            chatUsername: "room@chatroom",
            senderUsername: "",
            senderName: "豆包"
        ))

        try store.unignoreSender(
            chatUsername: "room@chatroom",
            senderUsername: "",
            senderName: "豆包"
        )
        XCTAssertFalse(store.isSenderIgnored(
            chatUsername: "room@chatroom",
            senderUsername: "",
            senderName: "豆包"
        ))
    }

    func testSyncState() throws {
        XCTAssertNil(store.getSyncState("msg_01/Msg_abc"))
        try store.updateSyncState("msg_01/Msg_abc", lastLocalId: 100)
        let state = store.getSyncState("msg_01/Msg_abc")
        XCTAssertEqual(state?.lastLocalId, 100)
    }

    func testAnalysisCacheExpiresAndPurgesOnRead() throws {
        try store.writeAnalysisCache(
            chatUsername: "room@chatroom",
            analysisType: "group_context_briefing_v1",
            inputHash: "msg-1",
            result: #"{"ok":true}"#,
            ttlHours: 1,
            now: Date(timeIntervalSince1970: 100)
        )

        let hit = store.loadAnalysisCache(
            chatUsername: "room@chatroom",
            analysisType: "group_context_briefing_v1",
            inputHash: "msg-1",
            now: Date(timeIntervalSince1970: 120)
        )
        XCTAssertEqual(hit, #"{"ok":true}"#)

        let expired = store.loadAnalysisCache(
            chatUsername: "room@chatroom",
            analysisType: "group_context_briefing_v1",
            inputHash: "msg-1",
            now: Date(timeIntervalSince1970: 4000)
        )
        XCTAssertNil(expired)
    }
}
