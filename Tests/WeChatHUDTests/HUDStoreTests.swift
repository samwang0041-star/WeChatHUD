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
        XCTAssertEqual(store.resolveAutopilotLogSent(id: logId), .consumedPending)
        // Reject lands late — must not flip a sent row, must not count.
        XCTAssertEqual(store.resolveAutopilotLogSkipped(id: logId), .wasNotPending)
        // Double-send resolution doesn't recount either.
        XCTAssertEqual(store.resolveAutopilotLogSent(id: logId), .wasNotPending)

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
        XCTAssertEqual(store.autopilotLogTwinState(queueId: qid), .open)
        let flipped = try store.markAutopilotLogPending(
            queueId: qid, chatUsername: "wxid_stall2", replyText: "好的"
        )
        XCTAssertEqual(flipped, 1)
        XCTAssertEqual(store.loadAutopilotLog(sessionId: sessionId)[0].action, .pending)
        XCTAssertEqual(store.autopilotLogTwinState(queueId: qid), .open)
        // Skip resolves it — no longer open.
        _ = try store.markAutopilotLogSkipped(
            queueId: qid, chatUsername: "wxid_stall2", replyText: "好的"
        )
        XCTAssertEqual(store.loadAutopilotLog(sessionId: sessionId)[0].action, .skipped)
        XCTAssertEqual(store.autopilotLogTwinState(queueId: qid), .resolved)
    }

    /// The gate that decides whether a failed send keeps its draft in the queue
    /// read `Bool` off a `try?`, so "the user rejected this" and "we could not
    /// read the row" were the same answer — and the draft vanished from the
    /// 待确认列表 for the rest of the session while its DB row stayed pending.
    func testTwinStateSeparatesUnreadableFromResolved() throws {
        let sessionId = try store.startAutopilotSession()
        let qid = UUID()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId,
            chatUsername: "wxid_twin", chatName: "Twin",
            senderUsername: "s", senderName: "S",
            triggerMsgUID: "mT", triggerText: "hi",
            generatedReply: "好的", confidence: 0.9,
            riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: qid.uuidString
        ))
        XCTAssertEqual(store.autopilotLogTwinState(queueId: qid), .open)
        // No twin row at all is a known answer, not an unreadable one.
        XCTAssertEqual(store.autopilotLogTwinState(queueId: UUID()), .resolved)

        try store.exec("DROP TABLE autopilot_log")
        XCTAssertEqual(
            store.autopilotLogTwinState(queueId: qid), .unreadable,
            "a failed query must not be reported as 'the user resolved this'"
        )
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

    /// The transaction is the whole point of the return value: `false` used to
    /// mean "not pending" and "the write failed" at once, so after a failed
    /// write the row stayed 'pending' in the database and 待确认回复 kept
    /// offering a reply that had already been sent.
    func testSentResolutionSeparatesWriteFailureFromNotPending() throws {
        let sessionId = try store.startAutopilotSession()
        XCTAssertEqual(
            store.resolveAutopilotLogSent(id: 999_999), .wasNotPending,
            "no such row is a known answer, not a failure"
        )
        try store.exec("DROP TABLE autopilot_log")
        XCTAssertEqual(
            store.resolveAutopilotLogSent(id: 1), .writeFailed,
            "读不到/写不回时必须报告失败，不能当成『已经不是待确认』"
        )
        _ = sessionId
    }

    /// The cancel side has to answer the same three questions, because a Bool
    /// answers two of them with the same `false`: when the 'skipped' write-back
    /// fails the row is still 'pending' in the database, 待确认回复 keeps offering
    /// it, and one tap sends to a real person the reply they had explicitly
    /// 取消了. Same defect as the send side, opposite direction.
    func testSkipResolutionSeparatesWriteFailureFromNotPending() throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "shard/Msg_s/1", triggerText: "结论有了吗",
            generatedReply: "我下午给你结论", confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        let logId = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: sessionId).first?.id,
            "fixture 没落库 ⇒ 这条测试什么都没验"
        )
        XCTAssertEqual(
            store.resolveAutopilotLogSkipped(id: logId), .consumedPending,
            "真的吃掉了一个 pending 行，这条判据才算数"
        )
        XCTAssertEqual(store.resolveAutopilotLogSkipped(id: logId), .wasNotPending,
                       "第二次取消不该再算一次")
        try store.exec("DROP TABLE autopilot_log")
        XCTAssertEqual(store.resolveAutopilotLogSkipped(id: logId), .writeFailed,
                       "写不回必须单独报失败，不能当成『已经不是待确认』")
    }

    /// `getWhitelist` answers `[]` for two different worlds, and the admission
    /// snapshot hands that `[]` to a verdict whose negative branch deletes work:
    /// one BUSY during `AdmissionRules.load` retired a whole batch of pending
    /// analysis instead of a single row.
    func testWhitelistAllReadSeparatesNobodyFollowedFromUnreadable() throws {
        if case .value(let empty) = store.whitelistAllRead() {
            XCTAssertTrue(empty.isEmpty, "没关注任何人时是空列表")
        } else {
            XCTFail("空表不是读失败")
        }
        try store.addToWhitelist(
            username: "wxid_here", displayName: "同事", isGroup: false, category: .work
        )
        if case .value(let entries) = store.whitelistAllRead() {
            XCTAssertEqual(entries.map(\.id), ["wxid_here"])
        } else {
            XCTFail("关注过就该原样读回来")
        }
        try store.exec("DROP TABLE whitelist")
        if case .unreadable = store.whitelistAllRead() {} else {
            XCTFail("表读不到时不许答『谁都没关注』")
        }
    }

    /// 水位读失败被当成「从没扫过」时，两条扫描链都会把水位直接基线到「最新一条」——
    /// 上次水位到最新之间的那段消息从此再也扫不到（无未回、无待办、不进托管），
    /// 而且没有任何地方说为什么。
    func testCursorReadSeparatesNeverScannedFromUnreadable() throws {
        if case .neverScanned = store.whitelistCursorRead(username: "wxid_never") {} else {
            XCTFail("没扫过的对话必须是 neverScanned，不能顺手算成读失败")
        }
        try store.setWhitelistCursor(username: "wxid_here", lastCreateTime: 1_780_000_000,
                                     lastLocalId: 42, lastShard: "Msg.db")
        switch store.whitelistCursorRead(username: "wxid_here") {
        case .value(let time, let localId, let shard):
            XCTAssertEqual(time, 1_780_000_000)
            XCTAssertEqual(localId, 42)
            XCTAssertEqual(shard, "Msg.db")
        default: XCTFail("写过的水位必须原样读回来")
        }
        // DEFAULT-0 from the migration means "no per-second id yet", not "unreadable".
        try store.setWhitelistCursor(username: "wxid_zero", lastCreateTime: 1_780_000_000,
                                     lastLocalId: 0, lastShard: "Msg.db")
        if case .value(_, let localId, _) = store.whitelistCursorRead(username: "wxid_zero") {
            XCTAssertEqual(localId, .max, "同一秒内的历史行不许被重放")
        } else { XCTFail("time>0 就是有一条水位") }

        try store.exec("DROP TABLE sync_state")
        if case .unreadable = store.whitelistCursorRead(username: "wxid_here") {} else {
            XCTFail("表读不到时必须单独报 unreadable —— 这是唯一能阻止水位前跳的信号")
        }
        if case .unreadable = store.autopilotCursorRead(username: "wxid_here") {} else {
            XCTFail("托管那条链同样要分得开")
        }
    }

    /// The store can tell the three apart; the scan has to act on it. Both
    /// watermark chains are gated, so a future third consumer that goes back to
    /// `getWhitelistCursor() == nil` shows up here instead of shipping.
    func testScanSkipsTheRoundWhenTheWatermarkCannotBeRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scan = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/Services/ScanEngine.swift"),
            encoding: .utf8
        )
        // 验的是「读不到」那个 if 的**体内**有没有跳过本轮：整段区间里别处的
        // `continue`（比如 `guard let messages = … else { continue }`）不算数——
        // 第一版这么写，第二条变异删掉真正的 continue 照样绿。
        // (读的那一句, 判读的那个 if) —— 白名单那条先把结果存进 `cursorRead`，
        // 所以两句的锚点不一样。
        for (read, anchor) in [
            ("store.whitelistCursorRead(username: entry.id)",
             "if case .unreadable = cursorRead"),
            ("store.autopilotCursorRead(username: session.username)",
             "if case .unreadable = store.autopilotCursorRead(username: session.username)"),
        ] {
            XCTAssertTrue(scan.contains(read), "这条水位链没再走三态读：\(read)")
            let body = try XCTUnwrap(
                Self.ifBody(of: scan, anchor: anchor),
                "找不到 \(anchor) 的分支体，判据不能零命中")
            XCTAssertTrue(body.contains("continue"), "\(anchor) 里面必须真的跳过本轮：\(body)")
        }
    }

    /// The braces of one `if`/`switch` body, matched by counting rather than by
    /// indentation: a slice that runs past the closing brace picks up unrelated
    /// statements and turns the gate green for the wrong reason.
    private static func ifBody(of source: String, anchor: String) -> String? {
        guard let found = source.range(of: anchor),
              let open = source[found.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var index = source.index(after: open)
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
                depth -= 1
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// 「没有活动会话」和「这次读不到会话」在旧写法里是同一个 nil，而
    /// clearAutopilotHistory 把 nil 读成「可以删」—— 一次 BUSY 就会在托管还活着时
    /// 清空整张历史表。谓词与接线都要验。
    func testSessionReadForTheHistoryInterlockReportsFailure() throws {
        let sessionId = try store.startAutopilotSession()
        XCTAssertNotNil(try store.currentAutopilotSessionThrowing())
        try store.exec("DROP TABLE autopilot_sessions")
        XCTAssertThrowsError(
            try store.currentAutopilotSessionThrowing(),
            "读不到活动会话时必须报错，不能答 nil"
        )
        XCTAssertNil(store.currentAutopilotSession(), "Bool 版本仍然只能答 nil，所以联锁不许用它")

        let source = try read("Sources/WeChatHUD/Data/HUDStore.swift")
        let clear = try XCTUnwrap(
            source.components(separatedBy: "func clearAutopilotHistory() throws {").last?
                .components(separatedBy: "\n    }").first,
            "找不到 clearAutopilotHistory，判据不能零命中")
        XCTAssertTrue(clear.contains("currentAutopilotSessionThrowing()"),
                      "安全联锁必须用会报错的那条读")
        XCTAssertFalse(clear.contains("currentAutopilotSession() == nil"),
                      "旧的那条读把读失败读成『可以删』")
        _ = sessionId
    }

    /// 日志孪干的 queue_id 读失败时，旧写法会掉进「按 (chat, 文本) 匹配」的 legacy
    /// 分支：删掉另一条同文本、无人认领的草稿，而真正该删的那条继续可发。
    func testQueueIdReadSeparatesLegacyNullFromUnreadable() throws {
        let sessionId = try store.startAutopilotSession()
        let queueId = UUID()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "shard/Msg_q/1", triggerText: "结论",
            generatedReply: "我下午给你结论", confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: queueId.uuidString
        ))
        let claimed = try XCTUnwrap(store.loadAutopilotLog(sessionId: sessionId).first?.id)
        if case .value(let qid) = store.autopilotLogQueueIdRead(id: claimed) {
            XCTAssertEqual(qid, queueId.uuidString)
        } else { XCTFail("认领过的孪干必须读得出来") }

        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "shard/Msg_q/2", triggerText: "结论二",
            generatedReply: "明天给你", confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        // 不能靠 `AutopilotLogEntry.queueId` 认行：解码器不填这个字段，两行都会是 nil。
        let legacy = store.loadAutopilotLog(sessionId: sessionId).map(\.id).first { $0 != claimed }
        if case .value(let qid) = store.autopilotLogQueueIdRead(id: try XCTUnwrap(legacy)) {
            XCTAssertNil(qid, "真的没有 queue_id 是合法答案，legacy 匹配就是为它留的")
        } else { XCTFail("NULL 不是读失败") }

        // 现在把日志表整个拿掉：读不到时宁可什么都不删。
        let sibling = PendingSend(
            chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1)
        )
        try store.upsertPendingSend(sibling, sessionId: sessionId)
        XCTAssertTrue(store.hasPendingSend(id: sibling.id))
        try store.exec("DROP TABLE autopilot_log")
        if case .unreadable = store.autopilotLogQueueIdRead(id: claimed) {} else {
            XCTFail("表读不到时必须单独报 unreadable")
        }
        XCTAssertThrowsError(
            try store.deletePendingSendForLog(
                logId: claimed, chatUsername: "wxid_peer", replyText: "我下午给你结论"),
            "读不到孪干时不许降级去删另一条"
        )
        XCTAssertTrue(store.hasPendingSend(id: sibling.id),
                      "另一条同文本的草稿不该被误删")
        // 上面那句被另一个信号满足了：日志表没了，legacy 文本匹配里的子查询自己就会
        // 抛错，所以「不再降级去匹配」这件事只能钉源码 —— 变异 O6 就是这么活的。
        let src = try read("Sources/WeChatHUD/Data/HUDStore.swift")
        let deleteFn = try XCTUnwrap(
            src.components(separatedBy: "func deletePendingSendForLog(").last?
                .components(separatedBy: "\n    }").first,
            "找不到 deletePendingSendForLog，判据不能零命中")
        let unreadableArm = try XCTUnwrap(
            deleteFn.components(separatedBy: "case .unreadable:").last,
            "unreadable 那一臂不见了")
        // 「紧跟 throw」会被注释挡掉（第一版就是这么假红的）：取到下一个 case 为止，
        // 要求这一段里真的有一条 throw 提前退出。
        let armBody = unreadableArm.components(separatedBy: "case ").first ?? unreadableArm
        XCTAssertTrue(armBody.contains("throw"),
                      "读不到孪干时必须停手，而不是掉进文本匹配：\(armBody)")
    }

    func testWhitelistReadSeparatesUnfollowedFromUnreadable() throws {
        XCTAssertEqual(store.whitelistRead("wxid_absent"), .unfollowed)
        try store.addToWhitelist(
            username: "wxid_here", displayName: "同事", isGroup: false, category: .work
        )
        XCTAssertEqual(store.whitelistRead("wxid_here"), .followed)
        XCTAssertTrue(store.isWhitelisted("wxid_here"))

        try store.exec("DROP TABLE whitelist")
        XCTAssertEqual(store.whitelistRead("wxid_here"), .unreadable)
        XCTAssertFalse(store.isWhitelisted("wxid_here"), "Bool 版本仍然只能回答 false，所以删除/退役队列的调用点不许用它")

        // The tri-state exists because of one caller: the classifier retired
        // (deleted) the queue row whenever the read answered false, so a single
        // BUSY error erased the only record that a message needed analysis —
        // no 待办, no badge, no 未回, nothing in the log.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/ChatMonitor+Classification.swift")
        let classifier = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(classifier.contains("store.isWhitelisted("),
                       "分类队列会在读失败时把消息当已处理删掉，必须走 whitelistRead 的三态")
        XCTAssertGreaterThanOrEqual(
            classifier.components(separatedBy: "deferClassificationMessage(").count - 1, 2,
            "读不到要退避重试；判据至少得看见两处调用点，否则是判据自己坏了"
        )
    }

    /// Same conflation, one level up, and this one bites on the *write* side: the
    /// settings page merged into `?? AutopilotConfig()` and saved the result, so a
    /// single busy lock during 保存 replaced 敏感词、每会话上限、主动提醒开关 — every
    /// guardrail the page does not show — with defaults, and printed 「设置已保存」.
    func testSettingReadSeparatesAbsentFromUnreadable() throws {
        if case .absent = store.readSettingJSON("autopilot", as: AutopilotConfig.self) {} else {
            XCTFail("没存过时该报 absent，否则首次保存没有合法的起点")
        }
        var tightened = AutopilotConfig()
        tightened.sensitiveKeywords = ["转账", "合同金额"]
        tightened.maxSendsPerSession = 3
        try store.setSettingJSON("autopilot", value: tightened)
        guard case .value(let read) = store.readSettingJSON("autopilot", as: AutopilotConfig.self)
        else { return XCTFail("存过的配置必须原样读回来") }
        XCTAssertEqual(read.sensitiveKeywords, ["转账", "合同金额"])
        XCTAssertEqual(read.maxSendsPerSession, 3)

        // Undecodable garbage is 「没有可合并的值」, not a read failure: refusing
        // to write then would leave the page unable to save anything, ever.
        try store.setSetting("autopilot", value: "{ not json")
        if case .absent = store.readSettingJSON("autopilot", as: AutopilotConfig.self) {} else {
            XCTFail("读得回来但解不开时，不许当成读失败把设置页锁死")
        }

        try store.exec("DROP TABLE settings")
        if case .unreadable = store.readSettingJSON("autopilot", as: AutopilotConfig.self) {} else {
            XCTFail("表读不到时必须报 unreadable，这是唯一能阻止合并写覆盖护栏的信号")
        }
    }

    /// The merge-write's contract: `false` means not one byte was written.
    func testAutopilotConfigMergeWriteRefusesAnUnreadableConfig() throws {
        // While the read works, the fields this page doesn't show survive a save
        // from it — that is the only reason the merge exists.
        var tightened = AutopilotConfig()
        tightened.sensitiveKeywords = ["转账", "合同金额"]
        tightened.maxSendsPerSession = 3
        tightened.autoSendEnabled = false
        try store.setSettingJSON("autopilot", value: tightened)
        XCTAssertTrue(try store.updateAutopilotConfig { $0.batchWindowSeconds = 25 })
        guard case .value(let after) = store.readSettingJSON("autopilot", as: AutopilotConfig.self)
        else { return XCTFail("这次读得回来") }
        XCTAssertEqual(after.batchWindowSeconds, 25)
        XCTAssertEqual(after.sensitiveKeywords, ["转账", "合同金额"],
                       "保存这页没显示的字段，不许被默认值盖掉")
        XCTAssertEqual(after.maxSendsPerSession, 3)

        // Once it doesn't work, nothing may be written — and no receipt either.
        var mutated = false
        try store.exec("DROP TABLE settings")
        XCTAssertFalse(try store.updateAutopilotConfig { cfg in
            cfg.autoSendEnabled = true
            mutated = true
        }, "读不回来就不该写")
        XCTAssertFalse(mutated, "连合并闭包都不该被调用")
    }

    /// The indexes are best-effort now; the version stamp must not advance over
    /// a failure, or the retry-on-next-launch that the comment relies on is
    /// gone and the database stays unindexed for good.
    func testRetrospectiveIndexMigrationReportsWhetherItLanded() throws {
        XCTAssertTrue(store.migrateToV3RetrospectiveIndexes())
        try store.exec("DROP TABLE review_todos")
        XCTAssertFalse(store.migrateToV3RetrospectiveIndexes())
    }
}
    private func read(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

