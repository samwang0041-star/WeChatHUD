import XCTest
import SQLite3
@testable import WeChatHUD

final class AccountStoreCoordinatorTests: XCTestCase {
    private var root: URL!
    private var coordinator: AccountStoreCoordinator!
    private var accountA: String!
    private var accountB: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        accountA = root.appendingPathComponent("wechat/alice/db_storage").path
        accountB = root.appendingPathComponent("wechat/bob/db_storage").path
        for path in [accountA!, accountB!] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        coordinator = AccountStoreCoordinator(supportDirectory: root.appendingPathComponent("support"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func seedLegacy(path: String) throws -> String {
        let legacyPath = coordinator.supportDirectory.appendingPathComponent("hud.sqlite3").path
        let old = HUDStore(dbPath: legacyPath)
        try old.open()
        defer { old.close() }
        var config = SyncConfig()
        config.wechatDBPath = path
        try old.setSettingJSON("sync", value: config)
        try old.addToWhitelist(username: "same-chat", displayName: "Alice's contact", isGroup: false, category: .work)
        try old.setSetting("composer_draft:same-chat", value: "Alice's confidential draft")
        try old.setSetting("autopilot", value: "account-specific-policy")
        try old.setWhitelistCursor(username: "same-chat", lastCreateTime: 100, lastLocalId: 9)
        try old.upsertConversationMemory(ConversationMemory(
            chatUsername: "same-chat", summary: "Alice's memory", keyTopics: [], pendingItems: [],
            sharedContext: [], communicationNotes: [], moodTrend: "", conversationPhase: "", stance: "",
            messageCount7d: 1, lastUpdated: Date()))
        try old.upsertCommitment(msgUID: "old-commitment", chatUsername: "same-chat", chatName: "Alice",
                                 content: "Alice's task", commitTo: "Alice", confidence: 1, promptVersion: "test")
        try old.enqueueClassificationMessages([MessageInfo(
            id: "old-queue-message", localId: 1, chatUsername: "same-chat", chatName: "Alice",
            senderUsername: "sender", senderName: "sender", text: "Alice's source", baseType: 1,
            subType: 0, createTime: 100)])
        return legacyPath
    }

    func testReadOnlyDoesNotCreateSupportFilesOrBusinessStore() throws {
        let support = coordinator.supportDirectory
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        let result = try coordinator.readOnly(databaseCandidates: [accountA])
        defer { result.store?.close() }
        XCTAssertNil(result.store)
        XCTAssertEqual(result.databaseRoot, URL(fileURLWithPath: accountA).standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("device-settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("accounts").path))
    }

    private func staticLegacy() throws -> (String, SyncConfig) {
        let path = coordinator.supportDirectory.appendingPathComponent("hud.sqlite3").path
        try FileManager.default.createDirectory(at: coordinator.supportDirectory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        var config = SyncConfig()
        config.wechatDBPath = accountA
        config.keysFilePath = root.appendingPathComponent("custom-keys.json").path
        let raw = String(data: try JSONEncoder().encode(config), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO settings VALUES('sync','\(raw)'); INSERT INTO settings VALUES('sentinel','unchanged')", nil, nil, nil), SQLITE_OK)
        return (path, config)
    }

    func testReadOnlyReadsExistingStoreFromSnapshotWithoutChangingSource() throws {
        let (path, config) = try staticLegacy()
        let fm = FileManager.default
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let fallback = try coordinator.readOnly(databaseCandidates: [accountB])
        XCTAssertEqual(fallback.databaseRoot, accountA)
        XCTAssertEqual(fallback.syncConfig.keysFilePath, config.keysFilePath)
        XCTAssertFalse(fm.fileExists(atPath: coordinator.supportDirectory.appendingPathComponent("device-settings.json").path))
        // Explicitly bind the fixture, then verify actual snapshot reads.
        let device = try DeviceSettingsStore(path: coordinator.supportDirectory.appendingPathComponent("device-settings.json"))
        try device.initializeIfNeeded(legacySettings: ["sync": String(data: try JSONEncoder().encode(config), encoding: .utf8)!], legacyAccountRoot: accountA)
        let names = try fm.contentsOfDirectory(atPath: coordinator.supportDirectory.path)
        let tempBefore = Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path).filter { $0.hasPrefix("wechat-hud-diagnostic-") })
        let result = try coordinator.readOnly(databaseCandidates: [accountB])
        let store = try XCTUnwrap(result.store)
        XCTAssertEqual(store.getSetting("sentinel"), "unchanged")
        store.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: coordinator.supportDirectory.path), names)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path).filter { $0.hasPrefix("wechat-hud-diagnostic-") }), tempBefore)
    }

    func testReadOnlySkipsBusinessStoreWithLiveWAL() throws {
        let (path, config) = try staticLegacy()
        let wal = URL(fileURLWithPath: path + "-wal")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: wal)
        XCTAssertThrowsError(try coordinator.readOnly(databaseCandidates: [accountA]))
        let device = try DeviceSettingsStore(path: coordinator.supportDirectory.appendingPathComponent("device-settings.json"))
        try device.initializeIfNeeded(legacySettings: ["sync": String(data: try JSONEncoder().encode(config), encoding: .utf8)!], legacyAccountRoot: accountA)
        let result = try coordinator.readOnly(databaseCandidates: [accountB])
        XCTAssertNil(result.store)
        XCTAssertEqual(result.databaseRoot, accountA)
        XCTAssertEqual(try Data(contentsOf: wal), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))
        try device.set("sync", value: "invalid-json")
        XCTAssertThrowsError(try coordinator.readOnly(databaseCandidates: [accountB]))
    }

    func testFirstLaunchPreservesLegacyAndReturningAccountRestoresItsData() throws {
        let legacyPath = try seedLegacy(path: accountA)
        let first = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        XCTAssertEqual(first.storePath, legacyPath)
        XCTAssertEqual(first.store.deviceSettings?.legacyStoreStatus, .bound)
        XCTAssertEqual(first.store.getWhitelist().count, 1)
        var config = first.store.getSettingJSON("sync", as: SyncConfig.self)!
        config.wechatDBPath = accountB
        try first.store.setSettingJSON("sync", value: config)
        first.store.close()

        let second = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        XCTAssertNotEqual(second.storePath, legacyPath)
        XCTAssertEqual(second.databaseRoot, accountB)
        XCTAssertTrue(second.store.getWhitelist().isEmpty)
        XCTAssertNil(second.store.getSetting("composer_draft:same-chat"))
        XCTAssertNil(second.store.getSetting("autopilot"))
        XCTAssertNil(second.store.getWhitelistCursor(username: "same-chat"))
        XCTAssertNil(second.store.loadConversationMemory(chatUsername: "same-chat"))
        XCTAssertTrue(second.store.loadCommitments().isEmpty)
        XCTAssertEqual(second.store.classificationQueueCount(), 0)
        try second.store.setSetting("composer_draft:same-chat", value: "Bob's own draft")
        config.wechatDBPath = accountA
        try second.store.setSettingJSON("sync", value: config)
        second.store.close()

        let returning = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        defer { returning.store.close() }
        XCTAssertEqual(returning.storePath, legacyPath)
        XCTAssertEqual(returning.store.getSetting("composer_draft:same-chat"), "Alice's confidential draft")
        XCTAssertEqual(returning.store.getSetting("autopilot"), "account-specific-policy")
        XCTAssertEqual(returning.store.getWhitelistCursor(username: "same-chat")?.lastLocalId, 9)
        XCTAssertEqual(returning.store.loadConversationMemory(chatUsername: "same-chat")?.summary, "Alice's memory")
        XCTAssertEqual(returning.store.loadCommitments().count, 1)
        XCTAssertEqual(returning.store.classificationQueueCount(), 1)
    }

    func testRestartRemembersExplicitSelectionAndSharesOnlyDevicePreferences() throws {
        _ = try seedLegacy(path: accountA)
        let first = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        var config = SyncConfig()
        config.wechatDBPath = accountB
        try first.store.setSettingJSON("sync", value: config)
        var ai = AIConfig()
        ai.provider.model = "device-model"
        try first.store.setSettingJSON("ai", value: ai)
        first.store.close()
        // A newly created coordinator represents a process restart.
        let restarted = try AccountStoreCoordinator(supportDirectory: coordinator.supportDirectory)
            .bootstrap(databaseCandidates: [accountB, accountA])
        defer { restarted.store.close() }
        XCTAssertEqual(restarted.databaseRoot, accountB)
        XCTAssertEqual(restarted.store.loadAIConfig().provider.model, "device-model")
        XCTAssertEqual(restarted.store.getSettingJSON("sync", as: SyncConfig.self)?.wechatDBPath, accountB)
        XCTAssertTrue(restarted.store.getWhitelist().isEmpty)
    }

    func testRestartPreservesConfiguredKeyFilePath() throws {
        let first = try coordinator.bootstrap(databaseCandidates: [accountA])
        var config = SyncConfig()
        config.wechatDBPath = accountA
        config.keysFilePath = root.appendingPathComponent("keys.json").path
        try first.store.setSettingJSON("sync", value: config)
        first.store.close()

        let restarted = try AccountStoreCoordinator(supportDirectory: coordinator.supportDirectory)
            .bootstrap(databaseCandidates: [accountA])
        defer { restarted.store.close() }
        XCTAssertEqual(restarted.store.getSettingJSON("sync", as: SyncConfig.self)?.keysFilePath, config.keysFilePath)
    }

    func testUnconfiguredOrAmbiguousLegacyIsNeverAssignedToLaterAccount() throws {
        let legacyPath = try seedLegacy(path: "auto")
        let first = try coordinator.bootstrap(databaseCandidates: [])
        XCTAssertNil(first.databaseRoot)
        XCTAssertEqual(first.store.deviceSettings?.legacyStoreStatus, .needsAccountConfirmation)
        XCTAssertEqual(first.store.deviceSettings?.legacyStoreURL.path, legacyPath)
        XCTAssertNotEqual(first.storePath, legacyPath)
        XCTAssertTrue(first.store.getWhitelist().isEmpty)
        var config = SyncConfig()
        config.wechatDBPath = accountB
        try first.store.setSettingJSON("sync", value: config)
        first.store.close()
        let selected = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        defer { selected.store.close() }
        XCTAssertNotEqual(selected.storePath, legacyPath)
        XCTAssertTrue(selected.store.getWhitelist().isEmpty)
        let preserved = HUDStore(dbPath: legacyPath)
        try preserved.open()
        defer { preserved.close() }
        XCTAssertEqual(preserved.getWhitelist().count, 1)
        XCTAssertEqual(preserved.getSetting("composer_draft:same-chat"), "Alice's confidential draft")
        XCTAssertNil(AccountStoreCoordinator.selectedRoot(configuredPath: "auto", candidates: [accountA, accountB]))
    }

    func testExplicitConfirmationBindsLegacyToTheConfirmedAccount() throws {
        _ = try seedLegacy(path: "auto")
        let unconfigured = try coordinator.bootstrap(databaseCandidates: [])
        XCTAssertEqual(unconfigured.store.deviceSettings?.legacyStoreStatus, .needsAccountConfirmation)
        unconfigured.store.close()

        let selected = try coordinator.bootstrap(databaseCandidates: [accountB])
        let device = try XCTUnwrap(selected.store.deviceSettings)
        XCTAssertTrue(selected.store.getWhitelist().isEmpty)
        var sync = selected.store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()
        sync.wechatDBPath = accountB
        try selected.store.setSettingJSON("sync", value: sync)
        try device.confirmLegacyAccountIdentity(expectedRoot: accountB)
        XCTAssertEqual(device.legacyStoreStatus, .bound)
        XCTAssertThrowsError(try device.confirmLegacyAccountIdentity(expectedRoot: accountA))
        selected.store.close()

        let restarted = try coordinator.bootstrap(databaseCandidates: [accountB, accountA])
        defer { restarted.store.close() }
        XCTAssertEqual(restarted.databaseRoot, accountB)
        XCTAssertEqual(restarted.storePath, coordinator.supportDirectory.appendingPathComponent("hud.sqlite3").path)
        XCTAssertEqual(restarted.store.getWhitelist().count, 1)
        XCTAssertEqual(restarted.store.classificationQueueCount(), 1)
    }

    func testLegacyConfirmationFailureDoesNotBindInMemoryAndRetryCanSucceed() throws {
        let devicePath = root.appendingPathComponent("device-settings.json")
        let device = try DeviceSettingsStore(path: devicePath)
        try device.initializeIfNeeded(legacySettings: [:], legacyAccountRoot: nil)

        // A directory at the destination makes the atomic rename fail after the
        // candidate document has been fully staged, exercising the persist error path.
        try FileManager.default.removeItem(at: devicePath)
        try FileManager.default.createDirectory(at: devicePath, withIntermediateDirectories: true)
        XCTAssertThrowsError(try device.confirmLegacyAccountIdentity(expectedRoot: accountB))
        XCTAssertNil(device.legacyAccountIdentity)

        try FileManager.default.removeItem(at: devicePath)
        try device.confirmLegacyAccountIdentity(expectedRoot: accountB)
        XCTAssertEqual(device.legacyAccountIdentity, WeChatReader.accountCacheIdentity(accountB))

        let restarted = try DeviceSettingsStore(path: devicePath)
        XCTAssertEqual(restarted.legacyAccountIdentity, WeChatReader.accountCacheIdentity(accountB))
    }

    func testInvalidDeviceStateFailsInsteadOfFallingBackToAnotherAccount() throws {
        try FileManager.default.createDirectory(at: coordinator.supportDirectory, withIntermediateDirectories: true)
        try Data("broken-json".utf8).write(to: coordinator.supportDirectory.appendingPathComponent("device-settings.json"))
        XCTAssertThrowsError(try coordinator.bootstrap(databaseCandidates: [accountA]))
    }
    func testAutoLegacyDoesNotBelongToTheOnlyRemainingDifferentAccount() throws {
        let legacyPath = try seedLegacy(path: "auto")
        // A's old source directory disappears; B is now the only discoverable account.
        try FileManager.default.removeItem(atPath: accountA)
        let selected = try coordinator.bootstrap(databaseCandidates: [accountB])
        defer { selected.store.close() }
        XCTAssertEqual(selected.databaseRoot, accountB)
        XCTAssertNotEqual(selected.storePath, legacyPath)
        XCTAssertTrue(selected.store.getWhitelist().isEmpty)
        XCTAssertNil(selected.store.getSetting("composer_draft:same-chat"))
        XCTAssertEqual(selected.store.classificationQueueCount(), 0)
        let preserved = HUDStore(dbPath: legacyPath)
        try preserved.open()
        defer { preserved.close() }
        XCTAssertEqual(preserved.getWhitelist().count, 1)
        XCTAssertEqual(preserved.getSetting("composer_draft:same-chat"), "Alice's confidential draft")
        XCTAssertEqual(preserved.classificationQueueCount(), 1)
    }

    func testNoLegacyDatabaseHasNoRecoveryNotice() throws {
        let first = try coordinator.bootstrap(databaseCandidates: [accountA])
        defer { first.store.close() }
        XCTAssertEqual(first.store.deviceSettings?.legacyStoreStatus, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.store.deviceSettings!.legacyStoreURL.path))
    }

}
