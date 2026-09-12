import Foundation
import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import WeChatHUD

/// Builder for the encrypted, WeChat-shaped store used by the reader/scan
/// performance suites: `message_N.db` shards, `session.db` and a key file, all
/// under one temp directory and encrypted page-by-page the way WeChat's
/// SQLCipher layout does.
///
/// Shared by `WeChatReaderKeyIndexPerfTests`,
/// `WeChatReaderEphemeralCachePerfTests`, `WeChatReaderManifestDebouncePerfTests`
/// and `ScanEngineContactReusePerfTests` because all four need real encrypted
/// files with real mtimes and a real key file, not stubs.
final class WeChatReaderPerfFixture {
    struct MessageRow {
        let localId: Int
        let createTime: Int
        /// `Name2Id.rowid` of the sender; 0 means WeChat's "unknown sender".
        let senderId: Int
        let text: String
    }

    struct SessionRow {
        let username: String
        let unreadCount: Int
        let lastTimestamp: Int
    }

    let root: URL
    let dbDir: URL
    let keysURL: URL
    let accountUsername: String
    let key: Data

    /// Key-file entries written so far: key path → hex key. Tests that need a
    /// specific key-file shape mutate this and call `writeKeyFile`.
    private(set) var keyEntries: [String: String] = [:]
    private var plainPaths: [String: String] = [:]

    init(accountUsername: String = "synthetic_account", keyByte: UInt8 = 0x44) throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-perf-" + UUID().uuidString)
        self.dbDir = root.appendingPathComponent("xwechat_files/\(accountUsername)/db_storage", isDirectory: true)
        self.keysURL = root.appendingPathComponent("all_keys.json")
        self.accountUsername = accountUsername
        self.key = Data(repeating: keyByte, count: 32)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try writeKeyFile()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        for strategy in [CacheStrategy.memory, .persistent] {
            try? FileManager.default.removeItem(
                atPath: WeChatReader.cacheDir(for: strategy, databaseRoot: dbDir.path)
            )
        }
    }

    // MARK: Key file

    /// Writes `keyEntries` to the key file.
    ///
    /// `mtime` is set explicitly so a test can produce a genuinely *different*
    /// modification date (the reader treats an identical date as "no change").
    func writeKeyFile(mtime: Date? = nil) throws {
        let json: [String: [String: String]] = keyEntries.mapValues { ["enc_key": $0] }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: keysURL, options: .atomic)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: keysURL.path)
        }
    }

    func addKeyEntry(_ path: String, key: Data) {
        keyEntries[path] = Self.hex(key)
    }

    func addDefaultKeyEntry(_ path: String) {
        keyEntries[path] = Self.hex(key)
    }

    // MARK: Encrypted stores

    func createMessageDB(relPath: String, chats: [String: [MessageRow]], name2id: [String] = []) throws {
        let plainURL = plainURL(for: relPath)
        try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination(for: relPath).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(plainURL.path, &db) == SQLITE_OK, let db else {
            throw FixtureError("cannot create \(relPath)")
        }
        var reserve: Int32 = 80
        guard sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError("reserve bytes unavailable")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA page_size=4096; VACUUM; CREATE TABLE Name2Id(user_name TEXT)",
                           nil, nil, nil) == SQLITE_OK else {
            throw FixtureError("schema for \(relPath) rejected")
        }
        for name in name2id {
            sqlite3_exec(db, "INSERT INTO Name2Id(user_name) VALUES ('\(name)')", nil, nil, nil)
        }
        for (chat, rows) in chats {
            Self.ensureMessageTable(chat: chat, db: db)
            for row in rows {
                sqlite3_exec(db, """
                    INSERT INTO [\(Self.messageTable(for: chat))]
                    VALUES (\(row.localId), 1, \(row.createTime), \(row.senderId), '\(row.text)', 0)
                    """, nil, nil, nil)
            }
        }
        plainPaths[relPath] = plainURL.path
        addDefaultKeyEntry(relPath)
        try writeKeyFile()
        try encrypt(plainURL, to: destination(for: relPath))
    }

    func createSessionDB(rows: [SessionRow]) throws {
        let relPath = "session/session.db"
        let plainURL = plainURL(for: relPath)
        try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination(for: relPath).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(plainURL.path, &db) == SQLITE_OK, let db else {
            throw FixtureError("cannot create session.db")
        }
        var reserve: Int32 = 80
        guard sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError("reserve bytes unavailable")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, """
            PRAGMA page_size=4096;
            VACUUM;
            CREATE TABLE SessionTable(username TEXT, unread_count INTEGER, last_timestamp INTEGER);
            """, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError("session schema rejected")
        }
        for row in rows {
            sqlite3_exec(db, "INSERT INTO SessionTable VALUES ('\(row.username)', \(row.unreadCount), \(row.lastTimestamp))",
                         nil, nil, nil)
        }
        plainPaths[relPath] = plainURL.path
        addDefaultKeyEntry(relPath)
        try writeKeyFile()
        try encrypt(plainURL, to: destination(for: relPath))
    }

    /// Append rows to an existing message DB and re-publish the encrypted file,
    /// exactly like a WeChat write: new content, newer mtime.
    func appendMessages(relPath: String, chats: [String: [MessageRow]]) throws {
        guard let plainPath = plainPaths[relPath] else { throw FixtureError("unknown db \(relPath)") }
        var db: OpaquePointer?
        guard sqlite3_open(plainPath, &db) == SQLITE_OK, let db else {
            throw FixtureError("cannot open plaintext \(relPath)")
        }
        for (chat, rows) in chats {
            Self.ensureMessageTable(chat: chat, db: db)
            for row in rows {
                sqlite3_exec(db, """
                    INSERT INTO [\(Self.messageTable(for: chat))]
                    VALUES (\(row.localId), 1, \(row.createTime), \(row.senderId), '\(row.text)', 0)
                    """, nil, nil, nil)
            }
        }
        sqlite3_close(db)

        let encrypted = destination(for: relPath)
        try encrypt(URL(fileURLWithPath: plainPath), to: encrypted)
        // Guarantee a different mtime than the previous publication even on a
        // filesystem with coarse timestamps.
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: encrypted.path)
    }

    // MARK: Reader + store

    func makeReader(cacheStrategy: CacheStrategy = .memory) throws -> WeChatReader {
        let reader = WeChatReader(keysPath: keysURL.path, dbDir: dbDir.path, cacheStrategy: cacheStrategy)
        try reader.loadKeys()
        return reader
    }

    /// A HUD store for this fixture. `name` lets one fixture hold two stores —
    /// used to compare the real scan against a reference implementation with
    /// identical seed data but separate queue and cursor state.
    func makeStore(name: String = "hud") throws -> HUDStore {
        let store = HUDStore(dbPath: root.appendingPathComponent("\(name).sqlite3").path)
        try store.open()
        return store
    }

    func destination(for relPath: String) -> URL {
        dbDir.appendingPathComponent(relPath)
    }

    func plainURL(for relPath: String) -> URL {
        root.appendingPathComponent("plain/" + relPath.replacingOccurrences(of: "/", with: "_") + ".sqlite")
    }

    // MARK: Helpers

    static func messageTable(for username: String) -> String {
        "Msg_" + md5Hex(username)
    }

    private static func ensureMessageTable(chat: String, db: OpaquePointer) {
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS [\(messageTable(for: chat))] (
                local_id INTEGER PRIMARY KEY,
                local_type INTEGER,
                create_time INTEGER,
                real_sender_id INTEGER,
                message_content TEXT,
                WCDB_CT_message_content INTEGER
            )
            """, nil, nil, nil)
    }

    static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func encrypt(_ plain: URL, to encrypted: URL) throws {
        let data = try Data(contentsOf: plain)
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
                                    source.baseAddress, bytes.count,
                                    destination.baseAddress, bytes.count, &written)
                        }
                    }
                }
            }
            guard status == CCCryptorStatus(kCCSuccess) else { throw FixtureError("AES failure") }
            if first { output += Data(repeating: 0x11, count: 16) }
            output += cipher + iv + Data(count: 64)
        }
        try output.write(to: encrypted, options: .atomic)
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
