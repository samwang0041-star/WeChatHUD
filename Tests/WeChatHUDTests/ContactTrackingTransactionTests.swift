import XCTest
import SQLite3
@testable import WeChatHUD

final class ContactTrackingTransactionTests: XCTestCase {
    private var stores: [HUDStore] = []
    private var storePaths: [String] = []

    override func tearDown() {
        stores.forEach { $0.close() }
        for path in storePaths {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        stores.removeAll()
        storePaths.removeAll()
        super.tearDown()
    }

    func testSaveContactTrackingRollsBackProfileWhenTrackingInsertAborts() throws {
        let store = try makeStore()
        try store.upsertContact(username: "wxid_abort", displayName: "旧名称", attentionLevel: .greylist, role: .friend)
        try exec(store, """
            CREATE TRIGGER abort_contact_tracking BEFORE INSERT ON whitelist
            WHEN NEW.username = 'wxid_abort'
            BEGIN SELECT RAISE(ABORT, 'forced tracking failure'); END;
        """)

        XCTAssertThrowsError(try store.saveContactTracking(
            username: "wxid_abort",
            displayName: "新名称",
            isGroup: false,
            category: .life,
            attentionLevel: .vip,
            role: .boss
        ))

        XCTAssertEqual(store.getContact(username: "wxid_abort")?.displayName, "旧名称")
        XCTAssertEqual(store.getContact(username: "wxid_abort")?.attentionLevel, .greylist)
        XCTAssertFalse(store.isWhitelisted("wxid_abort"))
    }

    func testDeleteContactAndTrackingRollsBackEveryTableWhenProfileDeleteAborts() throws {
        let store = try makeStore()
        try store.saveContactTracking(
            username: "wxid_delete",
            displayName: "待删除",
            isGroup: false,
            category: .work,
            attentionLevel: .vip,
            role: .colleague
        )
        try store.setWhitelistCursor(username: "wxid_delete", lastCreateTime: 10, lastLocalId: 2)
        try store.snoozeChat(chatUsername: "wxid_delete", until: 999_999)
        try exec(store, """
            INSERT INTO relationship_profiles(
                username, display_name, relationship, hierarchy, tone_preference,
                context, confidence, user_note, user_edited, inferred_at, updated_at
            ) VALUES ('wxid_delete', '待删除', 'friend', 'peer', 'casual', '', 0.8, '', 0, 1, 1);
            CREATE TRIGGER abort_profile_delete BEFORE DELETE ON relationship_profiles
            WHEN OLD.username = 'wxid_delete'
            BEGIN SELECT RAISE(ABORT, 'forced delete failure'); END;
        """)

        XCTAssertThrowsError(try store.deleteContactAndTracking(username: "wxid_delete"))

        XCTAssertNotNil(store.getContact(username: "wxid_delete"))
        XCTAssertTrue(store.isWhitelisted("wxid_delete"))
        XCTAssertNotNil(store.getWhitelistCursor(username: "wxid_delete"))
        XCTAssertNotNil(store.loadChatActions()["wxid_delete"])
        XCTAssertNotNil(store.getRelationshipProfile(username: "wxid_delete"))
    }

    func testSuccessfulSaveAndDeleteKeepContactAndTrackingTablesConsistent() throws {
        let store = try makeStore()
        try store.saveContactTracking(
            username: "wxid_consistent",
            displayName: "一致",
            isGroup: true,
            category: .other,
            attentionLevel: .vip,
            role: .keyClient
        )
        XCTAssertNotNil(store.getContact(username: "wxid_consistent"))
        XCTAssertTrue(store.isWhitelisted("wxid_consistent"))

        try store.saveContactTracking(
            username: "wxid_consistent",
            displayName: "一致",
            isGroup: true,
            category: .other,
            attentionLevel: .greylist,
            role: .acquaintance
        )
        XCTAssertNotNil(store.getContact(username: "wxid_consistent"))
        XCTAssertFalse(store.isWhitelisted("wxid_consistent"))

        try store.deleteContactAndTracking(username: "wxid_consistent")
        XCTAssertNil(store.getContact(username: "wxid_consistent"))
        XCTAssertFalse(store.isWhitelisted("wxid_consistent"))
        XCTAssertNil(store.getWhitelistCursor(username: "wxid_consistent"))
        XCTAssertNil(store.loadChatActions()["wxid_consistent"])
    }

    func testTransactionMutexCoversTheWholeSynchronousTransaction() throws {
        let store = try makeStore()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { firstFinished.signal() }
            _ = try? store.withTransaction {
                try store.upsertContact(username: "wxid_first", displayName: "一", attentionLevel: .vip, role: .friend)
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                try store.upsertContact(username: "wxid_first_done", displayName: "二", attentionLevel: .vip, role: .friend)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.upsertContact(username: "wxid_second", displayName: "三", attentionLevel: .vip, role: .friend)
            secondFinished.signal()
        }

        // The second writer must wait for the first transaction's COMMIT,
        // rather than entering between its two writes.
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNotNil(store.getContact(username: "wxid_first_done"))
        XCTAssertNotNil(store.getContact(username: "wxid_second"))
    }

    func testNestedFailureRollsBackSavepointWithoutRollingBackOuterTransaction() throws {
        let store = try makeStore()
        try store.withTransaction {
            try store.upsertContact(username: "wxid_outer_before", displayName: "外层前", attentionLevel: .vip, role: .friend)
            XCTAssertThrowsError(try store.withTransaction {
                try store.upsertContact(username: "wxid_nested", displayName: "嵌套", attentionLevel: .vip, role: .friend)
                throw HUDStoreError.sqlError("forced nested failure")
            })
            try store.upsertContact(username: "wxid_outer_after", displayName: "外层后", attentionLevel: .vip, role: .friend)
        }

        XCTAssertNotNil(store.getContact(username: "wxid_outer_before"))
        XCTAssertNotNil(store.getContact(username: "wxid_outer_after"))
        XCTAssertNil(store.getContact(username: "wxid_nested"))
    }

    func testLedgerFailureUsesSavepointAndCannotCommitOrRollbackOuterTransaction() throws {
        let store = try makeStore()
        try exec(store, """
            CREATE TRIGGER abort_ledger_insert BEFORE INSERT ON ai_data_ledger
            BEGIN SELECT RAISE(ABORT, 'forced ledger failure'); END;
        """)

        try store.withTransaction {
            store.recordLedgerBatch([ledgerEntry()])
            try store.upsertContact(username: "wxid_after_ledger", displayName: "外层仍在", attentionLevel: .vip, role: .friend)
        }

        XCTAssertNotNil(store.getContact(username: "wxid_after_ledger"))
        XCTAssertTrue(store.recentLedger(days: 7).isEmpty)
    }

    private func makeStore() throws -> HUDStore {
        let path = "/tmp/wechathud-contact-transaction-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        stores.append(store)
        storePaths.append(path)
        return store
    }

    private func ledgerEntry() -> AILedgerEntry {
        AILedgerEntry(
            id: 0, ts: Date(), provider: "test", model: "test",
            purpose: .chatAnalysis, chatCount: 1, msgCount: 1,
            byteCount: 1, tokenIn: nil, tokenOut: nil, redacted: true
        )
    }

    private func exec(_ store: HUDStore, _ sql: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(store.rawDB, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(result)"
            XCTFail(message, file: file, line: line)
            throw HUDStoreError.sqlError(message)
        }
    }
}
