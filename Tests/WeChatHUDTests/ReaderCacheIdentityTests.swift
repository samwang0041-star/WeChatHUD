import XCTest
@testable import WeChatHUD

final class ReaderCacheIdentityTests: XCTestCase {
    func testDiagnosticMemoryReaderDoesNotPersistLearnedAliasesToInjectedDefaults() {
        let suiteName = "wechat-hud-diagnostic-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let reader = WeChatReader(dbDir: "/tmp/diagnostic-alias-test", cacheStrategy: .memory,
                                  persistLearnedAliases: false, userDefaults: defaults)
        reader.learnSelfAlias("synthetic-alias")
        XCTAssertTrue(reader.mySelfNames.contains("synthetic-alias"))
        XCTAssertNil(defaults.stringArray(forKey: "wchud.learnedSelfAliases." + WeChatReader.accountCacheIdentity("/tmp/diagnostic-alias-test")))
        let normal = WeChatReader(dbDir: "/tmp/diagnostic-alias-test", cacheStrategy: .memory,
                                  persistLearnedAliases: true, userDefaults: defaults)
        normal.learnSelfAlias("persisted-alias")
        XCTAssertEqual(defaults.stringArray(forKey: "wchud.learnedSelfAliases." + WeChatReader.accountCacheIdentity("/tmp/diagnostic-alias-test")), ["persisted-alias"])
    }
    func testAllCacheStrategiesSeparateAccounts() {
        for strategy in CacheStrategy.allCases {
            let first = WeChatReader.cacheDir(for: strategy, databaseRoot: "/accounts/alice/db_storage")
            let second = WeChatReader.cacheDir(for: strategy, databaseRoot: "/accounts/bob/db_storage")
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(first, WeChatReader.cacheDir(for: strategy, databaseRoot: "/accounts/alice/tmp/../db_storage"))
        }
    }

    func testDiscoveryReturnsEveryCandidateAndIgnoresRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for account in ["bob", "alice"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(account + "/db_storage"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("invalid"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("invalid/db_storage"))
        XCTAssertEqual(WeChatReader.databaseCandidates(baseDirectory: root.path),
                       [root.appendingPathComponent("alice/db_storage").path, root.appendingPathComponent("bob/db_storage").path])
    }
    func testSessionCacheIsPrivateAndRemovedOnRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let accountCache = WeChatReader.cacheDir(for: .memory, databaseRoot: root)
        defer { try? FileManager.default.removeItem(atPath: accountCache) }
        var reader: WeChatReader? = WeChatReader(dbDir: root, cacheStrategy: .memory)
        XCTAssertNotNil(reader)
        let children = try FileManager.default.contentsOfDirectory(atPath: accountCache)
        XCTAssertEqual(children.count, 1)
        let directory = accountCache + "/" + children[0]
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        reader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testAccessMaterialAvailabilityUsesConfiguredPathWithoutParsing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyPath = root.appendingPathComponent("access.json")
        let reader = WeChatReader(keysPath: keyPath.path, dbDir: root.path, cacheStrategy: .memory)
        XCTAssertEqual(reader.accessMaterialState, .missing)
        try Data("intentionally-not-a-key".utf8).write(to: keyPath)
        XCTAssertEqual(reader.accessMaterialState, .available)
        try FileManager.default.removeItem(at: keyPath)
        try FileManager.default.createDirectory(at: keyPath, withIntermediateDirectories: true)
        XCTAssertEqual(reader.accessMaterialState, .unreadable)
    }

    func testKeyFileValidationAcceptsOnlyNonEmptyJSONObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = root.appendingPathComponent("valid.json")
        try Data(#"{"db/session.db":{"enc_key":"00"}}"#.utf8).write(to: valid)
        XCTAssertTrue(WeChatReader.validateKeyFile(at: valid.path))

        let empty = root.appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        XCTAssertFalse(WeChatReader.validateKeyFile(at: empty.path))

        let array = root.appendingPathComponent("array.json")
        try Data("[]".utf8).write(to: array)
        XCTAssertFalse(WeChatReader.validateKeyFile(at: array.path))

        let malformed = root.appendingPathComponent("malformed.json")
        try Data("not-json".utf8).write(to: malformed)
        XCTAssertFalse(WeChatReader.validateKeyFile(at: malformed.path))
    }

    func testFindKeyPrefersCurrentAccountAndRefusesAmbiguousFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let aliceDir = root.appendingPathComponent("alice/db_storage")
        let carolDir = root.appendingPathComponent("carol/db_storage")
        try FileManager.default.createDirectory(at: aliceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: carolDir, withIntermediateDirectories: true)

        let keyA = Data(repeating: 0x11, count: 32)
        let keyB = Data(repeating: 0x22, count: 32)
        let hex: (Data) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        let json: [String: Any] = [
            "\(aliceDir.path)/message/message_0.db": ["enc_key": hex(keyA)],
            "\(root.path)/bob/db_storage/message/message_0.db": ["enc_key": hex(keyB)]
        ]
        let keysFile = root.appendingPathComponent("all_keys.json")
        try JSONSerialization.data(withJSONObject: json).write(to: keysFile)

        let alice = WeChatReader(keysPath: keysFile.path, dbDir: aliceDir.path, cacheStrategy: .memory)
        try alice.loadKeys()
        XCTAssertEqual(alice.findKey(for: "message/message_0.db"), keyA)

        let carol = WeChatReader(keysPath: keysFile.path, dbDir: carolDir.path, cacheStrategy: .memory)
        try carol.loadKeys()
        XCTAssertNil(carol.findKey(for: "message/message_0.db"))

        let onlyForeign = root.appendingPathComponent("only-foreign.json")
        try JSONSerialization.data(withJSONObject: [
            "\(root.path)/bob/db_storage/message/message_0.db": ["enc_key": hex(keyB)]
        ]).write(to: onlyForeign)
        let stranger = WeChatReader(keysPath: onlyForeign.path, dbDir: aliceDir.path, cacheStrategy: .memory)
        try stranger.loadKeys()
        XCTAssertNil(stranger.findKey(for: "message/message_0.db"))
    }

    func testFindKeyRefusesRelativeKeyWhenAnotherAccountIsNamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let aliceDir = root.appendingPathComponent("alice/db_storage")
        let carolDir = root.appendingPathComponent("carol/db_storage")
        try FileManager.default.createDirectory(at: aliceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: carolDir, withIntermediateDirectories: true)

        let keyA = Data(repeating: 0x33, count: 32)
        let keyB = Data(repeating: 0x44, count: 32)
        let hex: (Data) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        let shared = root.appendingPathComponent("shared.json")
        try JSONSerialization.data(withJSONObject: [
            "message/message_0.db": ["enc_key": hex(keyA)],
            "\(carolDir.path)/message/message_0.db": ["enc_key": hex(keyB)]
        ]).write(to: shared)

        let alice = WeChatReader(keysPath: shared.path, dbDir: aliceDir.path, cacheStrategy: .memory)
        try alice.loadKeys()
        XCTAssertNil(alice.findKey(for: "message/message_0.db"))

        let carol = WeChatReader(keysPath: shared.path, dbDir: carolDir.path, cacheStrategy: .memory)
        try carol.loadKeys()
        XCTAssertEqual(carol.findKey(for: "message/message_0.db"), keyB)

        let relativeOnly = root.appendingPathComponent("relative-only.json")
        try JSONSerialization.data(withJSONObject: [
            "message/message_0.db": ["enc_key": hex(keyA)]
        ]).write(to: relativeOnly)
        let solo = WeChatReader(keysPath: relativeOnly.path, dbDir: aliceDir.path, cacheStrategy: .memory)
        try solo.loadKeys()
        XCTAssertEqual(solo.findKey(for: "message/message_0.db"), keyA)
    }

}
