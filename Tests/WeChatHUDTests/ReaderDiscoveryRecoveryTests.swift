import XCTest
import SQLite3
import CryptoKit
import CommonCrypto
@testable import WeChatHUD

final class ReaderDiscoveryRecoveryTests: XCTestCase {
    func testNewTableAppearsAfterNegativeCacheAndEmptyPagesDoNotPoisonDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("message"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("fixture.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(plain.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var reserve: Int32 = 80
        XCTAssertEqual(sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA page_size=4096; VACUUM; CREATE TABLE Name2Id(user_name TEXT)", nil, nil, nil), SQLITE_OK)
        let key = Data(repeating: 0x44, count: 32)
        let encrypted = root.appendingPathComponent("message/message_0.db")
        let keys = root.appendingPathComponent("keys.json")
        let keyJSON = ["message/message_0.db": ["enc_key": key.map { String(format: "%02x", $0) }.joined()]]
        try JSONSerialization.data(withJSONObject: keyJSON).write(to: keys)
        try encrypt(plain, to: encrypted, key: key)
        let reader = WeChatReader(keysPath: keys.path, dbDir: root.path, cacheStrategy: .memory)
        defer { try? FileManager.default.removeItem(atPath: WeChatReader.cacheDir(for: .memory, databaseRoot: root.path)) }
        try reader.loadKeys()
        XCTAssertTrue(try reader.getMessages(chatUsername: "fixture").isEmpty)
        let hash = Insecure.MD5.hash(data: Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined()
        let table = "Msg_" + hash
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE [\(table)] (local_id INTEGER, local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT, WCDB_CT_message_content INTEGER)", nil, nil, nil), SQLITE_OK)
        try encrypt(plain, to: encrypted, key: key)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: "message/message_0.db"))
        // A real but empty message table is a successful query, not a missing table.
        XCTAssertTrue(try reader.getMessages(chatUsername: "fixture").isEmpty)
        XCTAssertTrue(try reader.getMessages(chatUsername: "fixture", afterCursor: (100, 0), oldestFirst: true).isEmpty)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO [\(table)] VALUES (1, 1, 101, 0, 'hello', 0)", nil, nil, nil), SQLITE_OK)
        try encrypt(plain, to: encrypted, key: key)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: "message/message_0.db"))
        let messages = try reader.getMessages(chatUsername: "fixture", afterCursor: (100, 0), oldestFirst: true)
        XCTAssertEqual(messages.map(\.localId), [1])
        XCTAssertEqual(messages.first?.text, "hello")
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
}
