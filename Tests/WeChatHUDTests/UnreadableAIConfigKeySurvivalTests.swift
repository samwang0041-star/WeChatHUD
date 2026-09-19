import XCTest
@testable import WeChatHUD

/// `loadAIConfig()` falls back to `AIConfig()` when the stored blob cannot be
/// decoded at all. The audit read that as "the next settings toggle saves a
/// blank key with no ref, which `persistAIConfig` treats as an explicit clear
/// and deletes the Keychain item". This file settles whether that chain is
/// actually reachable, because the secret is the one thing in this database
/// that cannot be recovered by re-scanning anything.
final class UnreadableAIConfigKeySurvivalTests: XCTestCase {
    /// A fixture value, not a credential.
    private static let fixtureToken = "local-fixture-token"

    private var root: String!
    private var secrets: InMemorySecretStore!
    private var store: HUDStore!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ai-blob-\(UUID())"
        try FileManager.default.createDirectory(atPath: root!, withIntermediateDirectories: true)
        secrets = InMemorySecretStore()
        store = HUDStore(dbPath: root! + "/hud.sqlite3", secretStore: secrets)
        try store.open()
    }

    override func tearDown() {
        store?.close()
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func persistRealKey() throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom", baseURL: "https://api.example.com",
            model: "m", apiKey: Self.fixtureToken
        )
        try store.persistAIConfig(cfg)
    }

    private func storedRaw() throws -> String {
        try XCTUnwrap(store.getSetting("ai"))
    }

    /// What the settings screen sees after the blob becomes unreadable, and
    /// what it writes back when the user toggles something unrelated.
    func testCorruptBlobThenUnrelatedToggleKeepsTheKey() throws {
        try persistRealKey()
        var corrupted = try storedRaw()
        corrupted += ",,truncated"
        try store.setSetting("ai", value: corrupted)
        XCTAssertNil(store.getSettingJSON("ai", as: AIConfig.self), "the fixture must be unreadable")

        let asTheScreenSeesIt = store.loadAIConfig()
        try store.persistAIConfig(asTheScreenSeesIt)

        XCTAssertEqual(
            try secrets.load(account: HUDStore.defaultAIKeyAccount), Self.fixtureToken,
            "a corrupt read must never be able to spend the only copy of the key"
        )
    }

    /// An explicit clear by the user still has to work: the protection above is
    /// about a corrupt read not spending the key, not about making the key
    /// impossible to remove.
    func testUserStillCanClearTheKey() throws {
        try persistRealKey()
        var cleared = store.loadAIConfig()
        cleared.provider.apiKey = ""
        cleared.provider.keychainItemRef = nil
        try store.persistAIConfig(cleared)

        XCTAssertNil(try secrets.load(account: HUDStore.defaultAIKeyAccount))
    }
}
