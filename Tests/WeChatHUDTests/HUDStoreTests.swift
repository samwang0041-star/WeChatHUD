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
        cfg.provider = AIProviderSlot(providerID: "custom", baseURL: "http://test:8080/v1", model: "test-model", apiKey: "")
        try store.setSettingJSON("ai", value: cfg)
        let loaded = store.getSettingJSON("ai", as: AIConfig.self)
        XCTAssertEqual(loaded?.provider.baseURL, "http://test:8080/v1")
        XCTAssertEqual(loaded?.provider.model, "test-model")
        // Compatibility shims should resolve correctly
        XCTAssertEqual(loaded?.baseURL, "http://test:8080/v1")
        XCTAssertEqual(loaded?.model, "test-model")
    }

    func testAIProviderSlotToleratesMissingFields() throws {
        try store.setSetting("ai", value: """
        {
          "localProvider": {
            "providerID": "custom",
            "baseURL": "http://test:8080/v1",
            "model": "test-model"
          },
          "activeMode": "local"
        }
        """)

        let cfg = store.loadAIConfig()

        XCTAssertEqual(cfg.provider.providerID, "custom")
        XCTAssertEqual(cfg.provider.baseURL, "http://test:8080/v1")
        XCTAssertEqual(cfg.provider.model, "test-model")
        XCTAssertEqual(cfg.provider.apiKey, "")
        XCTAssertEqual(cfg.baseURL, "http://test:8080/v1")
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
        XCTAssertTrue(store.hasWhitelistEntries())
        XCTAssertEqual(store.whitelistCount(), 1)

        let list = store.getWhitelist()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].displayName, "Test User")
        XCTAssertEqual(list[0].category, .work)
        XCTAssertEqual(list[0].attentionLevel, .watch)
        XCTAssertEqual(store.getContact(username: "user1")?.attentionLevel, .whitelist)
        XCTAssertEqual(store.getContact(username: "user1")?.role, .colleague)

        try store.removeFromWhitelist(username: "user1")
        XCTAssertFalse(store.isWhitelisted("user1"))
        XCTAssertFalse(store.hasWhitelistEntries())
        XCTAssertEqual(store.whitelistCount(), 0)
        XCTAssertNil(store.getContact(username: "user1"))
    }

    // Regression: removing a whitelist entry must drop its baseline and
    // any chat_actions too. Otherwise re-adding the same user later
    // reuses the stale watermark → backlog silently swallowed, or the
    // re-added chat comes back already muted.
    func testRemoveFromWhitelistClearsBaselineAndActions() throws {
        try store.addToWhitelist(
            username: "user1",
            displayName: "T",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.setWhitelistBaseline(username: "user1", lastCreateTime: 1700000000)
        try store.silenceChat(chatUsername: "user1", silencedAt: 1700001000)
        XCTAssertEqual(store.getWhitelistBaseline(username: "user1"), 1700000000)
        XCTAssertNotNil(store.loadChatActions()["user1"])

        try store.removeFromWhitelist(username: "user1")

        XCTAssertNil(store.getWhitelistBaseline(username: "user1"))
        XCTAssertNil(store.loadChatActions()["user1"])
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
        XCTAssertEqual(store.getContact(username: "user1")?.attentionLevel, .vip)
        XCTAssertEqual(store.getContact(username: "user1")?.role, .colleague)
    }

    func testAddToWhitelistPreservesExistingContactSettings() throws {
        try store.upsertContact(
            username: "user1",
            displayName: "Old Name",
            attentionLevel: .greylist,
            role: .supplier,
            roleNote: "keep me",
            replyWindowMinutes: 480
        )

        try store.addToWhitelist(
            username: "user1",
            displayName: "New Name",
            isGroup: false,
            category: .life,
            attentionLevel: .watch
        )

        let contact = store.getContact(username: "user1")
        XCTAssertEqual(contact?.displayName, "New Name")
        XCTAssertEqual(contact?.attentionLevel, .whitelist)
        XCTAssertEqual(contact?.role, .supplier)
        XCTAssertEqual(contact?.roleNote, "keep me")
        XCTAssertEqual(contact?.replyWindowMinutes, 480)
    }

    func testSaveContactTrackingWritesWhitelistForTrackedLevels() throws {
        try store.saveContactTracking(
            username: "wxid_track",
            displayName: "Track Me",
            isGroup: false,
            category: .work,
            attentionLevel: .vip,
            role: .boss,
            roleNote: "CEO",
            replyWindowMinutes: 30
        )

        let whitelistEntry = store.getWhitelistEntry(username: "wxid_track")
        XCTAssertEqual(whitelistEntry?.displayName, "Track Me")
        XCTAssertEqual(whitelistEntry?.category, .work)
        XCTAssertEqual(whitelistEntry?.attentionLevel, .vip)

        let contact = store.getContact(username: "wxid_track")
        XCTAssertEqual(contact?.attentionLevel, .vip)
        XCTAssertEqual(contact?.role, .boss)
        XCTAssertEqual(contact?.roleNote, "CEO")
        XCTAssertEqual(contact?.replyWindowMinutes, 30)
    }

    func testSaveContactTrackingGreylistUntracksButPreservesContact() throws {
        try store.saveContactTracking(
            username: "wxid_grey",
            displayName: "Grey",
            isGroup: false,
            category: .life,
            attentionLevel: .whitelist,
            role: .friend,
            roleNote: "old friend",
            replyWindowMinutes: 240
        )
        try store.setWhitelistBaseline(username: "wxid_grey", lastCreateTime: 1700000000)
        try store.silenceChat(chatUsername: "wxid_grey", silencedAt: 1700001000)

        try store.saveContactTracking(
            username: "wxid_grey",
            displayName: "Grey",
            isGroup: false,
            category: .life,
            attentionLevel: .greylist,
            role: .friend,
            roleNote: "old friend",
            replyWindowMinutes: 240
        )

        XCTAssertFalse(store.isWhitelisted("wxid_grey"))
        XCTAssertNil(store.getWhitelistBaseline(username: "wxid_grey"))
        XCTAssertNil(store.loadChatActions()["wxid_grey"])
        let contact = store.getContact(username: "wxid_grey")
        XCTAssertEqual(contact?.attentionLevel, .greylist)
        XCTAssertEqual(contact?.roleNote, "old friend")
    }

    func testDeleteContactAndTrackingRemovesWhitelistGhost() throws {
        try store.saveContactTracking(
            username: "wxid_delete",
            displayName: "Delete",
            isGroup: false,
            category: .work,
            attentionLevel: .whitelist,
            role: .colleague,
            replyWindowMinutes: 240
        )

        try store.deleteContactAndTracking(username: "wxid_delete")

        XCTAssertFalse(store.isWhitelisted("wxid_delete"))
        XCTAssertNil(store.getWhitelistEntry(username: "wxid_delete"))
        XCTAssertNil(store.getContact(username: "wxid_delete"))
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

    func testWhitelistCursorStoresSameSecondTieBreaker() throws {
        XCTAssertNil(store.getWhitelistCursor(username: "wxid_cursor"))

        try store.setWhitelistCursor(username: "wxid_cursor", lastCreateTime: 200, lastLocalId: 41)

        let cursor = store.getWhitelistCursor(username: "wxid_cursor")
        XCTAssertEqual(cursor?.lastCreateTime, 200)
        XCTAssertEqual(cursor?.lastLocalId, 41)
        XCTAssertEqual(store.getWhitelistBaseline(username: "wxid_cursor"), 200)
    }

    func testAutopilotCursorDoesNotPolluteWhitelistCursor() throws {
        try store.setAutopilotCursor(username: "wxid_private", lastCreateTime: 300, lastLocalId: 9)

        XCTAssertNil(store.getWhitelistCursor(username: "wxid_private"))
        XCTAssertEqual(store.getAutopilotCursor(username: "wxid_private")?.lastCreateTime, 300)
        XCTAssertEqual(store.getAutopilotCursor(username: "wxid_private")?.lastLocalId, 9)
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

    func testSnoozeClearsExistingSilence() throws {
        try store.silenceChat(chatUsername: "room@chatroom", silencedAt: 1_700_000_000)
        try store.snoozeChat(chatUsername: "room@chatroom", until: 1_700_003_600)
        let action = store.loadChatActions()["room@chatroom"]
        XCTAssertEqual(action?.snoozedUntil, 1_700_003_600)
        XCTAssertEqual(action?.silencedAt, 0)
    }

    func testSilenceClearsExistingSnooze() throws {
        try store.snoozeChat(chatUsername: "room@chatroom", until: 1_700_003_600)
        try store.silenceChat(chatUsername: "room@chatroom", silencedAt: 1_700_000_000)
        let action = store.loadChatActions()["room@chatroom"]
        XCTAssertEqual(action?.silencedAt, 1_700_000_000)
        XCTAssertEqual(action?.snoozedUntil, 0)
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

    func testPendingAskUpsertPreservesHandledStatus() throws {
        let ask = PendingAsk(
            id: 0, msgUID: "msg-handled", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "old",
            askType: .action, deadlineAt: nil, confidence: 0.9,
            bucket: .main, status: .pending, promptVersion: "v1",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: nil, senderRole: nil, urgency: nil
        )
        try store.upsertPendingAsk(ask)
        try store.updatePendingAskStatus(msgUID: "msg-handled", status: .done)
        try store.upsertPendingAsk(PendingAsk(
            id: 0, msgUID: "msg-handled", chatUsername: "c", chatName: "C",
            senderName: "S", rawText: "t", summary: "new",
            askType: .action, deadlineAt: nil, confidence: 0.95,
            bucket: .main, status: .pending, promptVersion: "v2",
            createdAt: Date(), updatedAt: Date(),
            senderLevel: nil, senderRole: nil, urgency: nil
        ))

        XCTAssertEqual(store.loadPendingAsks(status: .done).first?.summary, "new")
        XCTAssertTrue(store.loadPendingAsks(status: .pending).isEmpty)
    }

    // MARK: - Commitment lifecycle

    func testCommitmentCreatedAtCanUseSourceMessageTime() throws {
        let sourceTime = Date(timeIntervalSince1970: 1_700_000_123)
        try store.upsertCommitment(
            msgUID: "commit-source",
            chatUsername: "c",
            chatName: "C",
            content: "发资料",
            commitTo: "S",
            confidence: 0.9,
            promptVersion: "commitment_v1",
            createdAt: sourceTime
        )

        let loaded = store.loadCommitments()
        XCTAssertEqual(loaded.first?.createdAt.timeIntervalSince1970, sourceTime.timeIntervalSince1970)
    }

    func testAutoAdvanceCanFulfillOverdueCommitmentButNotCancelled() throws {
        try store.upsertCommitment(
            msgUID: "commit-late",
            chatUsername: "c",
            chatName: "C",
            content: "发资料",
            commitTo: "S",
            confidence: 0.9,
            promptVersion: "commitment_v1"
        )
        try store.autoAdvanceCommitmentStatus(msgUID: "commit-late", to: .overdue)
        try store.autoAdvanceCommitmentStatus(msgUID: "commit-late", to: .fulfilled)
        XCTAssertEqual(store.loadCommitments().first { $0.msgUID == "commit-late" }?.status, .fulfilled)

        try store.upsertCommitment(
            msgUID: "commit-cancelled",
            chatUsername: "c",
            chatName: "C",
            content: "不做了",
            commitTo: "S",
            confidence: 0.9,
            promptVersion: "commitment_v1"
        )
        try store.updateCommitmentStatus(msgUID: "commit-cancelled", status: .cancelled)
        try store.autoAdvanceCommitmentStatus(msgUID: "commit-cancelled", to: .fulfilled)
        XCTAssertEqual(store.loadCommitments().first { $0.msgUID == "commit-cancelled" }?.status, .cancelled)
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
        XCTAssertTrue(remaining[0].inputText.contains("new") || remaining[0].inputText.contains("sha256:"))
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

    func testAutopilotLogUpdateReply() throws {
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

        let logId = store.loadPendingAutopilotItems(sessionId: sessionId)[0].id
        try store.updateAutopilotLogReply(id: logId, reply: "改成这样说")

        let log = store.loadAutopilotLog(sessionId: sessionId)
        XCTAssertEqual(log[0].generatedReply, "改成这样说")
        XCTAssertEqual(log[0].action, .pending)  // still pending — edit ≠ send
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

    func testPendingSendPersistenceRoundTripAndDelete() throws {
        let sessionId = try store.startAutopilotSession()
        let id = UUID()
        let scheduled = Date(timeIntervalSince1970: 1_800)
        let created = Date(timeIntervalSince1970: 1_700)
        let item = PendingSend(
            id: id,
            chatUsername: "wxid_peer",
            chatName: "Peer",
            senderName: "Sender",
            replyText: "收到，我晚点看",
            confidence: 0.91,
            risk: .low,
            reasoning: "低风险确认",
            styleScore: 86,
            scheduledSendTime: scheduled,
            createdAt: created,
            peerLastMessage: "帮我看下这个",
            topic: "讨论",
            autoSendAttempts: 1,
            manualOnlyReason: "发送结果无法确认"
        )

        try store.upsertPendingSend(item, sessionId: sessionId)

        let loaded = store.loadPendingSends(sessionId: sessionId)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].chatUsername, "wxid_peer")
        XCTAssertEqual(loaded[0].replyText, "收到，我晚点看")
        XCTAssertEqual(loaded[0].risk, .low)
        XCTAssertEqual(loaded[0].styleScore, 86)
        XCTAssertEqual(Int(loaded[0].scheduledSendTime.timeIntervalSince1970), 1_800)
        XCTAssertEqual(Int(loaded[0].createdAt.timeIntervalSince1970), 1_700)
        XCTAssertEqual(loaded[0].peerLastMessage, "帮我看下这个")
        XCTAssertEqual(loaded[0].topic, "讨论")
        XCTAssertEqual(loaded[0].autoSendAttempts, 1)
        XCTAssertEqual(loaded[0].manualOnlyReason, "发送结果无法确认")

        try store.deletePendingSend(id: id)
        XCTAssertTrue(store.loadPendingSends(sessionId: sessionId).isEmpty)
    }

    /// Two identical replies in the same chat ("好的") each have their own
    /// queue twin — resolving one must never touch the other. This is the
    /// collision the queue_id shared key fixes: the old (chat, replyText)
    /// text match would flip BOTH rows and delete BOTH queue rows, marking
    /// B as sent although nothing went out.
    func testAutopilotTwinResolutionIsQueueIdKeyed() throws {
        let sessionId = try store.startAutopilotSession()
        let qA = UUID()
        let qB = UUID()

        func logRow(_ qid: UUID, trigger: String) -> AutopilotLogEntry {
            AutopilotLogEntry(
                id: 0, sessionId: sessionId,
                chatUsername: "wxid_dup", chatName: "Dup",
                senderUsername: "wxid_sender", senderName: "Sender",
                triggerMsgUID: trigger, triggerText: "在吗",
                generatedReply: "好的", confidence: 0.9,
                riskLevel: .low, action: .pending,
                aiReasoning: nil, sentAt: nil, createdAt: Date(),
                queueId: qid.uuidString
            )
        }
        func queueRow(_ qid: UUID) -> PendingSend {
            PendingSend(
                id: qid, chatUsername: "wxid_dup", chatName: "Dup",
                senderName: "Sender", replyText: "好的", confidence: 0.9,
                risk: .low, reasoning: "", styleScore: 0,
                scheduledSendTime: Date().addingTimeInterval(30),
                createdAt: Date()
            )
        }

        try store.insertAutopilotLog(logRow(qA, trigger: "mA"))
        try store.insertAutopilotLog(logRow(qB, trigger: "mB"))
        try store.upsertPendingSend(queueRow(qA), sessionId: sessionId)
        try store.upsertPendingSend(queueRow(qB), sessionId: sessionId)

        // Resolve A by queue_id — B must survive as pending.
        let flipped = try store.markAutopilotLogSent(
            queueId: qA, chatUsername: "wxid_dup", replyText: "好的"
        )
        XCTAssertEqual(flipped, 1)
        let stillPending = store.loadPendingAutopilotItems(sessionId: sessionId)
        XCTAssertEqual(stillPending.count, 1)
        XCTAssertEqual(stillPending[0].triggerMsgUID, "mB")

        // Log → queue direction: deleting A's twin must leave B's queue row.
        let logA = store.loadAutopilotLog(sessionId: sessionId)
            .first { $0.triggerMsgUID == "mA" }!
        try store.deletePendingSendForLog(
            logId: logA.id, chatUsername: "wxid_dup", replyText: "好的"
        )
        let remaining = store.loadPendingSends(sessionId: sessionId)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, qB)
    }

    /// A racing reject must not stomp an in-flight approve whose send
    /// completed — and neither side may double-count sessionPending.
    func testAutopilotRejectAfterSentIsIdempotent() throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "wxid_race", chatName: "Race",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "mR", triggerText: "hi",
            generatedReply: "收到", confidence: 0.9,
            riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        let logId = store.loadAutopilotLog(sessionId: sessionId)[0].id

        // Approve-path send completes first.
        XCTAssertTrue(store.resolveAutopilotLogSent(id: logId))
        // Reject lands late — must not flip a sent row, must not count.
        XCTAssertFalse(store.resolveAutopilotLogSkipped(id: logId))
        // Double-send resolution doesn't recount either.
        XCTAssertFalse(store.resolveAutopilotLogSent(id: logId))

        let row = store.loadAutopilotLog(sessionId: sessionId)[0]
        XCTAssertEqual(row.action, .sent)
        XCTAssertNotNil(row.sentAt)
    }

    /// A claimed queue_id must never fall back into the text match — a
    /// same-text LEGACY row (queue_id NULL) must survive resolution of the
    /// new-format twin.
    func testAutopilotNewFormatRowDoesNotTouchLegacyTwin() throws {
        let sessionId = try store.startAutopilotSession()
        let qid = UUID()

        // Legacy row: identical chat+text, no queue_id.
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "wxid_dup", chatName: "Dup",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "legacy", triggerText: "在吗",
            generatedReply: "好的", confidence: 0.9,
            riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        // New-format row: same text, queue_id claimed.
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "wxid_dup", chatName: "Dup",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "new", triggerText: "在吗",
            generatedReply: "好的", confidence: 0.9,
            riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: qid.uuidString
        ))

        _ = try store.markAutopilotLogSent(
            queueId: qid, chatUsername: "wxid_dup", replyText: "好的"
        )
        let rows = store.loadAutopilotLog(sessionId: sessionId)
        let legacy = rows.first { $0.triggerMsgUID == "legacy" }!
        let new = rows.first { $0.triggerMsgUID == "new" }!
        XCTAssertEqual(new.action, .sent)
        // The legacy row was NOT flipped by the claimed-id resolution.
        XCTAssertEqual(legacy.action, .pending)
    }

    /// '.stall' twins are unverified send claims — a verified send stamps
    /// sent_at on them, skip flips them to skipped, and the pending
    /// conversion pulls them back to pending.
    func testAutopilotStallTwinLifecycle() throws {
        let sessionId = try store.startAutopilotSession()
        let qid = UUID()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "wxid_stall", chatName: "Stall",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "mS", triggerText: "hi",
            generatedReply: "好的", confidence: 0.9,
            riskLevel: .low, action: .stall,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: qid.uuidString
        ))

        // Stall → sent stamps the claim.
        _ = try store.markAutopilotLogSent(
            queueId: qid, chatUsername: "wxid_stall", replyText: "好的"
        )
        var row = store.loadAutopilotLog(sessionId: sessionId)[0]
        XCTAssertEqual(row.action, .sent)
        XCTAssertNotNil(row.sentAt)

        // Sent is terminal — pending conversion must not reopen it.
        _ = try store.markAutopilotLogPending(
            queueId: qid, chatUsername: "wxid_stall", replyText: "好的"
        )
        row = store.loadAutopilotLog(sessionId: sessionId)[0]
        XCTAssertEqual(row.action, .sent)
    }

    func testAutopilotStallToPendingOnRequeue() throws {
        let sessionId = try store.startAutopilotSession()
        let qid = UUID()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "wxid_stall2", chatName: "Stall2",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "mS2", triggerText: "hi",
            generatedReply: "好的", confidence: 0.9,
            riskLevel: .low, action: .stall,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: qid.uuidString
        ))
        XCTAssertTrue(store.autopilotLogTwinOpen(queueId: qid))
        let flipped = try store.markAutopilotLogPending(
            queueId: qid, chatUsername: "wxid_stall2", replyText: "好的"
        )
        XCTAssertEqual(flipped, 1)
        XCTAssertEqual(store.loadAutopilotLog(sessionId: sessionId)[0].action, .pending)
        XCTAssertTrue(store.autopilotLogTwinOpen(queueId: qid))
        // Skip resolves it — no longer open.
        _ = try store.markAutopilotLogSkipped(
            queueId: qid, chatUsername: "wxid_stall2", replyText: "好的"
        )
        XCTAssertEqual(store.loadAutopilotLog(sessionId: sessionId)[0].action, .skipped)
        XCTAssertFalse(store.autopilotLogTwinOpen(queueId: qid))
    }

    /// Legacy sent-claim stamping is bounded to ONE row — a same-text legacy
    /// sibling must not inherit the sent stamp.
    func testAutopilotLegacySentStampIsSingleRowBounded() throws {
        let sessionId = try store.startAutopilotSession()
        for trigger in ["lA", "lB"] {
            try store.insertAutopilotLog(AutopilotLogEntry(
                id: 0, sessionId: sessionId,
                chatUsername: "wxid_dup2", chatName: "Dup2",
                senderUsername: "s", senderName: "S",
                triggerMsgUID: trigger, triggerText: "在吗",
                generatedReply: "好的", confidence: 0.9,
                riskLevel: .low, action: .sent,
                aiReasoning: nil, sentAt: nil, createdAt: Date()
            ))
        }
        let qid = UUID() // a queue id no row claims → legacy fallback path
        _ = try store.markAutopilotLogSent(
            queueId: qid, chatUsername: "wxid_dup2", replyText: "好的"
        )
        let rows = store.loadAutopilotLog(sessionId: sessionId)
        let stamped = rows.filter { $0.sentAt != nil }
        XCTAssertEqual(stamped.count, 1, "only ONE legacy same-text row may be stamped")
    }

    func testAutopilotInboundQueueRoundTripAndAck() throws {
        let msg = AutopilotService.InboundMessage(
            msgUID: "msg-inbound-1",
            chatUsername: "wxid_peer",
            chatName: "Peer",
            senderUsername: "wxid_sender",
            senderName: "Sender",
            text: "你看看这个",
            isGroup: false,
            isAtMention: false,
            attentionLevel: .whitelist,
            contactRole: .friend,
            timestamp: 1_900,
            messageType: 1,
            appType: 0
        )

        try store.enqueueAutopilotInbound(msg)
        try store.enqueueAutopilotInbound(msg)

        let loaded = store.loadPendingAutopilotInbound()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].msgUID, "msg-inbound-1")
        XCTAssertEqual(loaded[0].chatUsername, "wxid_peer")
        XCTAssertEqual(loaded[0].attentionLevel, .whitelist)
        XCTAssertEqual(loaded[0].contactRole, .friend)
        XCTAssertEqual(loaded[0].timestamp, 1_900)

        try store.deleteAutopilotInbound(msgUIDs: ["msg-inbound-1"])
        XCTAssertTrue(store.loadPendingAutopilotInbound().isEmpty)
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

        XCTAssertThrowsError(try store.clearAutopilotHistory())
        XCTAssertNotNil(store.currentAutopilotSession())
        XCTAssertEqual(store.loadAutopilotLog(sessionId: sessionId).count, 1)
        try store.endAutopilotSession(id: sessionId)
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

    func testOpenAutopilotPendingSurvivesEndedSessionAndSavesReply() throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c", chatName: "C",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "proactive", triggerText: "在吗",
            generatedReply: "稍后", confidence: 0.6,
            riskLevel: .medium, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        try store.endAutopilotSession(id: sessionId)
        XCTAssertNil(store.currentAutopilotSession())

        let open = store.loadOpenAutopilotPendingItems()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].triggerMsgUID, "proactive")
        let display = store.loadAutopilotDisplayLog(sessionId: nil)
        XCTAssertEqual(display.map(\.id), open.map(\.id))

        try store.updateAutopilotLogReply(id: open[0].id, reply: "改过的草稿")
        XCTAssertEqual(store.loadOpenAutopilotPendingItems().first?.generatedReply, "改过的草稿")
    }

    func testStaleAutopilotPendingIsHiddenFromLiveWindow() throws {
        let sessionId = try store.startAutopilotSession()
        let stale = Date(timeIntervalSince1970: 1_700_000_000) // 2023
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "c", chatName: "C",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "old", triggerText: "在吗",
            generatedReply: "稍后", confidence: 0.6,
            riskLevel: .medium, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: stale
        ))
        try store.endAutopilotSession(id: sessionId)
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: Date(timeIntervalSince1970: 1_778_000_000))
        XCTAssertTrue(store.loadOpenAutopilotPendingItems().contains { $0.triggerMsgUID == "old" })
        XCTAssertFalse(store.loadOpenAutopilotPendingItems(relevantSince: cutoff).contains { $0.triggerMsgUID == "old" })
        XCTAssertFalse(store.loadAutopilotDisplayLog(sessionId: nil, relevantSince: cutoff).contains { $0.triggerMsgUID == "old" })
    }

    func testCompletingACommitmentClosesTheMatchingDiscussionRow() throws {
        try store.upsertCommitment(
            msgUID: "same-msg", chatUsername: "chat", chatName: "项目群",
            content: "提交方案", commitTo: "林晓",
            deadlineAt: Date(), confidence: 0.9, promptVersion: "test"
        )
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "提交方案", detail: nil, anchorMsgUID: "same-msg",
            sourceTimestamp: Int(Date().timeIntervalSince1970),
            dueAt: nil, confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertEqual(try store.updatePendingDiscussionItems(matchingAnchorMsgUID: "same-msg", status: .done), 1)
        XCTAssertEqual(store.loadDiscussionItems(status: .pending).count, 0)
        XCTAssertEqual(store.loadDiscussionItems(excludingStatus: .pending).first?.status, .done)
    }

    func testVIPContactRepairPromotesOrCreatesWhitelistTracking() throws {
        try store.upsertContact(
            username: "wxid_vip_missing",
            displayName: "测试号",
            attentionLevel: .vip,
            role: .colleague
        )
        try store.addToWhitelist(
            username: "wxid_vip_watch",
            displayName: "赖豪",
            isGroup: false,
            category: .work,
            attentionLevel: .watch
        )
        try store.upsertContact(
            username: "wxid_vip_watch",
            displayName: "赖豪",
            attentionLevel: .vip,
            role: .colleague
        )

        store.repairVIPTrackingAlignment()

        XCTAssertEqual(store.getWhitelistEntry(username: "wxid_vip_missing")?.attentionLevel, .vip)
        XCTAssertEqual(store.getWhitelistEntry(username: "wxid_vip_watch")?.attentionLevel, .vip)
    }

    func testStalePendingAsksLeaveTheLiveWindow() throws {
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        try store.upsertPendingAsk(PendingAsk(
            id: 0, msgUID: "old", chatUsername: "c", chatName: "C", senderName: "S",
            rawText: "旧请求", summary: "旧请求", askType: .none, deadlineAt: nil,
            confidence: 0.9, bucket: .main, status: .pending, promptVersion: "t",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 20 * 86_400)),
            updatedAt: now, senderLevel: nil, senderRole: nil, urgency: nil
        ))
        try store.upsertPendingAsk(PendingAsk(
            id: 0, msgUID: "live", chatUsername: "c", chatName: "C", senderName: "S",
            rawText: "新请求", summary: "新请求", askType: .none, deadlineAt: nil,
            confidence: 0.9, bucket: .main, status: .pending, promptVersion: "t",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff + 3_600)),
            updatedAt: now, senderLevel: nil, senderRole: nil, urgency: nil
        ))
        XCTAssertEqual(try store.archiveStalePendingAsks(cutoff: cutoff, now: now), 1)
        XCTAssertEqual(store.loadPendingAsks(status: .pending, relevantSince: cutoff).map(\.msgUID), ["live"])
        XCTAssertEqual(store.loadPendingAsks(status: .dismissed).map(\.msgUID), ["old"])
    }
}
