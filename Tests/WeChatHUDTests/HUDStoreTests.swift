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
        var cfg = AIConfig()
        cfg.localProvider = AIProviderSlot(providerID: "custom", baseURL: "http://test:8080/v1", model: "test-model", apiKey: "")
        cfg.activeMode = .local
        try store.setSettingJSON("ai", value: cfg)
        let loaded = store.getSettingJSON("ai", as: AIConfig.self)
        XCTAssertEqual(loaded?.localProvider.baseURL, "http://test:8080/v1")
        XCTAssertEqual(loaded?.localProvider.model, "test-model")
        // Compatibility shims should resolve correctly
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

    // MARK: - Whitelist Entry & Baseline

    func testGetWhitelistEntryReturnsCorrectData() throws {
        try store.addToWhitelist(
            username: "wxid_test",
            displayName: "Test User",
            isGroup: true,
            category: .work,
            attentionLevel: .vip
        )
        let entry = store.getWhitelistEntry(username: "wxid_test")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.displayName, "Test User")
        XCTAssertTrue(entry?.isGroup ?? false)
        XCTAssertEqual(entry?.category, .work)
        XCTAssertEqual(entry?.attentionLevel, .vip)
    }

    func testGetWhitelistEntryReturnsNilForMissing() {
        XCTAssertNil(store.getWhitelistEntry(username: "nonexistent"))
    }

    func testWhitelistBaselineRoundTrip() throws {
        XCTAssertNil(store.getWhitelistBaseline(username: "wxid_abc"))
        try store.setWhitelistBaseline(username: "wxid_abc", lastCreateTime: 1700000000)
        XCTAssertEqual(store.getWhitelistBaseline(username: "wxid_abc"), 1700000000)
    }

    func testWhitelistBaselineZeroTreatedAsNil() throws {
        // Baseline of 0 means "never baselined" and should return nil
        try store.setWhitelistBaseline(username: "wxid_zero", lastCreateTime: 0)
        XCTAssertNil(store.getWhitelistBaseline(username: "wxid_zero"))
    }

    func testWhitelistBaselineUpdate() throws {
        try store.setWhitelistBaseline(username: "wxid_upd", lastCreateTime: 100)
        try store.setWhitelistBaseline(username: "wxid_upd", lastCreateTime: 200)
        XCTAssertEqual(store.getWhitelistBaseline(username: "wxid_upd"), 200)
    }

    // MARK: - Chat Actions (silence / snooze / clear)

    func testSilenceChatAndLoad() throws {
        try store.silenceChat(chatUsername: "room@chatroom", silencedAt: 1700000000)
        let actions = store.loadChatActions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions["room@chatroom"]?.silencedAt, 1700000000)
        XCTAssertEqual(actions["room@chatroom"]?.snoozedUntil, 0)
    }

    func testSnoozeChatAndLoad() throws {
        try store.snoozeChat(chatUsername: "room@chatroom", until: 1700003600)
        let actions = store.loadChatActions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions["room@chatroom"]?.snoozedUntil, 1700003600)
        XCTAssertEqual(actions["room@chatroom"]?.silencedAt, 0)
    }

    func testClearChatAction() throws {
        try store.silenceChat(chatUsername: "room1@chatroom", silencedAt: 100)
        try store.snoozeChat(chatUsername: "room2@chatroom", until: 200)
        try store.clearChatAction(chatUsername: "room1@chatroom")
        let actions = store.loadChatActions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertNil(actions["room1@chatroom"])
        XCTAssertNotNil(actions["room2@chatroom"])
    }

    func testSilenceUpdatesExistingAction() throws {
        try store.silenceChat(chatUsername: "room@chatroom", silencedAt: 100)
        try store.silenceChat(chatUsername: "room@chatroom", silencedAt: 200)
        let actions = store.loadChatActions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions["room@chatroom"]?.silencedAt, 200)
    }

    func testLoadChatActionsEmpty() {
        let actions = store.loadChatActions()
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Ignored Sender Map

    func testLoadIgnoredSenderMapGroupsByChat() throws {
        try store.ignoreSender(chatUsername: "room@chatroom", chatName: "群1",
                               senderUsername: "wxid_a", senderName: "Alice")
        try store.ignoreSender(chatUsername: "room@chatroom", chatName: "群1",
                               senderUsername: "wxid_b", senderName: "Bob")
        try store.ignoreSender(chatUsername: "room2@chatroom", chatName: "群2",
                               senderUsername: "wxid_c", senderName: "Carol")

        let map = store.loadIgnoredSenderMap()
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["room@chatroom"]?.count, 2)
        XCTAssertEqual(map["room2@chatroom"]?.count, 1)
    }

    // MARK: - PendingAsk lifecycle

    func testPendingAskUpsertAndLoad() throws {
        let ask = PendingAsk(
            id: 0,
            msgUID: "msg-001",
            chatUsername: "wxid_boss",
            chatName: "老板",
            senderName: "Boss",
            rawText: "明天交报告",
            summary: "明天要交报告",
            askType: .action,
            deadlineAt: Date(timeIntervalSince1970: 1700100000),
            confidence: 0.92,
            bucket: .main,
            status: .pending,
            promptVersion: "classifier_v1",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            updatedAt: Date(timeIntervalSince1970: 1700000000),
            senderLevel: .vip,
            senderRole: .boss,
            urgency: .urgent
        )
        try store.upsertPendingAsk(ask)

        let loaded = store.loadPendingAsks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].msgUID, "msg-001")
        XCTAssertEqual(loaded[0].summary, "明天要交报告")
        XCTAssertEqual(loaded[0].askType, .action)
        XCTAssertEqual(loaded[0].bucket, .main)
        XCTAssertEqual(loaded[0].status, .pending)
        XCTAssertEqual(loaded[0].senderLevel, .vip)
        XCTAssertEqual(loaded[0].senderRole, .boss)
        XCTAssertEqual(loaded[0].urgency, .urgent)
        XCTAssertNotNil(loaded[0].deadlineAt)
    }

    func testPendingAskFilterByBucketAndStatus() throws {
        func makeAsk(_ uid: String, _ bucket: AskBucket, _ status: AskStatus) -> PendingAsk {
            PendingAsk(
                id: 0, msgUID: uid, chatUsername: "c", chatName: "C",
                senderName: "S", rawText: "t", summary: "s",
                askType: .info, deadlineAt: nil, confidence: 0.8,
                bucket: bucket, status: status, promptVersion: "v1",
                createdAt: Date(), updatedAt: Date(),
                senderLevel: nil, senderRole: nil, urgency: nil
            )
        }
        try store.upsertPendingAsk(makeAsk("a", .main, .pending))
        try store.upsertPendingAsk(makeAsk("b", .review, .pending))
        try store.upsertPendingAsk(makeAsk("c", .main, .done))

        XCTAssertEqual(store.loadPendingAsks(bucket: .main).count, 2)
        XCTAssertEqual(store.loadPendingAsks(bucket: .review).count, 1)
        XCTAssertEqual(store.loadPendingAsks(status: .pending).count, 2)
        XCTAssertEqual(store.loadPendingAsks(bucket: .main, status: .pending).count, 1)
    }

    func testHasPendingAsk() throws {
        XCTAssertFalse(store.hasPendingAsk(msgUID: "msg-x"))
        try store.upsertPendingAsk(PendingAsk(
            id: 0, msgUID: "msg-x", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "s",
            askType: .info, deadlineAt: nil, confidence: 0.5,
            bucket: .review, status: .pending, promptVersion: "v1",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: nil, senderRole: nil, urgency: nil
        ))
        XCTAssertTrue(store.hasPendingAsk(msgUID: "msg-x"))
    }

    func testUpdatePendingAskStatus() throws {
        try store.upsertPendingAsk(PendingAsk(
            id: 0, msgUID: "msg-st", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "s",
            askType: .action, deadlineAt: nil, confidence: 0.9,
            bucket: .main, status: .pending, promptVersion: "v1",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: nil, senderRole: nil, urgency: nil
        ))
        try store.updatePendingAskStatus(msgUID: "msg-st", status: .done)
        let loaded = store.loadPendingAsks(status: .done)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].msgUID, "msg-st")
    }

    func testDismissPendingAsk() throws {
        try store.upsertPendingAsk(PendingAsk(
            id: 0, msgUID: "msg-dis", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "s",
            askType: .info, deadlineAt: nil, confidence: 0.7,
            bucket: .review, status: .pending, promptVersion: "v1",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: nil, senderRole: nil, urgency: nil
        ))
        try store.dismissPendingAsk(msgUID: "msg-dis")
        let loaded = store.loadPendingAsks(status: .dismissed)
        XCTAssertEqual(loaded.count, 1)
    }

    func testPendingAskUpsertUpdatesExisting() throws {
        let ask1 = PendingAsk(
            id: 0, msgUID: "msg-dup", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "old summary",
            askType: .info, deadlineAt: nil, confidence: 0.5,
            bucket: .review, status: .pending, promptVersion: "v1",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: nil, senderRole: nil, urgency: nil
        )
        let ask2 = PendingAsk(
            id: 0, msgUID: "msg-dup", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "new summary",
            askType: .action, deadlineAt: nil, confidence: 0.95,
            bucket: .main, status: .pending, promptVersion: "v2",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: .vip, senderRole: .boss, urgency: .urgent
        )
        try store.upsertPendingAsk(ask1)
        try store.upsertPendingAsk(ask2)

        let loaded = store.loadPendingAsks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].summary, "new summary")
        XCTAssertEqual(loaded[0].askType, .action)
        XCTAssertEqual(loaded[0].confidence, 0.95)
    }

    // MARK: - AI Audit

    func testAIAuditWriteAndLoad() throws {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(timeIntervalSince1970: 1700000000),
            role: .classifier,
            model: "test-model",
            promptVersion: "classifier_v1",
            inputText: "你好",
            outputText: #"{"type":"question"}"#,
            latencyMs: 150,
            status: .ok,
            errorMessage: nil
        )
        try store.writeAIAudit(entry)

        let loaded = store.loadRecentAIAudit(limit: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].role, .classifier)
        XCTAssertEqual(loaded[0].model, "test-model")
        XCTAssertEqual(loaded[0].latencyMs, 150)
        XCTAssertEqual(loaded[0].status, .ok)
    }

    func testAIAuditFilterByRole() throws {
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .classifier, model: "m", promptVersion: "v1",
            inputText: "a", outputText: "b", latencyMs: 10, status: .ok, errorMessage: nil
        ))
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .ranker, model: "m", promptVersion: "v1",
            inputText: "c", outputText: "d", latencyMs: 20, status: .ok, errorMessage: nil
        ))

        XCTAssertEqual(store.loadRecentAIAudit(role: .classifier).count, 1)
        XCTAssertEqual(store.loadRecentAIAudit(role: .ranker).count, 1)
        XCTAssertEqual(store.loadRecentAIAudit(role: .retrospector).count, 0)
    }

    func testAIAuditFilterByPromptVersionPrefix() throws {
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .classifier, model: "m", promptVersion: "classifier_v1",
            inputText: "a", outputText: "b", latencyMs: 10, status: .ok, errorMessage: nil
        ))
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .ranker, model: "m", promptVersion: "ranker_v1",
            inputText: "c", outputText: "d", latencyMs: 20, status: .ok, errorMessage: nil
        ))

        XCTAssertEqual(store.loadRecentAIAudit(promptVersionPrefix: "classifier_").count, 1)
        XCTAssertEqual(store.loadRecentAIAudit(promptVersionPrefix: "ranker_").count, 1)
    }

    func testAIAuditPruneRemovesOldEntries() throws {
        // Write an entry with timestamp 30 days ago
        let oldDate = Date(timeIntervalSinceNow: -31 * 86400)
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: oldDate, role: .classifier, model: "m", promptVersion: "v1",
            inputText: "old", outputText: "old", latencyMs: 10, status: .ok, errorMessage: nil
        ))
        // Write a recent entry
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .classifier, model: "m", promptVersion: "v1",
            inputText: "new", outputText: "new", latencyMs: 10, status: .ok, errorMessage: nil
        ))

        try store.pruneAIAudit(olderThanDays: 14)
        let remaining = store.loadRecentAIAudit()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].inputText, "new")
    }

    // MARK: - Autopilot Session & Log

    func testAutopilotSessionLifecycle() throws {
        let sessionId = try store.startAutopilotSession()
        XCTAssertTrue(sessionId > 0)

        let current = store.currentAutopilotSession()
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.id, sessionId)
        XCTAssertNil(current?.endedAt)

        try store.updateAutopilotSessionCounts(id: sessionId, handled: 5, pending: 2, sent: 3)
        let updated = store.currentAutopilotSession()
        XCTAssertEqual(updated?.totalHandled, 5)
        XCTAssertEqual(updated?.totalPending, 2)
        XCTAssertEqual(updated?.totalSent, 3)

        try store.endAutopilotSession(id: sessionId)
        XCTAssertNil(store.currentAutopilotSession())
    }

    func testAutopilotLogInsertAndLoad() throws {
        let sessionId = try store.startAutopilotSession()
        let entry = AutopilotLogEntry(
            id: 0,
            sessionId: sessionId,
            chatUsername: "wxid_test",
            chatName: "Test",
            senderUsername: "wxid_sender",
            senderName: "Sender",
            triggerMsgUID: "msg-ap-1",
            triggerText: "你好",
            generatedReply: "你好！",
            confidence: 0.95,
            riskLevel: .low,
            action: .sent,
            aiReasoning: "Simple greeting",
            sentAt: Date(),
            createdAt: Date()
        )
        try store.insertAutopilotLog(entry)

        let loaded = store.loadAutopilotLog(sessionId: sessionId)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].triggerText, "你好")
        XCTAssertEqual(loaded[0].generatedReply, "你好！")
        XCTAssertEqual(loaded[0].riskLevel, .low)
        XCTAssertEqual(loaded[0].action, .sent)
        XCTAssertEqual(loaded[0].aiReasoning, "Simple greeting")
    }

    func testAutopilotPendingItems() throws {
        let sessionId = try store.startAutopilotSession()
        // Insert a pending item
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c1", chatName: "C1",
            senderUsername: "s1", senderName: "S1",
            triggerMsgUID: "m1", triggerText: "重要的事",
            generatedReply: "收到", confidence: 0.6,
            riskLevel: .medium, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        // Insert a sent item
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c2", chatName: "C2",
            senderUsername: "s2", senderName: "S2",
            triggerMsgUID: "m2", triggerText: "hi",
            generatedReply: "hello", confidence: 0.99,
            riskLevel: .low, action: .sent,
            aiReasoning: nil, sentAt: Date(), createdAt: Date()
        ))

        let pending = store.loadPendingAutopilotItems(sessionId: sessionId)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].triggerMsgUID, "m1")
    }

    func testAutopilotLogUpdateAction() throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c", chatName: "C",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "m", triggerText: "t",
            generatedReply: "r", confidence: 0.7,
            riskLevel: .medium, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))

        let loaded = store.loadPendingAutopilotItems(sessionId: sessionId)
        XCTAssertEqual(loaded.count, 1)
        let logId = loaded[0].id

        try store.updateAutopilotLogAction(id: logId, action: .skipped)
        let afterUpdate = store.loadPendingAutopilotItems(sessionId: sessionId)
        XCTAssertEqual(afterUpdate.count, 0)  // no longer pending
    }

    func testAutopilotMarkLogSent() throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c", chatName: "C",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "m", triggerText: "t",
            generatedReply: "reply", confidence: 0.8,
            riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))

        let pending = store.loadPendingAutopilotItems(sessionId: sessionId)
        try store.markAutopilotLogSent(id: pending[0].id)

        let log = store.loadAutopilotLog(sessionId: sessionId)
        XCTAssertEqual(log[0].action, .sent)
        XCTAssertNotNil(log[0].sentAt)
    }

    func testLoadAutopilotSessions() throws {
        let s1 = try store.startAutopilotSession()
        try store.endAutopilotSession(id: s1)
        let s2 = try store.startAutopilotSession()

        let sessions = store.loadAutopilotSessions()
        XCTAssertEqual(sessions.count, 2)
        // Most recent first
        XCTAssertEqual(sessions[0].id, s2)
        XCTAssertNil(sessions[0].endedAt)
        XCTAssertEqual(sessions[1].id, s1)
        XCTAssertNotNil(sessions[1].endedAt)
    }

    func testClearAutopilotHistory() throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c", chatName: "C",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "m", triggerText: "t",
            generatedReply: nil, confidence: 0.5,
            riskLevel: .low, action: .skipped,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))

        try store.clearAutopilotHistory()
        XCTAssertNil(store.currentAutopilotSession())
        XCTAssertTrue(store.loadAutopilotSessions().isEmpty)
        XCTAssertTrue(store.loadAutopilotLog(sessionId: sessionId).isEmpty)
    }

    // MARK: - Sender Identifier (static helper)

    func testSenderIdentifierUsesUsernameWhenAvailable() {
        let id = HUDStore.senderIdentifier(senderUsername: "wxid_abc", senderName: "Alice")
        XCTAssertEqual(id, "username:wxid_abc")
    }

    func testSenderIdentifierFallsBackToNameWhenUsernameEmpty() {
        let id = HUDStore.senderIdentifier(senderUsername: "", senderName: "豆包")
        XCTAssertEqual(id, "name:豆包")
    }

    func testSenderIdentifierNormalizesWhitespace() {
        let id = HUDStore.senderIdentifier(senderUsername: "  WxId_ABC  ", senderName: "Alice")
        XCTAssertEqual(id, "username:wxid_abc")
    }

    // MARK: - Config loading

    func testLoadClassifierConfigReturnsSeededDefaults() {
        let cfg = store.loadAIConfig()
        XCTAssertFalse(cfg.baseURL.isEmpty)
        XCTAssertFalse(cfg.model.isEmpty)
    }

    func testLoadAIConfigReturnsSeededDefaults() {
        let cfg = store.loadAIConfig()
        XCTAssertFalse(cfg.baseURL.isEmpty)
        XCTAssertFalse(cfg.model.isEmpty)
    }

    func testScanDismissedRoundTrip() throws {
        try store.dismissScanResult(username: "alice", displayName: "Alice")
        Thread.sleep(forTimeInterval: 1.1)
        try store.dismissScanResult(username: "bob", displayName: "Bob")

        let all = store.loadDismissedScanResults()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].username, "bob")  // most recent first

        let set = store.dismissedScanUsernames()
        XCTAssertTrue(set.contains("alice"))
        XCTAssertTrue(set.contains("bob"))

        try store.undismissScanResult(username: "alice")
        XCTAssertEqual(store.loadDismissedScanResults().count, 1)
        XCTAssertFalse(store.dismissedScanUsernames().contains("alice"))
    }

    func testScanDismissedUpsert() throws {
        try store.dismissScanResult(username: "alice", displayName: "Alice")
        try store.dismissScanResult(username: "alice", displayName: "Alice Updated")
        let all = store.loadDismissedScanResults()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].displayName, "Alice Updated")
    }
}
