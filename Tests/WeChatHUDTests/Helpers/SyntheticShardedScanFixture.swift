import Foundation
import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import WeChatHUD

/// Builder for an encrypted, WeChat-shaped store: `message_N.db` shards plus
/// `session.db`, wired to a `WeChatReader`.
///
/// WeChat splits one chat's history across up to ten `message_N.db` files, with
/// the same `Msg_<md5>` table present in every shard that holds part of it. The
/// fixture keeps that shape so tests can prove the reader merges shards instead
/// of trusting whichever file it opens first.
final class SyntheticShardedScanFixture {
    struct MessageRow {
        let localId: Int
        let createTime: Int
        let senderId: Int
        let text: String
    }

    let root: URL
    let dbDir: URL
    let keysURL: URL
    let reader: WeChatReader
    let chatUsername: String
    private let key = Data(repeating: 0x44, count: 32)

    /// - Parameters:
    ///   - shards: shard index → rows for `chatUsername`'s table in that shard.
    ///   - unreadCount: what `session.db` reports for the chat, which is what
    ///     the scan sizes its page by.
    init(chatUsername: String, shards: [Int: [MessageRow]], unreadCount: Int = 0) throws {
        self.chatUsername = chatUsername
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sharded-scan-\(UUID().uuidString)")
        dbDir = root.appendingPathComponent("synthetic_account/db_storage", isDirectory: true)
        keysURL = root.appendingPathComponent("keys.json")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let table = Self.messageTable(for: chatUsername)
        var keyJSON: [String: Any] = [:]
        var newestTimestamp = 0

        for (index, rows) in shards.sorted(by: { $0.key < $1.key }) {
            let inserts = rows.map {
                "INSERT INTO [\(table)] VALUES (\($0.localId), 1, \($0.createTime), \($0.senderId), '\($0.text)', 0);"
            }.joined(separator: "\n")
            newestTimestamp = max(newestTimestamp, rows.map(\.createTime).max() ?? 0)
            let schema = """
                PRAGMA page_size=4096;
                VACUUM;
                CREATE TABLE Name2Id(user_name TEXT);
                CREATE TABLE [\(table)] (
                    local_id INTEGER PRIMARY KEY,
                    local_type INTEGER,
                    create_time INTEGER,
                    real_sender_id INTEGER,
                    message_content TEXT,
                    WCDB_CT_message_content INTEGER
                );
                INSERT INTO Name2Id(user_name) VALUES ('\(chatUsername)');
                INSERT INTO Name2Id(user_name) VALUES ('synthetic_account');
                \(inserts)
                """
            let encrypted = dbDir.appendingPathComponent("message/message_\(index).db")
            try FileManager.default.createDirectory(
                at: encrypted.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.writeEncryptedStore(
                plain: root.appendingPathComponent("message_\(index).sqlite"),
                encrypted: encrypted,
                key: key,
                schema: schema
            )
            keyJSON["message/message_\(index).db"] = ["enc_key": Self.hex(key)]
        }

        let sessionSchema = """
            PRAGMA page_size=4096;
            VACUUM;
            CREATE TABLE SessionTable (
                username TEXT,
                unread_count INTEGER,
                last_timestamp INTEGER
            );
            INSERT INTO SessionTable VALUES ('\(chatUsername)', \(unreadCount), \(newestTimestamp));
            """
        let sessionEncrypted = dbDir.appendingPathComponent("session/session.db")
        try FileManager.default.createDirectory(
            at: sessionEncrypted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeEncryptedStore(
            plain: root.appendingPathComponent("session.sqlite"),
            encrypted: sessionEncrypted,
            key: key,
            schema: sessionSchema
        )
        keyJSON["session/session.db"] = ["enc_key": Self.hex(key)]

        try JSONSerialization.data(withJSONObject: keyJSON).write(to: keysURL)
        reader = WeChatReader(keysPath: keysURL.path, dbDir: dbDir.path, cacheStrategy: .memory)
        // The reader discovers message DBs through its key file; without this it
        // reports "no DBs" instead of failing loudly.
        try reader.loadKeys()
    }

    func makeStore() throws -> HUDStore {
        let store = HUDStore(dbPath: root.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        return store
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func messageTable(for username: String) -> String {
        "Msg_" + md5Hex(username)
    }

    static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `schema` into a plain SQLite file, then encrypts it page by page
    /// the way WeChat's SQLCipher layout does (80 reserved bytes per page,
    /// AES-256-CBC over the page body with a fixed IV in the fixture).
    private static func writeEncryptedStore(plain: URL, encrypted: URL, key: Data, schema: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(plain.path, &db) == SQLITE_OK else {
            throw NSError(domain: "SyntheticShardedScanFixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var reserve: Int32 = 80
        guard sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve) == SQLITE_OK else {
            throw NSError(domain: "SyntheticShardedScanFixture", code: 2)
        }
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticShardedScanFixture", code: 3)
        }
        try encrypt(plain, to: encrypted, key: key)
    }

    private static func encrypt(_ plain: URL, to encrypted: URL, key: Data) throws {
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
                            CCCrypt(
                                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, 32, vector.baseAddress,
                                source.baseAddress, bytes.count,
                                destination.baseAddress, bytes.count, &written
                            )
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
}
