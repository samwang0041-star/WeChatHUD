import Foundation
import CommonCrypto
import SQLite3

final class WeChatReader {
    private let keysPath: String
    private let dbDir: String
    private let cacheDir: String
    private var keys: [String: Data] = [:]          // relative path → 32-byte key
    private var contactCache: [String: String] = [:] // username → display name
    private var decryptedCache: [String: String] = [:] // relative path → decrypted file path

    init(keysPath: String? = nil, dbDir: String? = nil) {
        let home = NSHomeDirectory()
        self.keysPath = keysPath ?? "\(home)/.wechat-cli/all_keys.json"
        self.dbDir = dbDir ?? Self.autoDetectDBDir() ?? ""
        self.cacheDir = NSTemporaryDirectory() + "wechat_hud_cache"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Auto-detect

    static func autoDetectDBDir() -> String? {
        let home = NSHomeDirectory()
        let base = "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        // Find the user data folder (usually a hex hash)
        for item in contents {
            let dbStorage = "\(base)/\(item)/db_storage"
            if FileManager.default.fileExists(atPath: dbStorage) {
                return dbStorage
            }
        }
        return nil
    }

    // MARK: - Key Loading

    func loadKeys() throws {
        guard let data = FileManager.default.contents(atPath: keysPath) else {
            throw ReaderError.keyLoadFailed("Cannot read \(keysPath)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReaderError.keyLoadFailed("Invalid JSON in \(keysPath)")
        }

        for (path, value) in json {
            guard !path.hasPrefix("_") else { continue }  // skip metadata
            guard let dict = value as? [String: Any],
                  let hexKey = dict["enc_key"] as? String else { continue }
            guard let keyData = Data(hexString: hexKey), keyData.count == 32 else { continue }
            // Normalize path variants
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            keys[normalized] = keyData
        }
    }

    // MARK: - DB Access

    /// Get a decrypted, readable SQLite DB for the given relative path.
    func getDecryptedDB(relativePath: String) throws -> String {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")

        // Check cache
        if let cached = decryptedCache[normalized], FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        guard let key = findKey(for: normalized) else {
            throw ReaderError.noKey(normalized)
        }

        let encPath = "\(dbDir)/\(normalized)"
        guard FileManager.default.fileExists(atPath: encPath) else {
            throw ReaderError.dbNotFound(encPath)
        }

        // MD5 hash of relative path as cache filename
        let hash = md5Hex(normalized)
        let decPath = "\(cacheDir)/\(hash).db"

        try WeChatDecryptor.decryptDB(inputPath: encPath, outputPath: decPath, key: key)

        // Apply WAL if exists
        let walPath = encPath + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            try WeChatDecryptor.applyWAL(dbPath: decPath, walPath: walPath, key: key)
        }

        decryptedCache[normalized] = decPath
        return decPath
    }

    private func findKey(for path: String) -> Data? {
        if let k = keys[path] { return k }
        // Try path variants
        let withSlash = path.replacingOccurrences(of: "\\", with: "/")
        if let k = keys[withSlash] { return k }
        // Try matching by suffix (filename only)
        let filename = (path as NSString).lastPathComponent
        for (kp, kv) in keys {
            if (kp as NSString).lastPathComponent == filename { return kv }
        }
        return nil
    }

    // MARK: - Contacts

    func loadContacts() throws {
        let decPath = try getDecryptedDB(relativePath: "contact/contact.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(decPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("Cannot open contact.db")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT username, nick_name, remark FROM contact", -1, &stmt, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("Cannot query contacts")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let username = columnText(stmt, 0)
            let nickName = columnText(stmt, 1)
            let remark = columnText(stmt, 2)
            // Priority: remark > nick_name > username
            let display = remark.isEmpty ? (nickName.isEmpty ? username : nickName) : remark
            contactCache[username] = display
        }
    }

    func displayName(for username: String) -> String {
        contactCache[username] ?? username
    }

    func allContacts() -> [String: String] {
        contactCache
    }

    // MARK: - Message DB Discovery

    /// Find all message_*.db files that have keys.
    func findMessageDBs() -> [String] {
        keys.keys
            .filter { $0.contains("message/message_") && $0.hasSuffix(".db") }
            .sorted()
    }

    /// Find the Msg_{hash} table for a given chat username in a specific message DB.
    func findMsgTable(chatUsername: String, dbPath: String) throws -> String? {
        let hash = md5Hex(chatUsername)
        let tableName = "Msg_\(hash)"

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("Cannot open \(dbPath)")
        }
        defer { sqlite3_close(db) }

        // Check if table exists
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return sqlite3_step(stmt) == SQLITE_ROW ? tableName : nil
    }

    // MARK: - Message Queries

    /// Get recent messages from a chat. Returns raw message data.
    func getMessages(chatUsername: String, limit: Int = 50, sinceLocalId: Int? = nil) throws -> [MessageInfo] {
        let msgDBs = findMessageDBs()
        var results: [MessageInfo] = []

        for relPath in msgDBs {
            let decPath = try getDecryptedDB(relativePath: relPath)
            guard let tableName = try findMsgTable(chatUsername: chatUsername, dbPath: decPath) else {
                continue
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(decPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            defer { sqlite3_close(db) }

            var sql = """
                SELECT local_id, local_type, create_time, real_sender_id,
                       message_content, WCDB_CT_message_content
                FROM [\(tableName)]
            """
            if let since = sinceLocalId {
                sql += " WHERE local_id > \(since)"
            }
            sql += " ORDER BY create_time DESC LIMIT \(limit)"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            // Load Name2Id mapping for sender resolution
            let name2id = loadName2Id(db: db)
            let isGroup = chatUsername.contains("@chatroom")
            let chatName = displayName(for: chatUsername)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let localId = Int(sqlite3_column_int64(stmt, 0))
                let localType = Int(sqlite3_column_int64(stmt, 1))
                let createTime = Int(sqlite3_column_int64(stmt, 2))
                let realSenderId = Int(sqlite3_column_int64(stmt, 3))
                let baseType = localType & 0xFFFFFFFF
                let subType = localType >> 32

                // Decode content
                let contentRaw: Data?
                if let blob = sqlite3_column_blob(stmt, 4) {
                    let len = sqlite3_column_bytes(stmt, 4)
                    contentRaw = Data(bytes: blob, count: Int(len))
                } else {
                    contentRaw = nil
                }
                let ct = Int(sqlite3_column_int(stmt, 5))
                let contentStr = WeChatParser.decodeContent(contentRaw, ct: ct)

                // Parse message
                let parsed = WeChatParser.renderMessage(content: contentStr, baseType: baseType, isGroup: isGroup)

                // Resolve sender
                let senderUsername = name2id[realSenderId] ?? parsed.senderHint
                let senderName = displayName(for: senderUsername)

                let uid = "\(relPath)/\(tableName)/\(localId)"
                let msg = MessageInfo(
                    id: uid,
                    chatUsername: chatUsername,
                    chatName: chatName,
                    senderUsername: senderUsername,
                    senderName: senderName,
                    text: parsed.text,
                    baseType: baseType,
                    subType: subType,
                    createTime: createTime
                )
                results.append(msg)
            }
        }

        return results.sorted { $0.createTime > $1.createTime }
    }

    /// Count new messages since a given local_id for a specific chat table.
    func countNewMessages(relPath: String, tableName: String, sinceLocalId: Int) throws -> Int {
        let decPath = try getDecryptedDB(relativePath: relPath)
        var db: OpaquePointer?
        guard sqlite3_open_v2(decPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM [\(tableName)] WHERE local_id > \(sinceLocalId)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Get the max local_id for a table.
    func maxLocalId(relPath: String, tableName: String) throws -> Int {
        let decPath = try getDecryptedDB(relativePath: relPath)
        var db: OpaquePointer?
        guard sqlite3_open_v2(decPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT MAX(local_id) FROM [\(tableName)]"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// List all chat tables across all message DBs.
    func listAllChatTables() throws -> [(relPath: String, tableName: String, chatUsername: String)] {
        var results: [(String, String, String)] = []
        let msgDBs = findMessageDBs()

        for relPath in msgDBs {
            let decPath = try getDecryptedDB(relativePath: relPath)
            var db: OpaquePointer?
            guard sqlite3_open_v2(decPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            defer { sqlite3_close(db) }

            // Get all Msg_ tables
            var stmt: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let tableName = columnText(stmt, 0)
                results.append((relPath, tableName, ""))
            }
        }

        return results
    }

    // MARK: - Name2Id

    private func loadName2Id(db: OpaquePointer?) -> [Int: String] {
        var mapping: [Int: String] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, user_name FROM Name2Id", -1, &stmt, nil) == SQLITE_OK else {
            return mapping
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let username = columnText(stmt, 1)
            mapping[rowid] = username
        }
        return mapping
    }

    // MARK: - Helpers

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }

    private func md5Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum ReaderError: Error {
    case keyLoadFailed(String)
    case noKey(String)
    case dbNotFound(String)
    case sqlError(String)
}

// MARK: - Data hex extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
