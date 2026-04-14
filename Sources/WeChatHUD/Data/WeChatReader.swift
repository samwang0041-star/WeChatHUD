import Foundation
import CryptoKit
import SQLite3

final class WeChatReader: ObservableObject, @unchecked Sendable {
    private let keysPath: String
    let dbDir: String
    private let cacheDir: String
    private let cacheStrategy: CacheStrategy
    private let manifestPath: String

    /// Recursive lock protecting all mutable dictionary state from concurrent access.
    /// ChatMonitor runs scans on a detached task while the main actor may read state;
    /// this lock serialises those accesses without requiring full actor isolation.
    /// Recursive because public methods (e.g. refreshIfChanged) call other locked
    /// methods (e.g. getDecryptedDB) internally.
    private let lock = NSRecursiveLock()

    private var keys: [String: Data] = [:]           // relative path → 32-byte key
    private var contactCache: [String: String] = [:] // username → display name
    /// All known aliases for the current user (wxid, nicknames from contact.db,
    /// and senderHint names learned from group messages where name2id failed).
    /// Used by isFromSelf to catch group chat messages where the sender is
    /// stored as a display name instead of wxid.
    private(set) var mySelfNames: Set<String> = []
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
        try lock.withLock {
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
        try lock.withLock {
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
    }

    // MARK: - DB Access

    /// Get a decrypted, readable SQLite DB for the given relative path.
    func getDecryptedDB(relativePath: String) throws -> String {
        try lock.withLock {
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
        try lock.withLock {
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

        // Build self-name aliases: wxid + any display name from contact.db
        let me = myUsername()
        if !me.isEmpty {
            mySelfNames = [me]
            if let myDisplay = contactCache[me], myDisplay != me {
                mySelfNames.insert(myDisplay)
            }
            print("[WCHUD] mySelfNames: \(mySelfNames)")
        }
    }

    func displayName(for username: String) -> String {
        lock.withLock { contactCache[username] ?? username }
    }

    // MARK: - Self (my username)

    /// Extract the user's own wxid from the dbDir path. WeChat organizes
    /// per-account data under `xwechat_files/<wxid>/db_storage`, so we
    /// can grab the second-to-last path component cheaply instead of
    /// parsing contact.db for a self marker.
    func myUsername() -> String {
        let parts = dbDir.split(separator: "/")
        // .../xwechat_files/<wxid>/db_storage
        guard parts.count >= 2 else { return "" }
        return String(parts[parts.count - 2])
    }

    // MARK: - Sessions (unread state)

    /// Read `session/session.db` → `SessionTable`. Returns one row per
    /// chat; callers typically filter on `unreadCount > 0`.
    func getSessions() throws -> [SessionInfo] {
        let rel = "session/session.db"
        guard keys[rel] != nil else { return [] }
        _ = try? refreshIfChanged(relPath: rel)
        let decPath = try getDecryptedDB(relativePath: rel)
        var db: OpaquePointer?
        guard Self.openReadonly(path: decPath, db: &db) else {
            throw ReaderError.sqlError("Cannot open session.db")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT username, unread_count, last_timestamp FROM SessionTable"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("Cannot query SessionTable: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        var results: [SessionInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let username = columnText(stmt, 0)
            let unread = Int(sqlite3_column_int64(stmt, 1))
            let ts = Int(sqlite3_column_int64(stmt, 2))
            results.append(SessionInfo(
                username: username,
                isGroup: username.contains("@chatroom"),
                unreadCount: unread,
                lastTimestamp: ts
            ))
        }
        return results
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

                var senderUsername = name2id[realSenderId] ?? parsed.senderHint
                // In group chats, name2id lookup can fail for the user's own
                // messages because Name2Id only stores *other* members. Two
                // detection strategies, in order of confidence:
                //   1. hint is already a known self alias (wxid / contact name /
                //      previously-learned group nickname).
                //   2. realSenderId == 0 — WeChat stores 0 for the user's own
                //      messages in Name2Id-indexed group tables.
                // When either matches, learn the hint so future lookups are fast.
                if isGroup && name2id[realSenderId] == nil {
                    let hint = parsed.senderHint
                    if mySelfNames.contains(hint) {
                        senderUsername = myUsername()
                    } else if realSenderId == 0 && !hint.isEmpty {
                        mySelfNames.insert(hint)
                        print("[WCHUD] learned self alias from group: '\(hint)'")
                        senderUsername = myUsername()
                    }
                }
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
                    createTime: createTime,
                    appType: parsed.appType
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

    /// One candidate for smart whitelist import. All scoring inputs are
    /// preserved so the UI (and the user) can see *why* a contact ranked.
    struct ActiveContact {
        let username: String
        let displayName: String
        let isGroup: Bool
        /// Messages exchanged in the last 45 days — the primary signal.
        let recentCount: Int
        /// All-time message count per `sqlite_sequence.seq`. Used as a
        /// baseline pre-filter, not in the final ranking.
        let totalCount: Int
        /// Final rank score. Higher is more important.
        let score: Double
    }

    /// Smart whitelist ranking.
    ///
    /// Strategy — combine multiple signals instead of raw volume so the
    /// top-N is actually who you *talk to*, not who broadcasts at you:
    ///
    /// 1. **Noise filter.** Drop WeChat system accounts, public accounts
    ///    (`gh_*`), file transfer, WeCom bridges, news feeds, etc. These
    ///    dominate a naive ranking but none are real conversations.
    ///
    /// 2. **Baseline threshold.** Individuals need ≥ 30 total messages,
    ///    groups need ≥ 150. Chats below the floor are pruned before the
    ///    expensive pass-2 query.
    ///
    /// 3. **Recency window.** Rank by messages in the last 45 days, not
    ///    all-time, so old-but-dead conversations don't crowd out current
    ///    VIPs. A `COUNT(*) WHERE create_time > cutoff` per table reads
    ///    the table but doesn't decode blobs so it's cheap even at 10k
    ///    rows per chat.
    ///
    /// 4. **Group penalty.** Groups are multiplied by 0.35 because they
    ///    naturally have ~5-10× the volume per "interesting" event, and
    ///    most of that volume is off-topic chatter.
    ///
    /// 5. **Dead-chat cut.** Require ≥ 5 (individual) / ≥ 15 (group) new
    ///    messages in the window. Otherwise we'd import stale chats that
    ///    happened to have a lot of history.
    ///
    /// Cost: one `sqlite_sequence` scan per DB (pass 1, ~ms) + one
    /// per-table COUNT for the filtered subset (pass 2, typically well
    /// under 1 s total because the baseline threshold prunes heavily).
    func topActiveContacts(limit: Int = 20) throws -> [ActiveContact] {
        let contacts = contactCache
        guard !contacts.isEmpty else { return [] }

        // ---- 1. Noise filter ------------------------------------------
        let noisePrefixes: [String] = [
            "gh_",                // 公众号 official accounts
            "fmessage",           // friend-request stream
            "filehelper",         // 文件传输助手
            "medianote",          // Apple-device note bridge
            "newsapp",            // news broadcast
            "notification_",      // system notifications
            "notifymessage",
            "floatbottle",
            "qqmail",
            "brandsessionholder", // brand/official session container
            "masssend",           // mass-send placeholder
            "officialaccounts",
            "voip",
            "blogapp",
            "tmessage",
        ]
        let noiseExact: Set<String> = [
            "weixin", "qqmail", "qqsync", "qqsafe", "facebook", "voipapp",
            "masssendapp", "feedsapp",
        ]
        func isNoise(_ u: String) -> Bool {
            if noiseExact.contains(u) { return true }
            if u.contains("@openim") { return true }       // WeCom bridge
            if u.contains("@im.chatroom") { return true }  // invalid/legacy
            for p in noisePrefixes where u.hasPrefix(p) { return true }
            return false
        }

        let eligible = contacts.keys.filter { !isNoise($0) }
        guard !eligible.isEmpty else { return [] }

        var hashToUsername: [String: String] = [:]
        hashToUsername.reserveCapacity(eligible.count)
        for u in eligible { hashToUsername[md5Hex(u)] = u }

        // ---- 2. Pass 1: sqlite_sequence → total + table location ------
        struct TableRef { let relPath: String; let tableName: String }
        var tablesByUsername: [String: [TableRef]] = [:]
        var totalCounts: [String: Int] = [:]

        let msgDBs = findMessageDBs()
        for relPath in msgDBs {
            _ = try? refreshIfChanged(relPath: relPath)
            let decPath: String
            do { decPath = try getDecryptedDB(relativePath: relPath) }
            catch { continue }

            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else { continue }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "SELECT name, seq FROM sqlite_sequence WHERE name LIKE 'Msg_%'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
                let table = String(cString: namePtr)
                guard table.hasPrefix("Msg_") else { continue }
                let hash = String(table.dropFirst(4))
                guard let username = hashToUsername[hash] else { continue }
                let seq = Int(sqlite3_column_int64(stmt, 1))
                totalCounts[username, default: 0] += seq
                tablesByUsername[username, default: []].append(
                    TableRef(relPath: relPath, tableName: table)
                )
            }
        }

        // ---- 3. Baseline threshold prune ------------------------------
        let baselineFiltered = totalCounts.filter { username, total in
            let isGroup = username.contains("@chatroom")
            return total >= (isGroup ? 150 : 30)
        }
        guard !baselineFiltered.isEmpty else { return [] }

        // ---- 4. Pass 2: COUNT(*) in last 45 days, grouped by db -------
        let cutoff = Int(Date().timeIntervalSince1970) - 45 * 24 * 3600

        // Group (username, tableName) by DB so each DB is opened once.
        var workByDB: [String: [(String, String)]] = [:]  // relPath → (username, tableName)
        for (username, _) in baselineFiltered {
            guard let refs = tablesByUsername[username] else { continue }
            for ref in refs {
                workByDB[ref.relPath, default: []].append((username, ref.tableName))
            }
        }

        var recentCounts: [String: Int] = [:]
        for (relPath, work) in workByDB {
            let decPath: String
            do { decPath = try getDecryptedDB(relativePath: relPath) }
            catch { continue }

            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else { continue }
            defer { sqlite3_close(db) }

            for (username, table) in work {
                var stmt: OpaquePointer?
                let sql = "SELECT COUNT(*) FROM [\(table)] WHERE create_time > \(cutoff)"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    recentCounts[username, default: 0] += Int(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }

        // ---- 5. Score, dead-chat cut, rank ----------------------------
        let candidates: [ActiveContact] = recentCounts.compactMap { username, recent in
            let isGroup = username.contains("@chatroom")
            let deadFloor = isGroup ? 15 : 5
            guard recent >= deadFloor else { return nil }
            let groupPenalty: Double = isGroup ? 0.35 : 1.0
            let score = Double(recent) * groupPenalty
            return ActiveContact(
                username: username,
                displayName: contacts[username] ?? username,
                isGroup: isGroup,
                recentCount: recent,
                totalCount: totalCounts[username] ?? 0,
                score: score
            )
        }

        return candidates
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
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
        lock.withLock {
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
        let digest = Insecure.MD5.hash(data: data)
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
