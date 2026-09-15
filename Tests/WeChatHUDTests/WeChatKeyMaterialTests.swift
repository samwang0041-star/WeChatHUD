import XCTest
@testable import WeChatHUD

/// Gates for the key-material shapes the reader accepts.
///
/// The behaviour these lock down was, until now, a silent failure. `loadKeys`
/// matched one shape and `continue`d past every other one, so a key file in an
/// unrecognised format loaded **zero** keys and the reader then reported "no key
/// for this database". The user reads that as "my key is wrong" and goes looking
/// for a new one, when nothing was ever wrong with the key they had.
final class WeChatKeyMaterialTests: XCTestCase {

    private let keyHex = String(repeating: "ab", count: 32)
    private let saltHex = String(repeating: "7f", count: 16)

    private func makeTempDirectory(name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechathud-keys-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: - Entry shapes

    /// The shape this project writes: an object carrying `enc_key`.
    func testObjectEntryWithEncKeyIsAccepted() {
        let data = WeChatKeyMaterial.keyData(from: ["enc_key": keyHex])
        XCTAssertEqual(data?.count, 32)
    }

    /// The other public convention spells the same field `key`.
    func testObjectEntryWithKeyAliasIsAccepted() {
        XCTAssertEqual(WeChatKeyMaterial.keyData(from: ["key": keyHex])?.count, 32)
    }

    /// A bare hex string is a whole entry in the path-map convention.
    ///
    /// This is the shape that used to be skipped entirely: `value as?
    /// [String: Any]` failed for a String, and the entry vanished without a
    /// trace.
    func testBareHexStringEntryIsAccepted() {
        XCTAssertEqual(WeChatKeyMaterial.keyData(from: keyHex)?.count, 32)
    }

    func testUppercaseHexIsAcceptedAndLowercasedByDecoding() {
        let upper = keyHex.uppercased()
        XCTAssertEqual(WeChatKeyMaterial.keyData(from: upper)?.count, 32)
    }

    /// Wrong-length values must be rejected here, not later as a decrypt error.
    ///
    /// A 96-hex `enc_key + salt` value is the case that matters: it is a real
    /// string a user could plausibly have, and it would otherwise load as a key
    /// that can never match.
    func testWrongLengthKeysAreRejected() {
        XCTAssertNil(WeChatKeyMaterial.keyData(from: String(repeating: "ab", count: 48)))
        XCTAssertNil(WeChatKeyMaterial.keyData(from: String(repeating: "ab", count: 16)))
        XCTAssertNil(WeChatKeyMaterial.keyData(from: ["enc_key": "not-hex"]))
        XCTAssertNil(WeChatKeyMaterial.keyData(from: 42))
        XCTAssertNil(WeChatKeyMaterial.keyData(from: ["unrelated": keyHex]))
    }

    func testEnvelopeKeysAreNotTreatedAsDatabasePaths() {
        XCTAssertTrue(WeChatKeyMaterial.isEnvelopeKey("_comment"))
        XCTAssertTrue(WeChatKeyMaterial.isEnvelopeKey("schema_version"))
        XCTAssertTrue(WeChatKeyMaterial.isEnvelopeKey("keys"))
        XCTAssertFalse(WeChatKeyMaterial.isEnvelopeKey("message/message_0.db"))
    }

    // MARK: - Salt map

    func testSchema2SaltMapIsParsed() {
        let json: [String: Any] = [
            "schema_version": 2,
            "keys": [saltHex: keyHex]
        ]
        let map = WeChatKeyMaterial.saltMap(from: json)
        XCTAssertEqual(map?.keys.count, 1)
        XCTAssertEqual(map?.keys[saltHex]?.count, 32)
        XCTAssertEqual(map?.rejectedEntries, 0)
    }

    /// `schema_version` is accepted as a string too: JSON carries no type
    /// distinction, and a writer emitting "2" means the same thing as 2.
    func testSchemaVersionAcceptsStringSpelling() {
        let json: [String: Any] = ["schema_version": "2", "keys": [saltHex: keyHex]]
        XCTAssertEqual(WeChatKeyMaterial.saltMap(from: json)?.keys.count, 1)
    }

    /// A path map must not be mistaken for a salt map.
    ///
    /// Its top-level `keys` would have to be absent, and its entries are
    /// objects keyed by path rather than bare strings keyed by salt — so the
    /// salt parser must decline the file and leave it to the path parser.
    func testPathMapIsNotClaimedAsASaltMap() {
        let json: [String: Any] = ["message/message_0.db": ["enc_key": keyHex]]
        XCTAssertNil(WeChatKeyMaterial.saltMap(from: json))
    }

    func testSaltMapWithoutSchemaVersionIsDeclined() {
        XCTAssertNil(WeChatKeyMaterial.saltMap(from: ["keys": [saltHex: keyHex]]))
    }

    /// Partially-usable material is reported as partial, not as fine.
    func testMalformedSaltEntriesAreCountedNotIgnored() {
        let json: [String: Any] = [
            "schema_version": 2,
            "keys": [saltHex: keyHex, "zz": keyHex, String(repeating: "0", count: 32): "short"]
        ]
        let map = WeChatKeyMaterial.saltMap(from: json)
        XCTAssertEqual(map?.keys.count, 1)
        XCTAssertEqual(map?.rejectedEntries, 2)
    }

    func testSaltValidationEnforcesLengthAndHex() {
        XCTAssertEqual(WeChatKeyMaterial.normalizedSalt(saltHex), saltHex)
        XCTAssertEqual(WeChatKeyMaterial.normalizedSalt(saltHex.uppercased()), saltHex)
        XCTAssertNil(WeChatKeyMaterial.normalizedSalt(String(repeating: "7f", count: 8)))
        XCTAssertNil(WeChatKeyMaterial.normalizedSalt(String(repeating: "zz", count: 16)))
    }

    // MARK: - Reader integration

    /// A bare-string path map now loads, where it used to load nothing.
    func testReaderLoadsBareStringPathMap() throws {
        let dir = try makeTempDirectory(name: "bare")
        let keysPath = dir + "/all_keys.json"
        let json: [String: Any] = ["message/message_0.db": keyHex]
        try Data(try JSONSerialization.data(withJSONObject: json)).write(to: URL(fileURLWithPath: keysPath))

        let reader = WeChatReader(keysPath: keysPath, dbDir: dir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)
        XCTAssertEqual(reader.recognizedKeyEntryCount, 1)
        XCTAssertEqual(reader.rejectedKeyEntryCount, 0)
        XCTAssertEqual(reader.findKey(for: "message/message_0.db")?.count, 32)
    }

    /// The state that used to be invisible: a file whose entries are all in an
    /// unread shape reports zero recognised and a non-zero rejected count, so
    /// onboarding can say "unrecognised format" instead of "no key".
    func testUnrecognizableKeyFileIsReportedRatherThanSilentlyEmpty() throws {
        let dir = try makeTempDirectory(name: "weird")
        let keysPath = dir + "/all_keys.json"
        let json: [String: Any] = ["message/message_0.db": ["something_else": "x"]]
        try Data(try JSONSerialization.data(withJSONObject: json)).write(to: URL(fileURLWithPath: keysPath))

        let reader = WeChatReader(keysPath: keysPath, dbDir: dir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)
        XCTAssertEqual(reader.recognizedKeyEntryCount, 0)
        XCTAssertEqual(reader.rejectedKeyEntryCount, 1)
        XCTAssertNil(reader.findKey(for: "message/message_0.db"))
    }

    /// Salt-addressed lookup: the database carries no usable path entry, so the
    /// key is found by the salt in its own first 16 bytes.
    func testReaderFindsKeyByDatabaseHeaderSalt() throws {
        let dir = try makeTempDirectory(name: "salt")
        let dbDir = dir + "/db_storage"
        try FileManager.default.createDirectory(atPath: dbDir + "/message", withIntermediateDirectories: true)

        // A stand-in database: only the first 16 bytes are ever read.
        var page = Data()
        page.append(contentsOf: [UInt8](repeating: 0x7f, count: 16))
        page.append(Data(repeating: 0x11, count: 64))
        try page.write(to: URL(fileURLWithPath: dbDir + "/message/message_0.db"))

        let keysPath = dir + "/access.json"
        let json: [String: Any] = ["schema_version": 2, "keys": [saltHex: keyHex]]
        try Data(try JSONSerialization.data(withJSONObject: json)).write(to: URL(fileURLWithPath: keysPath))

        let reader = WeChatReader(keysPath: keysPath, dbDir: dbDir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)
        XCTAssertEqual(reader.recognizedKeyEntryCount, 1)
        // No path entry exists in this file at all, so this can only come from
        // the header salt.
        XCTAssertEqual(reader.findKey(for: "message/message_0.db")?.count, 32)
    }

    /// A salt that matches nothing must not fabricate a key.
    func testSaltLookupMissesForADifferentDatabase() throws {
        let dir = try makeTempDirectory(name: "saltmiss")
        let dbDir = dir + "/db_storage"
        try FileManager.default.createDirectory(atPath: dbDir + "/message", withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 80)
            .write(to: URL(fileURLWithPath: dbDir + "/message/message_0.db"))

        let keysPath = dir + "/access.json"
        let json: [String: Any] = ["schema_version": 2, "keys": [saltHex: keyHex]]
        try Data(try JSONSerialization.data(withJSONObject: json)).write(to: URL(fileURLWithPath: keysPath))

        let reader = WeChatReader(keysPath: keysPath, dbDir: dbDir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)
        XCTAssertNil(reader.findKey(for: "message/message_0.db"))
    }

    /// The path form still wins, and is not displaced by the new fallback.
    func testPathEntryStillResolvesWithoutSaltKeys() throws {
        let dir = try makeTempDirectory(name: "path")
        let keysPath = dir + "/all_keys.json"
        let json: [String: Any] = ["message/message_0.db": ["enc_key": keyHex, "salt": saltHex]]
        try Data(try JSONSerialization.data(withJSONObject: json)).write(to: URL(fileURLWithPath: keysPath))

        let reader = WeChatReader(keysPath: keysPath, dbDir: dir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)
        XCTAssertEqual(reader.findKey(for: "message/message_0.db")?.count, 32)
    }

    // MARK: - File permissions

    /// A key file another local account can read is a key disclosed.
    func testLooseKeyFilePermissionsAreDetected() throws {
        let dir = try makeTempDirectory(name: "perm")
        let keysPath = dir + "/all_keys.json"
        try Data("{\"a.db\": \"\(keyHex)\"}".utf8).write(to: URL(fileURLWithPath: keysPath))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysPath)
        XCTAssertFalse(WeChatReader.hasLoosePermissions(atPath: keysPath))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keysPath)
        XCTAssertTrue(WeChatReader.hasLoosePermissions(atPath: keysPath))

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: keysPath)
        XCTAssertTrue(WeChatReader.hasLoosePermissions(atPath: keysPath), "group-readable is still disclosed")
    }

    func testAccessMaterialStateReportsLoosePermissions() throws {
        let dir = try makeTempDirectory(name: "state")
        let keysPath = dir + "/all_keys.json"
        try Data("{\"a.db\": \"\(keyHex)\"}".utf8).write(to: URL(fileURLWithPath: keysPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keysPath)

        let reader = WeChatReader(keysPath: keysPath, dbDir: dir, cacheStrategy: .memory)
        XCTAssertEqual(reader.accessMaterialState, .loosePermissions)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysPath)
        XCTAssertEqual(reader.accessMaterialState, .available)
    }

    // MARK: - Wiring

    /// The whole chain: a real reader, a real key file, a real diagnosis.
    ///
    /// This is the test that was missing, and its absence is why a real defect
    /// shipped into this round: `keyFilePermissionsAreLoose` was declared and
    /// read but never assigned, so it was permanently false and the
    /// `looseKeyPermissions` state could never fire in the app.
    ///
    /// It passed every test I had, because those tested the two ends separately
    /// — `accessMaterialState` returning `.loosePermissions`, and the policy
    /// producing the state from hand-written facts. Neither end can notice that
    /// the value between them is a constant. So the facts are now read off a
    /// live reader here, with nothing supplied by hand.
    func testLooseKeyFileReachesTheDiagnosisThroughARealReader() throws {
        let dir = try makeTempDirectory(name: "wiring")
        let dbDir = dir + "/db_storage"
        try FileManager.default.createDirectory(atPath: dbDir + "/session", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dbDir + "/session/session.db"))

        let keysPath = dir + "/all_keys.json"
        try Data("{\"message/message_0.db\": \"\(keyHex)\"}".utf8)
            .write(to: URL(fileURLWithPath: keysPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keysPath)

        let reader = WeChatReader(keysPath: keysPath, dbDir: dbDir, cacheStrategy: .memory)
        let diagnosis = SyncConnectionDiagnosis.evaluate(
            configuredPath: dbDir, candidates: [dbDir],
            exists: { _ in true }, readable: { _ in true }, containsDatabase: { _ in true },
            keyMaterial: SyncConnectionDiagnosis.KeyMaterialFacts(reader: reader)
        )
        XCTAssertEqual(
            diagnosis, .looseKeyPermissions,
            "a 0644 key file must reach the diagnosis, not sit in an unread flag"
        )

        // And fixing it must clear the state without reloading anything, which
        // is the reason the reader exposes permissions as computed rather than
        // as a value captured at load time.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysPath)
        let after = SyncConnectionDiagnosis.evaluate(
            configuredPath: dbDir, candidates: [dbDir],
            exists: { _ in true }, readable: { _ in true }, containsDatabase: { _ in true },
            keyMaterial: SyncConnectionDiagnosis.KeyMaterialFacts(reader: reader)
        )
        XCTAssertEqual(after, .ready(dbDir))
    }

    /// The other half of the same chain: an unreadable key file reports the
    /// format problem, not a directory problem.
    ///
    /// This is the misleading-advice case. A user whose key file is in an
    /// unrecognised shape reads "你的密钥不对" unless this fires, and goes
    /// hunting for a key that was never the issue.
    func testUnrecognizedKeyFileReachesTheDiagnosisThroughARealReader() throws {
        let dir = try makeTempDirectory(name: "wiring-unrecognized")
        let dbDir = dir + "/db_storage"
        try FileManager.default.createDirectory(atPath: dbDir + "/session", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dbDir + "/session/session.db"))

        let keysPath = dir + "/all_keys.json"
        try Data("{\"message/message_0.db\": {\"unexpected_field\": \"x\"}}".utf8)
            .write(to: URL(fileURLWithPath: keysPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysPath)

        let reader = WeChatReader(keysPath: keysPath, dbDir: dbDir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)

        let diagnosis = SyncConnectionDiagnosis.evaluate(
            configuredPath: dbDir, candidates: [dbDir],
            exists: { _ in true }, readable: { _ in true }, containsDatabase: { _ in true },
            keyMaterial: SyncConnectionDiagnosis.KeyMaterialFacts(reader: reader)
        )
        XCTAssertEqual(diagnosis, .unrecognizedKeyFormat(recognized: 0, rejected: 1))
        // The message must not blame the key.
        XCTAssertTrue(diagnosis.message.contains("不代表密钥不对"), diagnosis.message)
    }

    /// A healthy setup must not be dragged into a key state by the new checks.
    func testHealthyKeyFileStillReportsReady() throws {
        let dir = try makeTempDirectory(name: "wiring-healthy")
        let dbDir = dir + "/db_storage"
        try FileManager.default.createDirectory(atPath: dbDir + "/session", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dbDir + "/session/session.db"))

        let keysPath = dir + "/all_keys.json"
        try Data("{\"message/message_0.db\": \"\(keyHex)\"}".utf8)
            .write(to: URL(fileURLWithPath: keysPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysPath)

        let reader = WeChatReader(keysPath: keysPath, dbDir: dbDir, cacheStrategy: .memory)
        try reader.loadKeys(force: true)
        let diagnosis = SyncConnectionDiagnosis.evaluate(
            configuredPath: dbDir, candidates: [dbDir],
            exists: { _ in true }, readable: { _ in true }, containsDatabase: { _ in true },
            keyMaterial: SyncConnectionDiagnosis.KeyMaterialFacts(reader: reader)
        )
        XCTAssertEqual(diagnosis, .ready(dbDir))
    }
}
