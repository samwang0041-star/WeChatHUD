import XCTest
@testable import WeChatHUD

final class SecurityRegressionTests: XCTestCase {
    private var tmpPath: String!
    private var secrets: InMemorySecretStore!
    private var store: HUDStore!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_security_\(UUID().uuidString).sqlite3"
        secrets = InMemorySecretStore()
        store = HUDStore(dbPath: tmpPath, secretStore: secrets)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testPersistAIConfigMovesKeyToSecretStoreAndStripsSQLite() throws {
        var cfg = store.loadAIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKey: "sk-live-secret-xyz"
        )
        try store.setSettingJSON("ai", value: cfg)

        let raw = try XCTUnwrap(store.persistedAIConfigJSON())
        XCTAssertFalse(raw.contains("sk-live-secret-xyz"), "SQLite must not keep the API key")
        XCTAssertTrue(raw.contains("keychainItemRef") || raw.contains(HUDStore.defaultAIKeyAccount))

        let loaded = store.loadAIConfig()
        XCTAssertEqual(loaded.provider.apiKey, "sk-live-secret-xyz")
        XCTAssertEqual(try secrets.load(account: HUDStore.defaultAIKeyAccount), "sk-live-secret-xyz")
    }

    func testTwoPhaseMigrationLeavesPlaintextIfReadbackFails() throws {
        try store.setSetting("ai", value: """
        {"provider":{"providerID":"custom","baseURL":"https://api.example.com","model":"m","apiKey":"sk-plain-keep"}}
        """)
        let failing = FailingReadbackStore()
        let otherPath = NSTemporaryDirectory() + "hud_security_fail_\(UUID().uuidString).sqlite3"
        let other = HUDStore(dbPath: otherPath, secretStore: failing)
        try other.open()
        defer {
            other.close()
            try? FileManager.default.removeItem(atPath: otherPath)
        }
        try other.setSetting("ai", value: """
        {"provider":{"providerID":"custom","baseURL":"https://api.example.com","model":"m","apiKey":"sk-plain-keep"}}
        """)
        XCTAssertFalse(other.migratePlaintextAPIKeysToKeychain())
        XCTAssertTrue(try XCTUnwrap(other.persistedAIConfigJSON()).contains("sk-plain-keep"))
    }

    func testTwoPhaseMigrationClearsPlaintextAfterVerifiedWrite() throws {
        try store.setSetting("ai", value: """
        {"provider":{"providerID":"custom","baseURL":"https://api.example.com","model":"m","apiKey":"sk-plain-migrate"}}
        """)
        XCTAssertTrue(store.migratePlaintextAPIKeysToKeychain())
        let raw = try XCTUnwrap(store.persistedAIConfigJSON())
        XCTAssertFalse(raw.contains("sk-plain-migrate"))
        XCTAssertEqual(store.loadAIConfig().provider.apiKey, "sk-plain-migrate")
    }

    func testRemoteCleartextHTTPIsRejectedAndLoopbackIsAllowed() {
        XCTAssertThrowsError(try AIEndpointPolicy.validateNormalizedBaseURL("http://api.openai.com/v1")) { error in
            guard case AIError.insecureCleartext = error as? AIError else {
                return XCTFail("expected insecureCleartext, got \(error)")
            }
        }
        XCTAssertThrowsError(try AIEndpointPolicy.validateNormalizedBaseURL("http://10.0.0.8/v1"))
        XCTAssertNoThrow(try AIEndpointPolicy.validateNormalizedBaseURL("http://127.0.0.1:11434/v1"))
        XCTAssertNoThrow(try AIEndpointPolicy.validateNormalizedBaseURL("http://localhost:8000/v1"))
        XCTAssertNoThrow(try AIEndpointPolicy.validateNormalizedBaseURL("http://[::1]:11434/v1"))
        XCTAssertNoThrow(try AIEndpointPolicy.validateNormalizedBaseURL("https://api.openai.com/v1"))
    }

    func testSettingsValidationRejectsRemoteHTTP() {
        let remote = AIProviderSlot(baseURL: "http://api.openai.com/v1", model: "gpt")
        XCTAssertEqual(
            AISettingsValidation.connectionError(remote, requireModel: true),
            "远程 AI 接口必须使用 https://。仅本机（localhost / 127.0.0.1 / ::1）允许 http://"
        )
        let local = AIProviderSlot(baseURL: "http://127.0.0.1:11434/v1", model: "local-model")
        XCTAssertNil(AISettingsValidation.connectionError(local, requireModel: true))
    }

    func testAIAuditDefaultWriteIsRedactedSnippetAndHash() throws {
        let phone = "请回 13800138000"
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .classifier, model: "m", promptVersion: "v1",
            inputText: phone, outputText: "ok", latencyMs: 1, status: .ok, errorMessage: nil
        ))
        let loaded = try XCTUnwrap(store.loadRecentAIAudit(limit: 1).first)
        XCTAssertFalse(loaded.inputText.contains("13800138000"))
        XCTAssertTrue(loaded.inputText.contains("sha256:"))
        XCTAssertTrue(loaded.inputText.contains("[手机]") || loaded.inputText.contains("请回"))
        XCTAssertEqual(AIAuditPrivacy.sha256Hex(phone).count, 64)
    }

    func testSecureFileManagerUsesOwnerOnlyModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-perms-\(UUID().uuidString)")
        let file = root.appendingPathComponent("hud.sqlite3")
        XCTAssertTrue(SecureFileManager.ensureDirectory(at: root.path))
        XCTAssertEqual(SecureFileManager.posixMode(at: root.path), 0o700)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)))
        XCTAssertTrue(SecureFileManager.ensureFilePermissions(at: file.path))
        XCTAssertEqual(SecureFileManager.posixMode(at: file.path), 0o600)
        try? FileManager.default.removeItem(at: root)
    }

    func testHUDStoreHardensItsOwnDatabaseFile() {
        XCTAssertEqual(SecureFileManager.posixMode(at: tmpPath), 0o600)
    }

    func testEmptyKeyWithExistingRefDoesNotDeleteSecret() throws {
        var cfg = store.loadAIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "https://api.example.com",
            model: "m",
            apiKey: "sk-keep-me",
            keychainItemRef: HUDStore.defaultAIKeyAccount
        )
        try store.persistAIConfig(cfg)

        var roundTrip = store.loadAIConfig()
        XCTAssertEqual(roundTrip.provider.apiKey, "sk-keep-me")
        roundTrip.provider.apiKey = ""
        try store.persistAIConfig(roundTrip)
        XCTAssertEqual(store.loadAIConfig().provider.apiKey, "sk-keep-me")
        XCTAssertEqual(try secrets.load(account: HUDStore.defaultAIKeyAccount), "sk-keep-me")
    }

    func testAIServiceSendRejectsRemoteCleartextBeforeNetwork() async {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://api.openai.com/v1",
            model: "gpt",
            apiKey: "sk-must-not-leave"
        )
        let service = AIService(config: cfg)
        do {
            _ = try await service.complete(system: "s", user: "u")
            XCTFail("remote http must fail closed")
        } catch {
            guard case AIError.insecureCleartext = error as? AIError else {
                return XCTFail("expected insecureCleartext, got \(error)")
            }
        }
    }
}

private final class FailingReadbackStore: SecretStore {
    func save(account: String, secret: String) throws {}
    func load(account: String) throws -> String? { "not-the-secret" }
    func delete(account: String) throws {}
}
