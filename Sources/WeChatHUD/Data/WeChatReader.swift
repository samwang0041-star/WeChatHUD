import Foundation
import CommonCrypto
import SQLite3

final class WeChatReader {
    private let keysPath: String
    let dbDir: String
    private let cacheDir: String
    private let cacheStrategy: CacheStrategy
    private let manifestPath: String

    private var keys: [String: Data] = [:]           // relative path → 32-byte key
    private var contactCache: [String: String] = [:] // username → display name
    private var decryptedCache: [String: String] = [:] // relative path → decrypted file path
    private var mainMtimes: [String: Date] = [:]     // relative path → last-seen enc DB mtime
    private var walMtimes: [String: Date] = [:]      // relative path → last-seen WAL mtime
    private var contactsMtime: Date?                 // last-seen contact.db mtime
    private var keysMtime: Date?                     // last-seen all_keys.json mtime

    init(keysPath: String? = nil, dbDir: String? = nil, cacheStrategy: CacheStrategy = .persistent) {
        let home = NSHomeDirectory()
        self.keysPath = keysPath ?? "\(home)/.wechat-cli/all_keys.json"
        self.dbDir = dbDir ?? Self.autoDetectDBDir() ?? ""
        self.cacheStrategy = cacheStrategy
        self.cacheDir = Self.cacheDir(for: cacheStrategy)
        self.manifestPath = "\(self.cacheDir)/manifest.json"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        if cacheStrategy == .persistent {
            loadManifest()
        }
    }

    static func cacheDir(for strategy: CacheStrategy) -> String {
        let home = NSHomeDirectory()
        switch strategy {
        case .persistent: return "\(home)/.wechat-hud/cache"
        case .temporary:  return "/tmp/wechat_hud_cache"
        case .memory:
            return NSTemporaryDirectory() + "wechat_hud_ephemeral_\(getpid())"
        }
    }

    // MARK: - Auto-detect

    static func autoDetectDBDir() -> String? {
        let home = NSHomeDirectory()
        let base = "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for item in contents {
            let dbStorage = "\(base)/\(item)/db_storage"
            if FileManager.default.fileExists(atPath: dbStorage) {
                return dbStorage
            }
        }
        return nil
    }

    // MARK: - Key Loading

    func loadKeys(force: Bool = false) throws {
        let fm = FileManager.default
        let curMtime = (try? fm.attributesOfItem(atPath: keysPath)[.modificationDate]) as? Date
        if !force, let cur = curMtime, let last = keysMtime, cur == last {
            return  // unchanged, nothing to do
        }
        guard let data = fm.contents(atPath: keysPath) else {
            throw ReaderError.keyLoadFailed("Cannot read \(keysPath)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReaderError.keyLoadFailed("Invalid JSON in \(keysPath)")
        }

        keys.removeAll(keepingCapacity: true)
        for (path, value) in json {
            guard !path.hasPrefix("_") else { continue }
            guard let dict = value as? [String: Any],
                  let hexKey = dict["enc_key"] as? String else { continue }
            guard let keyData = Data(hexString: hexKey), keyData.count == 32 else { continue }
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            keys[normalized] = keyData
        }
        keysMtime = curMtime
    }

    // MARK: - Cache Invalidation (mtime-based)

    /// Compare current mtimes of the encrypted DB / WAL against the last
    /// known values. Returns true if anything changed and the cache was
    /// refreshed. Callers use the return value to decide whether to re-query.
    ///
    /// Strategy: WCDB (WeChat's SQLCipher fork) aggressively checkpoints —
    /// on each flush it regenerates WAL header salts and moves new page
    /// content into the main DB, so the on-disk WAL frames can all be
    /// "stale" (0 matching salts) while the main DB carries the real new
    /// state. That means `applyWAL` alone is NOT enough — when main DB
    /// mtime bumps we must re-decrypt. A 4-5 MB message DB re-decrypts in
    /// ~30-40 ms, which is still cheap enough for the hot path.
    @discardableResult
    func refreshIfChanged(relPath: String) throws -> Bool {
        let normalized = relPath.replacingOccurrences(of: "\\", with: "/")
        let encPath = "\(dbDir)/\(normalized)"
        let walPath = encPath + "-wal"
        let fm = FileManager.default

        guard fm.fileExists(atPath: encPath) else { return false }

        let mainMtime = (try? fm.attributesOfItem(atPath: encPath)[.modificationDate]) as? Date
        let walMtime = (try? fm.attributesOfItem(atPath: walPath)[.modificationDate]) as? Date

        let mainChanged = mainMtime != mainMtimes[normalized]
        let walChanged = walMtime != walMtimes[normalized]

        if !mainChanged && !walChanged {
            return false  // common case — nothing moved
        }

        // Main DB touched → drop the cache and re-decrypt. This is the only
        // way to pick up pages that WCDB already flushed from WAL into the
        // main file. Cost for a typical message DB is ~30-40 ms.
        if mainChanged {
            if let old = decryptedCache[normalized] {
                try? fm.removeItem(atPath: old)
            }
            decryptedCache.removeValue(forKey: normalized)
        }

        let decPath = try getDecryptedDB(relativePath: normalized)

        // Still apply WAL — catches the case where WAL has newer frames than
        // the last checkpoint (rare but possible on rapid writes).
        if fm.fileExists(atPath: walPath), let key = findKey(for: normalized) {
            try WeChatDecryptor.applyWAL(dbPath: decPath, walPath: walPath, key: key)
        }

        mainMtimes[normalized] = mainMtime
        walMtimes[normalized] = walMtime
        if cacheStrategy == .persistent { saveManifest() }
        return true
    }

    // MARK: - DB Access

    /// Get a decrypted, readable SQLite DB for the given relative path.
    func getDecryptedDB(relativePath: String) throws -> String {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")

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

        let hash = md5Hex(normalized)
        let decPath = "\(cacheDir)/\(hash).db"

        try WeChatDecryptor.decryptDB(inputPath: encPath, outputPath: decPath, key: key)

        let walPath = encPath + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            try WeChatDecryptor.applyWAL(dbPath: decPath, walPath: walPath, key: key)
        }

        decryptedCache[normalized] = decPath
        return decPath
    }

    private func findKey(for path: String) -> Data? {
        if let k = keys[path] { return k }
        let withSlash = path.replacingOccurrences(of: "\\", with: "/")
        if let k = keys[withSlash] { return k }
        let filename = (path as NSString).lastPathComponent
        for (kp, kv) in keys {
            if (kp as NSString).lastPathComponent == filename { return kv }
        }
        return nil
    }

    // MARK: - Contacts

    /// Reload contacts only if contact.db mtime changed since last load.
    @discardableResult
    func refreshContactsIfChanged() throws -> Bool {
        let rel = "contact/contact.db"
        let encPath = "\(dbDir)/\(rel)"
        guard FileManager.default.fileExists(atPath: encPath) else { return false }
        let cur = (try? FileManager.default.attributesOfItem(atPath: encPath)[.modificationDate]) as? Date
        if let cur = cur, let last = contactsMtime, cur == last, !contactCache.isEmpty {
            return false
        }
        try refreshIfChanged(relPath: rel)
        try loadContacts()
        contactsMtime = cur
        return true
    }

    func loadContacts() throws {
        let decPath = try getDecryptedDB(relativePath: "contact/contact.db")
        print("[WCHUD] loadContacts opening \(decPath)")
        var db: OpaquePointer?
        // immutable=1 tells SQLite to treat the file as a read-only snapshot
        // and skip WAL/SHM aux-file machinery — prevents SQLITE_CANTOPEN on
        // decrypted WAL-mode databases that don't have matching -wal/-shm.
        let uri = "file:\(decPath)?immutable=1"
        let openRc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard openRc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(openRc)"
            throw ReaderError.sqlError("Cannot open contact.db: \(msg)")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let prepRc = sqlite3_prepare_v2(db, "SELECT username, nick_name, remark FROM contact", -1, &stmt, nil)
        guard prepRc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReaderError.sqlError("Cannot query contacts (rc=\(prepRc)): \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        contactCache.removeAll(keepingCapacity: true)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let username = columnText(stmt, 0)
            let nickName = columnText(stmt, 1)
            let remark = columnText(stmt, 2)
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

    func findMessageDBs() -> [String] {
        keys.keys
            .filter { $0.contains("message/message_") && $0.hasSuffix(".db") }
            .sorted()
    }

    func findMsgTable(chatUsername: String, dbPath: String) throws -> String? {
        let hash = md5Hex(chatUsername)
        let tableName = "Msg_\(hash)"

        var db: OpaquePointer?
        guard Self.openReadonly(path: dbPath, db: &db) else {
            throw ReaderError.sqlError("Cannot open \(dbPath)")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        return sqlite3_step(stmt) == SQLITE_ROW ? tableName : nil
    }

    // MARK: - Message Queries

    func getMessages(chatUsername: String, limit: Int = 50, sinceLocalId: Int? = nil) throws -> [MessageInfo] {
        let msgDBs = findMessageDBs()
        var results: [MessageInfo] = []

        for relPath in msgDBs {
            let decPath = try getDecryptedDB(relativePath: relPath)
            guard let tableName = try findMsgTable(chatUsername: chatUsername, dbPath: decPath) else {
                continue
            }

            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else { continue }
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

                let contentRaw: Data?
                if let blob = sqlite3_column_blob(stmt, 4) {
                    let len = sqlite3_column_bytes(stmt, 4)
                    contentRaw = Data(bytes: blob, count: Int(len))
                } else {
                    contentRaw = nil
                }
                let ct = Int(sqlite3_column_int(stmt, 5))
                let contentStr = WeChatParser.decodeContent(contentRaw, ct: ct)
                let parsed = WeChatParser.renderMessage(content: contentStr, baseType: baseType, isGroup: isGroup)

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

    func countNewMessages(relPath: String, tableName: String, sinceLocalId: Int) throws -> Int {
        let decPath = try getDecryptedDB(relativePath: relPath)
        var db: OpaquePointer?
        guard Self.openReadonly(path: decPath, db: &db) else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM [\(tableName)] WHERE local_id > \(sinceLocalId)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func maxLocalId(relPath: String, tableName: String) throws -> Int {
        let decPath = try getDecryptedDB(relativePath: relPath)
        var db: OpaquePointer?
        guard Self.openReadonly(path: decPath, db: &db) else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT MAX(local_id) FROM [\(tableName)]"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func listAllChatTables() throws -> [(relPath: String, tableName: String, chatUsername: String)] {
        var results: [(String, String, String)] = []
        let msgDBs = findMessageDBs()

        for relPath in msgDBs {
            let decPath = try getDecryptedDB(relativePath: relPath)
            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else { continue }
            defer { sqlite3_close(db) }

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

    // MARK: - Memory-strategy cleanup

    /// For the `.memory` cache strategy: remove decrypted files after use so
    /// plaintext never lingers on disk. Call this after each scan cycle.
    func purgeEphemeralCache() {
        guard cacheStrategy == .memory else { return }
        let fm = FileManager.default
        for (rel, path) in decryptedCache {
            try? fm.removeItem(atPath: path)
            _ = rel
        }
        decryptedCache.removeAll(keepingCapacity: true)
        mainMtimes.removeAll(keepingCapacity: true)
        walMtimes.removeAll(keepingCapacity: true)
    }

    // MARK: - Manifest (persistent strategy only)

    private func loadManifest() {
        guard let data = FileManager.default.contents(atPath: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return
        }
        let fm = FileManager.default
        for (relPath, entry) in json {
            guard let cachedPath = entry["cachedPath"] as? String,
                  let encMtimeRaw = entry["encMtime"] as? Double,
                  let walMtimeRaw = entry["walMtime"] as? Double?,
                  fm.fileExists(atPath: cachedPath) else { continue }
            let encPath = "\(dbDir)/\(relPath)"
            guard fm.fileExists(atPath: encPath) else {
                try? fm.removeItem(atPath: cachedPath)
                continue
            }
            let walPath = encPath + "-wal"
            let curEnc = (try? fm.attributesOfItem(atPath: encPath)[.modificationDate]) as? Date
            let curWal = (try? fm.attributesOfItem(atPath: walPath)[.modificationDate]) as? Date

            // Current encryption mtime must match what we cached
            guard let curEnc = curEnc, curEnc.timeIntervalSince1970 == encMtimeRaw else {
                try? fm.removeItem(atPath: cachedPath)
                continue
            }

            decryptedCache[relPath] = cachedPath
            mainMtimes[relPath] = curEnc
            // WAL may have moved since; we'll detect via refreshIfChanged on first use
            if let walMtimeRaw = walMtimeRaw, let curWal = curWal, curWal.timeIntervalSince1970 == walMtimeRaw {
                walMtimes[relPath] = curWal
            } else if let curWal = curWal {
                // WAL differs — record current so refreshIfChanged will detect change
                walMtimes[relPath] = nil
                _ = curWal
            }
        }
    }

    private func saveManifest() {
        guard cacheStrategy == .persistent else { return }
        var json: [String: [String: Any]] = [:]
        for (relPath, cachedPath) in decryptedCache {
            var entry: [String: Any] = ["cachedPath": cachedPath]
            if let m = mainMtimes[relPath] {
                entry["encMtime"] = m.timeIntervalSince1970
            }
            if let w = walMtimes[relPath] {
                entry["walMtime"] = w.timeIntervalSince1970
            } else {
                entry["walMtime"] = 0.0
            }
            json[relPath] = entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: URL(fileURLWithPath: manifestPath))
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

    /// Open a decrypted DB read-only in "immutable" mode. Prevents SQLite
    /// from touching -wal / -shm sidecars, which is essential for decrypted
    /// snapshots that carry the WAL-mode header but have no matching WAL
    /// files next to them (→ SQLITE_CANTOPEN otherwise).
    static func openReadonly(path: String, db: inout OpaquePointer?) -> Bool {
        let uri = "file:\(path)?immutable=1"
        return sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
    }

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
