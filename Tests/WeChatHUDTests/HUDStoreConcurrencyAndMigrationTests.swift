import XCTest
@testable import WeChatHUD

final class HUDStoreConcurrencyAndMigrationTests: XCTestCase {
    func testFreshStoreIsAtCurrentSchemaVersion() throws {
        let path = NSTemporaryDirectory() + "hud_schema_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertEqual(store.schemaUserVersion(), SchemaMigrator.currentVersion)
        XCTAssertFalse(store.loadDailyInsightPoints().contains { !$0.day.isEmpty && $0.chatUsername.isEmpty })
    }

    func testMigratingUserVersionZeroIsIdempotent() throws {
        let path = NSTemporaryDirectory() + "hud_schema_v0_\(UUID().uuidString).sqlite3"
        let first = HUDStore(dbPath: path)
        try first.open()
        first.setSchemaUserVersion(0)
        XCTAssertEqual(first.schemaUserVersion(), 0)
        first.close()

        let second = HUDStore(dbPath: path)
        try second.open()
        defer {
            second.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertEqual(second.schemaUserVersion(), SchemaMigrator.currentVersion)
        try SchemaMigrator.apply(to: second)
        XCTAssertEqual(second.schemaUserVersion(), SchemaMigrator.currentVersion)

        try second.upsertDailyInsightPoint(DailyInsightPoint(
            chatUsername: "wxid_a",
            day: "2026-09-01",
            headline: "hello",
            topics: ["排期"],
            decisions: [],
            waitingCount: 1,
            overallMood: "正式",
            messageCount: 4,
            myMessageCount: 1,
            insight: "等你"
        ))
        XCTAssertEqual(second.loadDailyInsightPoints(chatUsername: "wxid_a").count, 1)
    }

    func testConcurrentSettingsAuditAndCacheWritesDoNotCorrupt() throws {
        let path = NSTemporaryDirectory() + "hud_stress_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        let iterations = 80
        let workers = 8

        for worker in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    for step in 0..<iterations {
                        try store.setSetting("k\(worker)", value: "v\(step)")
                        _ = store.getSetting("k\(worker)")
                        try store.writeAIAudit(AIAuditEntry(
                            id: 0, ts: Date(), role: .classifier, model: "m",
                            promptVersion: "v1", inputText: "in \(worker)-\(step)",
                            outputText: "out", latencyMs: 1, status: .ok, errorMessage: nil
                        ))
                        try store.writeAnalysisCache(
                            chatUsername: "c\(worker)",
                            analysisType: "t",
                            inputHash: "h\(step)",
                            result: "{\"ok\":true}",
                            ttlHours: 2
                        )
                        _ = store.loadAnalysisCache(
                            chatUsername: "c\(worker)",
                            analysisType: "t",
                            inputHash: "h\(step)"
                        )
                    }
                } catch {
                    lock.lock()
                    failures.append("\(error)")
                    lock.unlock()
                }
            }
        }

        let waited = group.wait(timeout: .now() + 30)
        XCTAssertEqual(waited, .success, "mixed read/write stress timed out")
        XCTAssertTrue(failures.isEmpty, "SQLite stress failed: \(failures)")
        XCTAssertEqual(store.getSetting("k0"), "v\(iterations - 1)")
        XCTAssertFalse(store.loadRecentAIAudit(limit: 20).isEmpty)
    }

    func testConcurrentWhitelistSyncContactsAndRadarDoNotCorrupt() throws {
        let path = NSTemporaryDirectory() + "hud_serial_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        let iterations = 40
        let workers = 6

        for worker in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let username = "wxid_\(worker)"
                    for step in 0..<iterations {
                        try store.addToWhitelist(
                            username: username,
                            displayName: "联系人\(worker)",
                            isGroup: false,
                            category: .other,
                            attentionLevel: .watch
                        )
                        _ = store.isWhitelisted(username)
                        _ = store.getWhitelist()
                        _ = store.getWhitelistEntry(username: username)
                        _ = store.hasWhitelistEntries()
                        try store.setWhitelistCursor(username: username, lastCreateTime: 1_700_000_000 + step, lastLocalId: step)
                        _ = store.getWhitelistCursor(username: username)
                        _ = store.getSyncState("wl/\(username)")
                        _ = store.loadVIPUsernames()
                        _ = store.getContact(username: username)
                        _ = store.loadContacts()
                        try store.upsertDailyInsightPoint(DailyInsightPoint(
                            chatUsername: username,
                            day: String(format: "2026-08-%02d", (step % 9) + 1),
                            headline: "h",
                            topics: ["t"],
                            decisions: [],
                            waitingCount: step % 3,
                            overallMood: "正式",
                            messageCount: 4,
                            myMessageCount: 1,
                            insight: "i"
                        ))
                        _ = try RelationshipRadarService.refresh(store: store, chatUsername: username, now: Date(timeIntervalSince1970: 1_757_000_000))
                        _ = store.loadChatActions()
                    }
                } catch {
                    lock.lock()
                    failures.append("\(error)")
                    lock.unlock()
                }
            }
        }

        let waited = group.wait(timeout: .now() + 30)
        XCTAssertEqual(waited, .success, "serial-queue stress timed out")
        XCTAssertTrue(failures.isEmpty, "serial-queue stress failed: \(failures)")
        XCTAssertEqual(store.whitelistCount(), workers)
        XCTAssertTrue(store.isWhitelisted("wxid_0"))
        XCTAssertNotNil(store.getWhitelistCursor(username: "wxid_0"))
        XCTAssertEqual(store.loadDailyInsightChatUsernames().count, workers)
    }

    func testSchemaV3AddsRetrospectiveIndexes() throws {
        let path = NSTemporaryDirectory() + "hud_schema_v3_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertEqual(store.schemaUserVersion(), SchemaMigrator.currentVersion)
        let names = store.queryAll(
            "SELECT name FROM sqlite_master WHERE type='index'",
            bind: { _ in },
            decode: { stmt in HUDStore.textColumn(stmt, 0) }
        )
        XCTAssertTrue(names.contains("idx_red_banner_dismissals_todo_created"))
        XCTAssertTrue(names.contains("idx_review_todos_status_created"))
    }

    func testSchemaUpgradesFromV2ToV3Indexes() throws {
        let path = NSTemporaryDirectory() + "hud_schema_v2_\(UUID().uuidString).sqlite3"
        let first = HUDStore(dbPath: path)
        try first.open()
        first.setSchemaUserVersion(2)
        XCTAssertEqual(first.schemaUserVersion(), 2)
        first.close()

        let second = HUDStore(dbPath: path)
        try second.open()
        defer {
            second.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertEqual(second.schemaUserVersion(), SchemaMigrator.currentVersion)
        let names = second.queryAll(
            "SELECT name FROM sqlite_master WHERE type='index'",
            bind: { _ in },
            decode: { stmt in HUDStore.textColumn(stmt, 0) }
        )
        XCTAssertTrue(names.contains("idx_red_banner_dismissals_todo_created"))
        XCTAssertTrue(names.contains("idx_review_todos_status_created"))
    }
}

// MARK: - Round-2 regression coverage

extension HUDStoreConcurrencyAndMigrationTests {

    /// `close()` must finalize cached statements and close the connection in
    /// one serial-queue section — and `open()` must produce a usable store
    /// again afterwards (the old code could leave the statement cache
    //  pointing at a finalized connection).
    func testCloseThenOpenYieldsAWorkingStore() throws {
        let path = NSTemporaryDirectory() + "hud_reopen_\(UUID().uuidString).sqlite3"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HUDStore(dbPath: path)
        try store.open()
        try store.setSetting("roundtrip", value: "one")
        XCTAssertEqual(store.getSetting("roundtrip"), "one")
        store.close()
        // Re-open must not inherit a tombstoned connection or stale cache.
        try store.open()
        defer { store.close() }
        XCTAssertEqual(store.getSetting("roundtrip"), "one")
        try store.setSetting("roundtrip", value: "two")
        XCTAssertEqual(store.getSetting("roundtrip"), "two")
    }

    /// Commitment analysis is claimed with a bounded attempt count: a mark
    /// survives failure (dedup), but the row allows up to `maxAttempts`
    /// claims before permanently suppressing — so a transient AI failure
    /// retries instead of silently dropping the commitment forever.
    func testCommitmentAnalysisClaimIsBoundedNotOneShot() throws {
        let path = NSTemporaryDirectory() + "hud_claim_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        // First three claims are granted (attempts 1..3); the fourth is denied.
        XCTAssertTrue(store.markCommitmentAnalyzedIfNew(msgUID: "uid-x", maxAttempts: 3))
        XCTAssertTrue(store.markCommitmentAnalyzedIfNew(msgUID: "uid-x", maxAttempts: 3))
        XCTAssertTrue(store.markCommitmentAnalyzedIfNew(msgUID: "uid-x", maxAttempts: 3))
        XCTAssertFalse(store.markCommitmentAnalyzedIfNew(msgUID: "uid-x", maxAttempts: 3))
        // A different uid is independent.
        XCTAssertTrue(store.markCommitmentAnalyzedIfNew(msgUID: "uid-y", maxAttempts: 3))
    }

    /// A poison row in the classification queue must be quarantined — a
    /// permanently-undecodable row must not wedge every newer message.
    func testClassificationQueuePoisonRowIsQuarantined() throws {
        let path = NSTemporaryDirectory() + "hud_poison_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        // Insert a malformed payload directly so decoding cannot succeed.
        try store.exec(
            "INSERT INTO classification_queue(msg_uid, payload, source_timestamp) VALUES(?, ?, ?)",
            params: ["poison-1", "not-a-json-payload{{{", "1"]
        )
        let healthy = MessageInfo(
            id: "m1", localId: 1, chatUsername: "c", chatName: "c",
            senderUsername: "p", senderName: "p", text: "ok",
            baseType: 1, subType: 0, createTime: 1
        )
        try store.enqueueClassificationMessages([healthy])
        let pending = store.pendingClassificationMessages(limit: 10)
        XCTAssertEqual(pending.map(\.id), ["m1"],
                       "the healthy row must survive; the poison row is quarantined")
        // The poison row is gone — it cannot re-block the next drain.
        XCTAssertEqual(store.classificationQueueCount(), 1)
    }
}
