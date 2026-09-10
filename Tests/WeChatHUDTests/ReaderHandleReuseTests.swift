import XCTest
import SQLite3
import CryptoKit
import CommonCrypto
@testable import WeChatHUD

/// Guards the scan hot path against re-parsing a decrypted DB's schema per
/// query.
///
/// `WeChatReader.getMessages` used to open a throwaway connection for the
/// `Msg_<md5>` probe and a second one for the query itself. SQLite parses the
/// whole `sqlite_master` schema the first time a connection touches a file,
/// and production message DBs carry hundreds of tables — one observed parse
/// spent 4.6 s of CPU inside `sqlite3InitOne`. With roughly a hundred
/// whitelist sessions, each 30 s scan therefore never finished before the next
/// tick, and the reader lock stayed held long enough to stall the UI.
///
/// These assertions are timing-independent on purpose:
/// `readHandleOpenCount` makes "was the connection reused" directly
/// observable, so the regression cannot sneak back in as a flaky timing change.
final class ReaderHandleReuseTests: XCTestCase {

    private var reader: WeChatReader?
    private var fixture: EncryptedFixture?

    @discardableResult
    private func makeSUT(plan: [String: [String: [String]]], fillerTableCount: Int = 0) throws -> WeChatReader {
        let fixture = try EncryptedFixture(plan: plan, fillerTableCount: fillerTableCount)
        self.fixture = fixture
        let reader = try fixture.makeReader()
        self.reader = reader
        return reader
    }

    override func tearDown() {
        fixture?.cleanUp()
        reader = nil
        fixture = nil
        super.tearDown()
    }

    /// Ten reads across two chats in one DB must open a single connection.
    /// Before the fix this was ten — one throwaway attach per call, each one
    /// re-parsing the schema because `immutable=1` also keeps SQLite from
    /// sharing its schema cache between connections.
    func testRepeatedReadsReuseASingleHandle() throws {
        let reader = try makeSUT(plan: [
            EncryptedFixture.messageDB0: ["alpha": ["a1", "a2", "a3"], "beta": ["b1"]],
        ])

        for _ in 0..<5 {
            XCTAssertEqual(try reader.getMessages(chatUsername: "alpha", limit: 10).count, 3)
            XCTAssertEqual(try reader.getMessages(chatUsername: "beta", limit: 10).count, 1)
        }

        XCTAssertEqual(reader.readHandleOpenCount, 1)
    }

    /// A schema with hundreds of tables is what made the parse expensive, so the
    /// fixture reproduces that shape rather than testing a toy database.
    func testReadingManyChatsDoesNotReopenPerChat() throws {
        let chats = Dictionary(uniqueKeysWithValues: (0..<12).map { ("chat\($0)", ["m\($0)"]) })
        let reader = try makeSUT(plan: [EncryptedFixture.messageDB0: chats], fillerTableCount: 200)

        for _ in 0..<3 {
            for chat in chats.keys.sorted() {
                XCTAssertEqual(try reader.getMessages(chatUsername: chat, limit: 10).count, 1)
            }
        }

        XCTAssertEqual(reader.readHandleOpenCount, 1,
                       "36 reads over a 200-table DB must still share one handle")
    }

    /// `immutable=1` opts out of SQLite's own change detection, so a handle
    /// kept across a re-decrypt would silently serve the superseded snapshot.
    func testRewrittenSnapshotIsNotServedThroughAStaleHandle() throws {
        let reader = try makeSUT(plan: [
            EncryptedFixture.messageDB0: ["alpha": ["a1"]],
        ])
        let fixture = try XCTUnwrap(self.fixture)
        // Message rows come back newest-first.
        XCTAssertEqual(try reader.getMessages(chatUsername: "alpha", limit: 10).map(\.text), ["a1"])

        try fixture.appendMessages(["a2"], chat: "alpha", inRelPath: EncryptedFixture.messageDB0)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: EncryptedFixture.messageDB0))

        XCTAssertEqual(try reader.getMessages(chatUsername: "alpha", limit: 10).map(\.text), ["a2", "a1"])
    }

    /// A positive mapping records which DB holds a chat's table. Rewriting that
    /// DB does not move the table out of it, so the mapping must survive —
    /// dropping every mapping on each WeChat write forced a full O(N_dbs)
    /// re-probe of the whole whitelist on every scan.
    func testRefreshingOneMessageDBKeepsKnownTableLocations() throws {
        let reader = try makeSUT(plan: [
            EncryptedFixture.messageDB0: ["alpha": ["a1"]],
            EncryptedFixture.messageDB1: ["beta": ["b1"]],
        ])
        let fixture = try XCTUnwrap(self.fixture)

        // Prime both mappings: beta has no cached location, so this probes
        // message_0.db (miss) and then message_1.db (hit).
        XCTAssertEqual(try reader.getMessages(chatUsername: "alpha", limit: 10).count, 1)
        XCTAssertEqual(try reader.getMessages(chatUsername: "beta", limit: 10).count, 1)
        let opensAfterPriming = reader.readHandleOpenCount

        try fixture.appendMessages(["a2"], chat: "alpha", inRelPath: EncryptedFixture.messageDB0)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: EncryptedFixture.messageDB0))

        XCTAssertEqual(try reader.getMessages(chatUsername: "beta", limit: 10).count, 1)
        XCTAssertEqual(
            reader.readHandleOpenCount, opensAfterPriming,
            "beta lives in message_1.db; refreshing message_0.db must not force a re-probe"
        )
    }

    /// The other half of that contract: when a table really has moved, the
    /// reader must notice, drop the single stale mapping and recover on a full
    /// scan instead of returning an empty conversation forever.
    func testTableThatMovedToAnotherDBIsStillFound() throws {
        let reader = try makeSUT(plan: [
            EncryptedFixture.messageDB0: ["alpha": ["a1"]],
        ])
        let fixture = try XCTUnwrap(self.fixture)
        XCTAssertEqual(try reader.getMessages(chatUsername: "alpha", limit: 10).count, 1)

        // WeChat relocates the chat's table into a newly created message DB.
        try fixture.createMessageDB(relPath: EncryptedFixture.messageDB1, chats: ["alpha": ["a1", "a2"]])
        try fixture.dropTable(chat: "alpha", inRelPath: EncryptedFixture.messageDB0)
        try reader.loadKeys(force: true)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: EncryptedFixture.messageDB1))
        XCTAssertTrue(try reader.refreshIfChanged(relPath: EncryptedFixture.messageDB0))

        XCTAssertEqual(try reader.getMessages(chatUsername: "alpha", limit: 10).count, 2)
    }

    /// A negative result is the one thing a rewrite can genuinely invalidate: a
    /// chat that had no table may have gained one.
    func testNewlyCreatedTableIsDiscoveredAfterRefresh() throws {
        let reader = try makeSUT(plan: [
            EncryptedFixture.messageDB0: ["alpha": ["a1"]],
        ])
        let fixture = try XCTUnwrap(self.fixture)
        XCTAssertTrue(try reader.getMessages(chatUsername: "brand-new").isEmpty)

        try fixture.addTable(chat: "brand-new", messages: ["n1"], inRelPath: EncryptedFixture.messageDB0)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: EncryptedFixture.messageDB0))

        XCTAssertEqual(try reader.getMessages(chatUsername: "brand-new", limit: 10).count, 1)
    }
}

// MARK: - Encrypted fixture

/// Builds an encrypted WeChat-shaped DB set: one or more `message/message_N.db`
/// files, each holding a `Name2Id` table plus one `Msg_<md5>` table per chat.
/// The plaintext is kept alongside so a test can mutate it and re-publish, which
/// is what WeChat does to the real file on a write.
private final class EncryptedFixture {
    static let messageDB0 = "message/message_0.db"
    static let messageDB1 = "message/message_1.db"

    let root: URL
    private var plainPaths: [String: String] = [:]
    private var keyJSON: [String: [String: String]] = [:]
    private let key = Data(repeating: 0x7A, count: 32)
    private var accountRoot: String { root.appendingPathComponent("xwechat_files/wxid_fixture/db_storage").path }

    init(plan: [String: [String: [String]]], fillerTableCount: Int = 0) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-handle-reuse-" + UUID().uuidString)
        let dbRoot = root.appendingPathComponent("xwechat_files/wxid_fixture/db_storage")
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)

        for (relPath, chats) in plan {
            try createMessageDB(relPath: relPath, chats: chats, fillerTableCount: fillerTableCount)
        }

        try writeKeys()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(
            atPath: WeChatReader.cacheDir(for: .memory, databaseRoot: accountRoot)
        )
    }

    func makeReader() throws -> WeChatReader {
        let reader = WeChatReader(
            keysPath: root.appendingPathComponent("keys.json").path,
            dbDir: accountRoot,
            cacheStrategy: .memory
        )
        try reader.loadKeys()
        return reader
    }

    /// A DB created after the reader loaded its keys needs the key file
    /// refreshed and `loadKeys(force:)` re-run, exactly like a real new
    /// message shard appearing under WeChat.
    private func writeKeys() throws {
        try JSONSerialization.data(withJSONObject: keyJSON)
            .write(to: root.appendingPathComponent("keys.json"))
    }

    // MARK: Mutation

    func createMessageDB(relPath: String, chats: [String: [String]],
                         fillerTableCount: Int = 0) throws {
        let plainURL = plainPath(for: relPath)
        if plainPaths[relPath] == nil {
            try FileManager.default.createDirectory(
                at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: destination(for: relPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var db: OpaquePointer?
            guard sqlite3_open(plainURL.path, &db) == SQLITE_OK else {
                throw FixtureError("cannot create fixture db")
            }
            var reserve: Int32 = 80
            XCTAssertEqual(sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA page_size=4096; VACUUM; CREATE TABLE Name2Id(user_name TEXT)", nil, nil, nil), SQLITE_OK)
            for index in 0..<fillerTableCount {
                sqlite3_exec(db, "CREATE TABLE filler_\(index)(a INTEGER, b TEXT); CREATE INDEX idx_filler_\(index) ON filler_\(index)(a)", nil, nil, nil)
            }
            sqlite3_close(db)
            plainPaths[relPath] = plainURL.path
            keyJSON[relPath] = ["enc_key": key.map { String(format: "%02x", $0) }.joined()]
            try writeKeys()
        }

        try mutate(relPath: relPath) { db in
            for (chat, messages) in chats {
                self.ensureTable(chat: chat, db: db)
                for text in messages {
                    self.insert(chat: chat, text: text, db: db)
                }
            }
        }
    }

    func addTable(chat: String, messages: [String], inRelPath relPath: String) throws {
        try mutate(relPath: relPath) { db in
            self.ensureTable(chat: chat, db: db)
            for text in messages {
                self.insert(chat: chat, text: text, db: db)
            }
        }
    }

    func dropTable(chat: String, inRelPath relPath: String) throws {
        try mutate(relPath: relPath) { db in
            sqlite3_exec(db, "DROP TABLE [Msg_\(Self.md5Hex(chat))]", nil, nil, nil)
        }
    }

    func appendMessages(_ messages: [String], chat: String, inRelPath relPath: String) throws {
        try mutate(relPath: relPath) { db in
            for text in messages { self.insert(chat: chat, text: text, db: db) }
        }
    }

    // MARK: Internals

    /// Apply a mutation to the plaintext and re-publish the encrypted file, so
    /// the next `refreshIfChanged` sees a new mtime and a new snapshot.
    private func mutate(relPath: String, _ body: (OpaquePointer) -> Void) throws {
        guard let plainPath = plainPaths[relPath] else { throw FixtureError("unknown db \(relPath)") }
        var db: OpaquePointer?
        guard sqlite3_open(plainPath, &db) == SQLITE_OK, let db else {
            throw FixtureError("cannot open \(plainPath)")
        }
        body(db)
        sqlite3_close(db)
        try encrypt(URL(fileURLWithPath: plainPath), to: destination(for: relPath), key: key)
    }

    private func plainPath(for relPath: String) -> URL {
        root.appendingPathComponent(relPath.replacingOccurrences(of: "/", with: "_") + ".plain")
    }

    private func destination(for relPath: String) -> URL {
        root.appendingPathComponent("xwechat_files/wxid_fixture/db_storage")
            .appendingPathComponent(relPath)
    }

    private func ensureTable(chat: String, db: OpaquePointer) {
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS [Msg_\(Self.md5Hex(chat))] (
                local_id INTEGER PRIMARY KEY,
                local_type INTEGER,
                create_time INTEGER,
                real_sender_id INTEGER,
                message_content TEXT,
                WCDB_CT_message_content INTEGER
            )
            """, nil, nil, nil)
    }

    private func insert(chat: String, text: String, db: OpaquePointer) {
        let localId = maxLocalID(chat: chat, db: db) + 1
        sqlite3_exec(db, """
            INSERT INTO [Msg_\(Self.md5Hex(chat))]
            VALUES (\(localId), 1, \(1_700_000_000 + localId), 0, '\(text)', 0)
            """, nil, nil, nil)
    }

    private func maxLocalID(chat: String, db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(local_id) FROM [Msg_\(Self.md5Hex(chat))]", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func encrypt(_ plain: URL, to encrypted: URL, key: Data) throws {
        let data = try Data(contentsOf: plain)
        XCTAssertEqual(data[20], 80)
        var output = Data()
        let iv = Data(repeating: 0x22, count: 16)
        for start in stride(from: 0, to: data.count, by: 4096) {
            let first = start == 0
            let bytes = data.subdata(in: start + (first ? 16 : 0)..<start + 4016)
            var cipher = Data(count: bytes.count)
            var written = 0
            let status = cipher.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { source in
                    key.withUnsafeBytes { keyBytes in
                        iv.withUnsafeBytes { vector in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                    keyBytes.baseAddress, 32, vector.baseAddress,
                                    source.baseAddress, bytes.count, destination.baseAddress, bytes.count, &written)
                        }
                    }
                }
            }
            XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
            if first { output += Data(repeating: 0x11, count: 16) }
            output += cipher + iv + Data(count: 64)
        }
        try output.write(to: encrypted, options: .atomic)
    }

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
