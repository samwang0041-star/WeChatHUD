import XCTest
@testable import WeChatHUD

/// The settings blobs under `settings.sync` / `settings.notification` /
/// `settings.update` are copied forward verbatim by the device-settings
/// migration, so a machine that alternates between app versions hands the
/// newer build a blob that predates fields the newer build declares as
/// non-optional. The synthesized decoder rejects the *whole* blob for one
/// missing key, every read site collapses to `?? Config()`, and for
/// `SyncConfig` that silently un-selects the WeChat account.
final class PersistedConfigCompatibilityTests: XCTestCase {

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

    // MARK: - SyncConfig

    func testSyncBlobFromBeforeDisplayScreenExistedKeepsTheSelectedAccount() throws {
        let legacy = #"{"intervalSeconds":15,"wechatDBPath":"/x/alice/db_storage","keysFilePath":"/x/keys.json","cacheStrategy":"memory"}"#
        let config = try JSONDecoder().decode(SyncConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.wechatDBPath, "/x/alice/db_storage")
        XCTAssertEqual(config.intervalSeconds, 15)
        XCTAssertEqual(config.keysFilePath, "/x/keys.json")
        XCTAssertEqual(config.cacheStrategy, .memory)
        XCTAssertEqual(config.displayScreen, .builtIn, "the one missing key falls back, not the whole blob")
    }

    func testUnreadableEnumValuesFallBackPerKey() throws {
        let raw = #"{"wechatDBPath":"/x/alice/db_storage","cacheStrategy":"quantum","displayScreen":"retina","intervalSeconds":"thirty"}"#
        let config = try JSONDecoder().decode(SyncConfig.self, from: Data(raw.utf8))
        XCTAssertEqual(config.wechatDBPath, "/x/alice/db_storage")
        XCTAssertEqual(config.cacheStrategy, .temporary)
        XCTAssertEqual(config.displayScreen, .builtIn)
        XCTAssertEqual(config.intervalSeconds, 30)
    }

    func testCurrentShapeStillRoundTripsEveryField() throws {
        let original = SyncConfig(
            intervalSeconds: 45,
            wechatDBPath: "/x/bob/db_storage",
            keysFilePath: "/x/k.json",
            cacheStrategy: .persistent,
            displayScreen: .external
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SyncConfig.self, from: data), original)
    }

    /// The end-to-end shape of the bug: the legacy store's `sync` blob is
    /// copied verbatim into device settings on first launch, so a blob written
    /// before `displayScreen` existed reached bootstrap as an unreadable blob,
    /// decoded to `SyncConfig()` → "auto" → no root with two installs on the
    /// machine → `accounts/unconfigured/hud.sqlite3`, and the user's whitelist
    /// disappeared from the UI.
    func testBootstrapKeepsTheAccountWhenTheMigratedBlobPredatesANewField() throws {
        let legacyPath = coordinator.supportDirectory.appendingPathComponent("hud.sqlite3").path
        let old = HUDStore(dbPath: legacyPath)
        try old.open()
        try old.setSetting("sync", value:
            #"{"intervalSeconds":30,"wechatDBPath":"\#(accountA!)","keysFilePath":null,"cacheStrategy":"temporary"}"#)
        try old.addToWhitelist(username: "chat-1", displayName: "Alice", isGroup: false, category: .work)

        let boot = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        defer { boot.store.close() }
        XCTAssertEqual(boot.storePath, legacyPath)
        XCTAssertEqual(boot.store.getWhitelist().map(\.displayName), ["Alice"],
                       "the user's data must still be the data on screen")
    }

    /// A corrupt blob is not a missing blob. Defaulting it would open a fresh
    /// empty store next to the user's real one, so bootstrap stops instead —
    /// the same policy the other unreadable-state paths in this type use.
    func testBootstrapRefusesToGuessAnAccountFromACorruptSyncBlob() throws {
        let legacyPath = coordinator.supportDirectory.appendingPathComponent("hud.sqlite3").path
        let old = HUDStore(dbPath: legacyPath)
        try old.open()
        var seeded = SyncConfig()
        seeded.wechatDBPath = accountA
        try old.setSettingJSON("sync", value: seeded)
        try old.addToWhitelist(username: "chat-1", displayName: "Alice", isGroup: false, category: .work)

        let boot = try coordinator.bootstrap(databaseCandidates: [accountA, accountB])
        boot.store.close()

        let device = try DeviceSettingsStore(path: coordinator.supportDirectory.appendingPathComponent("device-settings.json"))
        try device.set("sync", value: #"{"wechatDBPath":"#)

        XCTAssertThrowsError(try coordinator.bootstrap(databaseCandidates: [accountA, accountB]))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: coordinator.supportDirectory
                    .appendingPathComponent("accounts/unconfigured/hud.sqlite3").path),
            "an unreadable config must never mint an empty store"
        )
    }

    /// The refusal has to come *before* the legacy copies are deleted.
    /// Refusing after the delete left the user's other four settings in exactly
    /// one place — the device file — and the only way out of the resulting
    /// launch failure was to delete that file, which then reseeded factory
    /// defaults from a legacy table that had already been emptied. One corrupt
    /// blob must never be able to cost the rest of the configuration.
    func testUnreadableSyncRefusalLeavesTheOtherLegacySettingsInPlace() throws {
        let legacyPath = coordinator.supportDirectory.appendingPathComponent("hud.sqlite3").path
        let old = HUDStore(dbPath: legacyPath)
        try old.open()
        try old.setSetting("sync", value: #"{"wechatDBPath":"#)
        try old.setSetting("notification", value: #"{"atMention":false,"important":false}"#)
        try old.addToWhitelist(username: "chat-1", displayName: "Alice", isGroup: false, category: .work)

        XCTAssertThrowsError(try coordinator.bootstrap(databaseCandidates: [accountA, accountB]))

        let reopened = HUDStore(dbPath: legacyPath)
        try reopened.open()
        defer { reopened.close() }
        XCTAssertEqual(
            reopened.getSetting("notification"),
            #"{"atMention":false,"important":false}"#,
            "the refusal must not have consumed the settings it was protecting"
        )
    }

    // MARK: - NotificationConfig

    func testNotificationBlobMissingANewerSwitchKeepsTheOnesTheUserSet() throws {
        let legacy = #"{"atMention":false,"important":false}"#
        let config = try JSONDecoder().decode(NotificationConfig.self, from: Data(legacy.utf8))
        XCTAssertFalse(config.atMention)
        XCTAssertFalse(config.important)
        XCTAssertFalse(config.allWhitelist)
        XCTAssertEqual(config.durationSeconds, 3)
    }

    // MARK: - AppUpdateConfig

    func testUpdateConfigDropsOnlyAnUnreadableOffer() throws {
        let raw = #"{"autoCheckEnabled":false,"autoInstallEnabled":true,"repository":"me/repo","pendingOffer":"not-an-object"}"#
        let config = try JSONDecoder().decode(AppUpdateConfig.self, from: Data(raw.utf8))
        XCTAssertFalse(config.autoCheckEnabled)
        XCTAssertTrue(config.autoInstallEnabled)
        XCTAssertEqual(config.repository, "me/repo")
        XCTAssertNil(config.pendingOffer)
    }
}
