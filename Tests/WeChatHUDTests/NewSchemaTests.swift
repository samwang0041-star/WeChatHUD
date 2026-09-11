import XCTest
import SQLite3
@testable import WeChatHUD

final class NewSchemaTests: XCTestCase {
    var store: HUDStore!
    var tmpPath: String!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_schema_test_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // MARK: - Contacts

    func testContactUpsertAndGet() throws {
        try store.upsertContact(
            username: "wxid_boss",
            displayName: "林总",
            attentionLevel: .vip,
            role: .boss,
            roleNote: "直属上级",
            replyWindowMinutes: 30
        )

        let contact = store.getContact(username: "wxid_boss")
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact?.username, "wxid_boss")
        XCTAssertEqual(contact?.displayName, "林总")
        XCTAssertEqual(contact?.attentionLevel, .vip)
        XCTAssertEqual(contact?.role, .boss)
        XCTAssertEqual(contact?.roleNote, "直属上级")
        XCTAssertEqual(contact?.replyWindowMinutes, 30)
    }

    func testContactUpsertOverwrites() throws {
        try store.upsertContact(
            username: "wxid_alice",
            displayName: "Alice",
            attentionLevel: .whitelist,
            role: .colleague
        )
        try store.upsertContact(
            username: "wxid_alice",
            displayName: "Alice Wang",
            attentionLevel: .vip,
            role: .keyClient,
            roleNote: "upgraded"
        )
        let contact = store.getContact(username: "wxid_alice")
        XCTAssertEqual(contact?.displayName, "Alice Wang")
        XCTAssertEqual(contact?.attentionLevel, .vip)
        XCTAssertEqual(contact?.role, .keyClient)
        XCTAssertEqual(contact?.roleNote, "upgraded")
    }

    func testLoadContactsAll() throws {
        try store.upsertContact(username: "u1", displayName: "A", attentionLevel: .vip, role: .boss)
        try store.upsertContact(username: "u2", displayName: "B", attentionLevel: .whitelist, role: .colleague)
        try store.upsertContact(username: "u3", displayName: "C", attentionLevel: .stranger, role: .acquaintance)

        let all = store.loadContacts()
        XCTAssertEqual(all.count, 3)
    }

    func testLoadContactsWithLevelFilter() throws {
        try store.upsertContact(username: "u1", displayName: "VIP1", attentionLevel: .vip, role: .boss)
        try store.upsertContact(username: "u2", displayName: "VIP2", attentionLevel: .vip, role: .keyClient)
        try store.upsertContact(username: "u3", displayName: "WL1", attentionLevel: .whitelist, role: .colleague)

        let vips = store.loadContacts(level: .vip)
        XCTAssertEqual(vips.count, 2)
        for c in vips {
            XCTAssertEqual(c.attentionLevel, .vip)
        }

        let wl = store.loadContacts(level: .whitelist)
        XCTAssertEqual(wl.count, 1)
        XCTAssertEqual(wl[0].displayName, "WL1")
    }

    func testUpdateContactLevel() throws {
        try store.upsertContact(username: "wxid_x", displayName: "X", attentionLevel: .stranger, role: .acquaintance)
        try store.updateContactLevel(username: "wxid_x", level: .vip, role: .boss)

        let contact = store.getContact(username: "wxid_x")
        XCTAssertEqual(contact?.attentionLevel, .vip)
        XCTAssertEqual(contact?.role, .boss)
    }

    func testLoadVIPUsernames() throws {
        try store.upsertContact(username: "v1", displayName: "V1", attentionLevel: .vip, role: .boss)
        try store.upsertContact(username: "v2", displayName: "V2", attentionLevel: .vip, role: .keyClient)
        try store.upsertContact(username: "w1", displayName: "W1", attentionLevel: .whitelist, role: .colleague)

        let vips = store.loadVIPUsernames()
        XCTAssertEqual(vips, Set(["v1", "v2"]))
    }

    func testGetContactReturnsNilForMissing() {
        let contact = store.getContact(username: "nonexistent")
        XCTAssertNil(contact)
    }

    // MARK: - VIP Traces

    func testVIPTraceInsertAndLoad() throws {
        try store.insertVIPTrace(
            vipUsername: "wxid_boss",
            vipName: "林总",
            chatUsername: "room@chatroom",
            chatName: "项目群",
            msgUID: "msg-001",
            rawText: "明天开会",
            msgTime: 1000
        )

        let traces = store.loadVIPTraces(vipUsername: "wxid_boss")
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].vipName, "林总")
        XCTAssertEqual(traces[0].rawText, "明天开会")
        XCTAssertEqual(traces[0].msgTime, 1000)
        XCTAssertNil(traces[0].batchID)
    }

    func testVIPTraceDedupOnMsgUID() throws {
        try store.insertVIPTrace(
            vipUsername: "wxid_boss",
            vipName: "林总",
            chatUsername: "room@chatroom",
            chatName: "项目群",
            msgUID: "msg-dup",
            rawText: "first",
            msgTime: 1000
        )
        // Same msg_uid — should be silently ignored
        try store.insertVIPTrace(
            vipUsername: "wxid_boss",
            vipName: "林总",
            chatUsername: "room@chatroom",
            chatName: "项目群",
            msgUID: "msg-dup",
            rawText: "second",
            msgTime: 2000
        )

        let traces = store.loadVIPTraces(vipUsername: "wxid_boss")
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].rawText, "first")
    }

    func testLoadUnbatchedVIPTraces() throws {
        try store.insertVIPTrace(
            vipUsername: "wxid_boss", vipName: "Boss",
            chatUsername: "room", chatName: "Room",
            msgUID: "m1", rawText: "a", msgTime: 100
        )
        try store.insertVIPTrace(
            vipUsername: "wxid_boss", vipName: "Boss",
            chatUsername: "room", chatName: "Room",
            msgUID: "m2", rawText: "b", msgTime: 200
        )

        let unbatched = store.loadUnbatchedVIPTraces(vipUsername: "wxid_boss")
        XCTAssertEqual(unbatched.count, 2)
        // ASC order
        XCTAssertEqual(unbatched[0].msgUID, "m1")
        XCTAssertEqual(unbatched[1].msgUID, "m2")
    }

    func testMarkVIPTracesBatched() throws {
        try store.insertVIPTrace(
            vipUsername: "wxid_boss", vipName: "Boss",
            chatUsername: "room", chatName: "Room",
            msgUID: "m1", rawText: "a", msgTime: 100
        )
        try store.insertVIPTrace(
            vipUsername: "wxid_boss", vipName: "Boss",
            chatUsername: "room", chatName: "Room",
            msgUID: "m2", rawText: "b", msgTime: 200
        )

        let unbatched = store.loadUnbatchedVIPTraces(vipUsername: "wxid_boss")
        let ids = unbatched.map(\.id)
        try store.markVIPTracesBatched(ids: ids, batchID: "batch-001")

        let afterBatch = store.loadUnbatchedVIPTraces(vipUsername: "wxid_boss")
        XCTAssertEqual(afterBatch.count, 0)

        let all = store.loadVIPTraces(vipUsername: "wxid_boss")
        XCTAssertEqual(all.count, 2)
        for t in all {
            XCTAssertEqual(t.batchID, "batch-001")
        }
    }

    // MARK: - Recalled Messages

    func testRecalledMessageInsertAndLoad() throws {
        try store.insertRecalledMessage(
            msgUID: "recall-001",
            senderUsername: "wxid_alice",
            senderName: "Alice",
            senderLevel: .vip,
            senderRole: .keyClient,
            chatUsername: "room@chatroom",
            chatName: "项目群",
            chatType: .group,
            originalText: "价格可以再降一点",
            sentAt: 1000,
            recalledAt: 1060
        )

        let msgs = store.loadRecalledMessages()
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].msgUID, "recall-001")
        XCTAssertEqual(msgs[0].senderName, "Alice")
        XCTAssertEqual(msgs[0].senderLevel, .vip)
        XCTAssertEqual(msgs[0].chatType, .group)
        XCTAssertEqual(msgs[0].recallDelaySeconds, 60)
        XCTAssertNil(msgs[0].aiReason)
    }

    func testRecalledMessageDedupOnMsgUID() throws {
        try store.insertRecalledMessage(
            msgUID: "recall-dup",
            senderUsername: "wxid_a", senderName: "A",
            senderLevel: .whitelist, senderRole: .colleague,
            chatUsername: "room", chatName: "Room",
            chatType: .group, originalText: "first",
            sentAt: 100, recalledAt: 200
        )
        try store.insertRecalledMessage(
            msgUID: "recall-dup",
            senderUsername: "wxid_a", senderName: "A",
            senderLevel: .whitelist, senderRole: .colleague,
            chatUsername: "room", chatName: "Room",
            chatType: .group, originalText: "second",
            sentAt: 100, recalledAt: 200
        )

        let msgs = store.loadRecalledMessages()
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].originalText, "first")
    }

    func testUpdateRecallAnalysis() throws {
        try store.insertRecalledMessage(
            msgUID: "recall-analyze",
            senderUsername: "wxid_b", senderName: "B",
            senderLevel: .vip, senderRole: .boss,
            chatUsername: "wxid_b", chatName: "B",
            chatType: .privateChat, originalText: "这个方案不行",
            sentAt: 1000, recalledAt: 1010
        )

        try store.updateRecallAnalysis(
            msgUID: "recall-analyze",
            reason: "情绪性撤回",
            value: "领导对方案不满",
            detail: "可能需要修改方案后重新汇报",
            shouldNotify: true,
            notifyLevel: .strong
        )

        let msgs = store.loadRecalledMessages()
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].aiReason, "情绪性撤回")
        XCTAssertEqual(msgs[0].aiIntelligenceValue, "领导对方案不满")
        XCTAssertEqual(msgs[0].aiShouldNotify, true)
        XCTAssertEqual(msgs[0].aiNotifyLevel, .strong)
        XCTAssertNotNil(msgs[0].aiAnalyzedAt)
    }

    // MARK: - Commitments

    func testCommitmentUpsertAndLoad() throws {
        let deadline = Date(timeIntervalSince1970: 2000000)
        try store.upsertCommitment(
            msgUID: "commit-001",
            chatUsername: "wxid_boss",
            chatName: "林总",
            content: "明天发预算单",
            commitTo: "林总",
            deadlineAt: deadline,
            confidence: 0.92,
            promptVersion: "v1",
            sourceText: "好的，我明天发预算单",
            contextText: "林总要求补一版预算单",
            captureReason: "用户承诺明天交付预算单",
            nextStep: "整理预算单并发给林总",
            deadlineLabel: "明天前",
            commitmentKind: "deliverable"
        )

        let list = store.loadCommitments()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].msgUID, "commit-001")
        XCTAssertEqual(list[0].content, "明天发预算单")
        XCTAssertEqual(list[0].commitTo, "林总")
        XCTAssertEqual(list[0].confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(list[0].status, .pending)
        XCTAssertNotNil(list[0].deadlineAt)
        XCTAssertEqual(list[0].sourceText, "好的，我明天发预算单")
        XCTAssertEqual(list[0].contextText, "林总要求补一版预算单")
        XCTAssertEqual(list[0].captureReason, "用户承诺明天交付预算单")
        XCTAssertEqual(list[0].nextStep, "整理预算单并发给林总")
        XCTAssertEqual(list[0].deadlineLabel, "明天前")
        XCTAssertEqual(list[0].commitmentKind, "deliverable")
    }

    func testCommitmentUpsertUpdatesExisting() throws {
        try store.upsertCommitment(
            msgUID: "commit-upd",
            chatUsername: "room", chatName: "Room",
            content: "first version",
            commitTo: "A",
            confidence: 0.8,
            promptVersion: "v1"
        )
        try store.upsertCommitment(
            msgUID: "commit-upd",
            chatUsername: "room", chatName: "Room",
            content: "updated version",
            commitTo: "A",
            confidence: 0.95,
            promptVersion: "v2"
        )

        let list = store.loadCommitments()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].content, "updated version")
        XCTAssertEqual(list[0].confidence, 0.95, accuracy: 0.001)
    }

    func testUpdateCommitmentStatus() throws {
        try store.upsertCommitment(
            msgUID: "commit-status",
            chatUsername: "room", chatName: "Room",
            content: "deliver report",
            commitTo: "Boss",
            confidence: 0.9,
            promptVersion: "v1"
        )

        try store.updateCommitmentStatus(msgUID: "commit-status", status: .fulfilled)

        let fulfilled = store.loadCommitments(status: .fulfilled)
        XCTAssertEqual(fulfilled.count, 1)
        XCTAssertEqual(fulfilled[0].status, .fulfilled)

        let pending = store.loadCommitments(status: .pending)
        XCTAssertEqual(pending.count, 0)
    }

    func testLoadCommitmentsFilterByStatus() throws {
        try store.upsertCommitment(
            msgUID: "c1", chatUsername: "r", chatName: "R",
            content: "task1", commitTo: "A", confidence: 0.9, promptVersion: "v1"
        )
        try store.upsertCommitment(
            msgUID: "c2", chatUsername: "r", chatName: "R",
            content: "task2", commitTo: "B", confidence: 0.8, promptVersion: "v1"
        )
        try store.updateCommitmentStatus(msgUID: "c1", status: .overdue)

        let overdue = store.loadCommitments(status: .overdue)
        XCTAssertEqual(overdue.count, 1)
        XCTAssertEqual(overdue[0].msgUID, "c1")

        let all = store.loadCommitments()
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - PendingAsk with new fields

    func testPendingAskWithNewFields() throws {
        let now = Date()
        let ask = PendingAsk(
            id: 0,
            msgUID: "ask-new-fields",
            chatUsername: "wxid_boss",
            chatName: "林总",
            senderName: "林总",
            rawText: "明天开会",
            summary: "开会通知",
            askType: .schedule,
            deadlineAt: nil,
            confidence: 0.88,
            bucket: .main,
            status: .pending,
            promptVersion: "classifier_v4",
            createdAt: now,
            updatedAt: now,
            senderLevel: .vip,
            senderRole: .boss,
            urgency: .urgent
        )
        try store.upsertPendingAsk(ask)

        let loaded = store.loadPendingAsks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].senderLevel, .vip)
        XCTAssertEqual(loaded[0].senderRole, .boss)
        XCTAssertEqual(loaded[0].urgency, .urgent)
        XCTAssertEqual(loaded[0].askType, .schedule)
    }

    func testPendingAskWithNilNewFields() throws {
        let now = Date()
        let ask = PendingAsk(
            id: 0,
            msgUID: "ask-nil-fields",
            chatUsername: "wxid_test",
            chatName: "Test",
            senderName: "Tester",
            rawText: "hello",
            summary: "greeting",
            askType: .none,
            deadlineAt: nil,
            confidence: 0.5,
            bucket: .review,
            status: .pending,
            promptVersion: "v1",
            createdAt: now,
            updatedAt: now,
            senderLevel: nil,
            senderRole: nil,
            urgency: nil
        )
        try store.upsertPendingAsk(ask)

        let loaded = store.loadPendingAsks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].senderLevel)
        XCTAssertNil(loaded[0].senderRole)
        XCTAssertNil(loaded[0].urgency)
    }

    func testNewAskTypeCases() {
        XCTAssertEqual(AskType.schedule.label, "安排")
        XCTAssertEqual(AskType.action.label, "执行")
        XCTAssertEqual(AskType.schedule.rawValue, "schedule")
        XCTAssertEqual(AskType.action.rawValue, "action")
    }

    func testNewAIRoleCases() {
        XCTAssertEqual(AIRole.commitmentTracker.rawValue, "commitment_tracker")
        XCTAssertEqual(AIRole.contextAnalyzer.rawValue, "context_analyzer")
        XCTAssertEqual(AIRole.replyGenerator.rawValue, "reply_generator")
        XCTAssertEqual(AIRole.vipAggregator.rawValue, "vip_aggregator")
        XCTAssertEqual(AIRole.groupDigestor.rawValue, "group_digestor")
        XCTAssertEqual(AIRole.recallAnalyzer.rawValue, "recall_analyzer")
    }

    // MARK: - Role Configs

    func testSeedRoleConfigs() {
        let json = store.getSetting("role_configs")
        XCTAssertNotNil(json, "role_configs should be seeded on open()")
        let configs = store.getSettingJSON("role_configs", as: [String: RoleConfig].self)
        XCTAssertNotNil(configs)
        XCTAssertNotNil(configs?["boss"])
        XCTAssertEqual(configs?["boss"]?.replyWindow, 30)
        XCTAssertEqual(configs?["key_client"]?.replyWindow, 60)
    }

    // MARK: - Whitelist Migration

    /// Constructs the real pre-migration state: whitelist rows written by an
    /// older build, with no contacts rows.
    ///
    /// The previous version built its fixture with `addToWhitelist`, which
    /// already writes the contacts row using exactly the rules the migration
    /// applies. The migration's `getContact(...) == nil` guard was therefore
    /// false for every entry and the loop was a no-op — the test could not fail,
    /// and the upgrade path it claims to cover was never exercised.
    func testWhitelistMigrationToContacts() throws {
        try execMigrationFixture("""
            INSERT INTO whitelist(username, display_name, is_group, category,
                                  attention_level, added_at, auto_suggested)
            VALUES ('boss1', '王总', '0', 'work', 'vip', 1, 0),
                   ('coworker1', '李四', '0', 'work', 'watch', 1, 0),
                   ('friend1', '小红', '0', 'life', 'watch', 1, 0),
                   ('other1', '老同学', '0', 'other', 'watch', 1, 0);
            """)
        XCTAssertNil(store.getContact(username: "boss1"), "fixture must start without contacts rows")
        XCTAssertEqual(store.getWhitelist().count, 4)

        store.migrateWhitelistToContacts()

        let boss = store.getContact(username: "boss1")
        XCTAssertNotNil(boss)
        XCTAssertEqual(boss?.attentionLevel, .vip)
        XCTAssertEqual(boss?.role, .colleague) // default for work category
        XCTAssertEqual(boss?.displayName, "王总")

        let coworker = store.getContact(username: "coworker1")
        XCTAssertNotNil(coworker)
        XCTAssertEqual(coworker?.attentionLevel, .whitelist) // watch → whitelist

        let friend = store.getContact(username: "friend1")
        XCTAssertNotNil(friend)
        XCTAssertEqual(friend?.role, .friend) // life → friend

        XCTAssertEqual(store.getContact(username: "other1")?.role, .acquaintance)
    }

    /// The migration must not clobber a contact the user already configured.
    func testWhitelistMigrationKeepsExistingContactRow() throws {
        try store.upsertContact(
            username: "boss1",
            displayName: "王总",
            attentionLevel: .vip,
            role: .boss,
            roleNote: "直属上级",
            replyWindowMinutes: 15
        )
        try execMigrationFixture("""
            INSERT INTO whitelist(username, display_name, is_group, category,
                                  attention_level, added_at, auto_suggested)
            VALUES ('boss1', '王总', '0', 'work', 'watch', 1, 0);
            """)

        store.migrateWhitelistToContacts()

        XCTAssertEqual(store.getContact(username: "boss1")?.role, .boss)
        XCTAssertEqual(store.getContact(username: "boss1")?.replyWindowMinutes, 15)
    }

    /// Writes rows with raw SQL so the fixture can represent a database from a
    /// build that predates the contacts table's writers.
    private func execMigrationFixture(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(store.rawDB, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        guard result == SQLITE_OK else {
            throw NSError(domain: "NewSchemaTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "sqlite error"
            ])
        }
    }
}
