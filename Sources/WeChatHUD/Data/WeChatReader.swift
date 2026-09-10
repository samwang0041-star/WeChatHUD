import Foundation
import CryptoKit
import SQLite3

final class WeChatReader: ObservableObject, @unchecked Sendable {
    private let keysPath: String
    /// Used to compare pending connection settings with this running reader.
    /// This exposes only the file location, never the loaded access material.
    var configuredKeysPath: String { keysPath }
    let dbDir: String
    private let cacheDir: String
    private let cacheStrategy: CacheStrategy
    private let persistLearnedAliases: Bool
    private let aliasDefaults: UserDefaults
    private let manifestPath: String

    /// Recursive lock protecting all mutable dictionary state from concurrent access.
    /// ChatMonitor runs scans on a detached task while the main actor may read state;
    /// this lock serialises those accesses without requiring full actor isolation.
    /// Recursive because public methods (e.g. refreshIfChanged) call other locked
    /// methods (e.g. getDecryptedDB) internally.
    private let lock = NSRecursiveLock()

    private var keys: [String: Data] = [:]           // relative path → 32-byte key
    private var contactCache: [String: String] = [:] // username → display name
    /// Maps WeChat username / nick_name / remark to one canonical username
    /// when the alias is unambiguous. Prevents group member nicknames and
    /// local remarks from being treated as different people downstream.
    private var contactIdentityIndex: ContactIdentityIndex = .empty
    /// Room username → member display names. WeChat leaves ~30% of group
    /// rooms without any name in `contact`, so the member list is the only
    /// human-readable handle available for them.
    private var groupMemberNamesCache: [String: [String]] = [:]
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
    /// Cache: chatUsername → relPath of the DB that contains its Msg_ table.
    /// Avoids O(N_dbs) table lookups on every getMessages() call.
    private var chatDBCache: [String: String] = [:]
    /// Negative cache: chats we scanned all DBs for and found no table.
    /// Cleared on each refreshIfChanged so new tables are discovered.
    private var chatDBNegativeCache: Set<String> = []

    /// Reusable read-only handles, keyed by decrypted file path.
    ///
    /// Opening a decrypted DB is not cheap: SQLite parses the whole
    /// `sqlite_master` schema the first time a connection touches a file, and
    /// the largest message DB here holds 340 tables — one observed parse spent
    /// 4.6 s of CPU inside `sqlite3InitOne`. The old code opened a throwaway
    /// connection for the table probe and a second one for the query, so every
    /// `getMessages` paid that schema parse twice.
    private struct CachedHandle {
        let db: OpaquePointer
        var lastUsed: UInt64
    }
    private var handleCache: [String: CachedHandle] = [:]
    private var handleTick: UInt64 = 0
    /// Bounds resident page caches. The message corpus is a dozen files, so a
    /// smaller limit would evict and re-parse during every full scan.
    private static let handleCacheLimit = 16
    /// Number of times a fresh connection was actually opened. Exposed so tests
    /// can assert the hot path reuses one handle instead of re-parsing the
    /// schema per query, which is a timing-independent signal.
    private(set) var readHandleOpenCount = 0

    init(keysPath: String? = nil, dbDir: String? = nil, cacheStrategy: CacheStrategy = .persistent,
         persistLearnedAliases: Bool = true, userDefaults: UserDefaults = .standard) {
        let home = NSHomeDirectory()
        self.keysPath = keysPath ?? "\(home)/.wechat-cli/all_keys.json"
        self.dbDir = dbDir ?? Self.autoDetectDBDir() ?? ""
        self.cacheStrategy = cacheStrategy
        self.persistLearnedAliases = persistLearnedAliases
        self.aliasDefaults = userDefaults
        let accountDirectory = Self.cacheDir(for: cacheStrategy, databaseRoot: self.dbDir)
        self.cacheDir = cacheStrategy == .memory ? accountDirectory + "/" + UUID().uuidString : accountDirectory
        self.manifestPath = "\(self.cacheDir)/manifest.json"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDir)
        if cacheStrategy == .persistent {
            loadManifest()
        }
        // Hydrate learned group-chat self-aliases from last run so the
        // first scan after a restart already knows "我" vs "哆啦" and
        // the AI summarizer doesn't mis-attribute the user's own
        // messages on day one.
        if let saved = aliasDefaults.stringArray(forKey: learnedAliasesKey) {
            self.mySelfNames = Set(saved)
        }
    }

    deinit {
        for (_, stale) in handleCache { sqlite3_close(stale.db) }
        if cacheStrategy == .memory { try? FileManager.default.removeItem(atPath: cacheDir) }
    }

    private var learnedAliasesKey: String {
        "wchud.learnedSelfAliases." + Self.accountCacheIdentity(dbDir)
    }

    static func accountCacheIdentity(_ databaseRoot: String) -> String {
        let canonical = URL(fileURLWithPath: databaseRoot).standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func cacheDir(for strategy: CacheStrategy, databaseRoot: String) -> String {
        cacheDir(for: strategy) + "/" + accountCacheIdentity(databaseRoot)
    }

    /// Persist the current `mySelfNames` set to UserDefaults so it
    /// survives relaunches. Called after `getMessages` learns a new
    /// alias from a realSenderId==0 + hint pair.
    func learnSelfAlias(_ alias: String) {
        guard !alias.isEmpty else { return }
        mySelfNames.insert(alias)
        guard persistLearnedAliases else { return }
        aliasDefaults.set(Array(mySelfNames), forKey: learnedAliasesKey)
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

    /// Directory presence identifies candidates, not the account active in WeChat.
    static func databaseCandidates(baseDirectory: String? = nil) -> [String] {
        let base = baseDirectory ?? NSHomeDirectory() + "/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return contents.compactMap { item in
            let path = "\(base)/\(item)/db_storage"
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }.sorted()
    }

    static func autoDetectDBDir() -> String? {
        let candidates = databaseCandidates()
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Validate only the container shape and readability; callers never
    /// receive or persist key material from this check.
    static func validateKeyFile(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        return !dictionary.isEmpty
    }

    /// Only a unique directory candidate can be reported. This is not proof
    /// of the account currently logged into the running WeChat process.
    func detectCurrentAccountWxid() -> String? {
        guard let live = Self.autoDetectDBDir() else { return nil }
        let parts = live.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    /// A vanished configured root is actionable. Historical account directories
    /// cannot establish a live account switch, so do not guess from their order.
    func hasAccountSwitched() -> Bool {
        guard !dbDir.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: dbDir)
    }

    enum AccessMaterialState {
        case missing, unreadable, available
    }

    /// Availability only; successful database reads establish whether keys match.
    var accessMaterialState: AccessMaterialState {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: keysPath, isDirectory: &isDirectory) else { return .missing }
        return !isDirectory.boolValue && fm.isReadableFile(atPath: keysPath) ? .available : .unreadable
    }

    // MARK: - Key Loading

    func loadKeys(force: Bool = false) throws {
        try lock.withLock {
            let fm = FileManager.default
            let curMtime = (try? fm.attributesOfItem(atPath: keysPath)[.modificationDate]) as? Date
            if !force, let cur = curMtime, let last = keysMtime, cur == last {
                return  // unchanged, nothing to do
            }
            // Changed key material invalidates both discovery and decrypted snapshots.
            chatDBNegativeCache.removeAll()
            chatDBCache.removeAll()
            guard let data = fm.contents(atPath: keysPath) else {
                throw ReaderError.keyLoadFailed("Cannot read \(keysPath)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReaderError.keyLoadFailed("Invalid JSON in \(keysPath)")
            }

            if keysMtime != nil {
                decryptedCache.removeAll()
                mainMtimes.removeAll()
                walMtimes.removeAll()
                contactsMtime = nil
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

            // Both the re-decrypt and the WAL apply rewrite the file in place,
            // so a cached handle would now read a superseded snapshot.
            invalidateHandles(path: decPath)

            // Only the negative cache is dropped here. A positive mapping
            // records which DB holds a chat's table, and rewriting that DB does
            // not move the table out of it — clearing every mapping forced a
            // full O(N_dbs) re-probe of the whole whitelist on every WeChat
            // write, which is what kept the scan permanently behind. The
            // positive path still rescans when a table really has moved:
            // `getMessages` drops the single stale mapping and retries.
            if normalized.hasPrefix("message/") {
                chatDBNegativeCache.removeAll()
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

            let hash = Self.md5Hex(normalized)
            let decPath = "\(cacheDir)/\(hash).db"

            let staging = decPath + ".decrypt-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: staging) }
            try WeChatDecryptor.decryptDB(inputPath: encPath, outputPath: staging, key: key)

            let walPath = encPath + "-wal"
            if FileManager.default.fileExists(atPath: walPath) {
                try WeChatDecryptor.applyWAL(dbPath: staging, walPath: walPath, key: key)
            }
            guard rename(staging, decPath) == 0 else {
                throw ReaderError.sqlError("Cannot publish decrypted snapshot")
            }

            // The snapshot at this path was just replaced; drop any handle
            // still pointing at the previous contents.
            invalidateHandles(path: decPath)
            decryptedCache[normalized] = decPath
            return decPath
        }
    }

    func findKey(for path: String) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let filename = (normalized as NSString).lastPathComponent
        let candidates = keys.filter { keyPath, _ in
            let kp = keyPath.replacingOccurrences(of: "\\", with: "/")
            return kp == path || kp == normalized || (kp as NSString).lastPathComponent == filename
        }
        if candidates.isEmpty { return nil }

        let db = URL(fileURLWithPath: dbDir).standardizedFileURL.path
        let scoped = candidates.filter { keyPath, _ in
            let kp = keyPath.replacingOccurrences(of: "\\", with: "/")
            guard kp.hasPrefix("/") else { return false }
            let absolute = URL(fileURLWithPath: kp).standardizedFileURL.path
            return Self.keyPath(absolute, isUnderDatabaseRoot: db)
        }
        if !scoped.isEmpty {
            let unique = Set(scoped.map(\.value))
            return unique.count == 1 ? unique.first : nil
        }
        let hasAbsolute = candidates.contains { keyPath, _ in
            keyPath.replacingOccurrences(of: "\\", with: "/").hasPrefix("/")
        }
        // A shared key file that already names another account must not
        // fall back to a relative `message/message_0.db` entry.
        if hasAbsolute { return nil }
        let unique = Set(candidates.map(\.value))
        return unique.count == 1 ? unique.first : nil
    }

    static func keyPath(_ keyPath: String, isUnderDatabaseRoot db: String) -> Bool {
        guard !db.isEmpty else { return false }
        return keyPath == db || keyPath.hasPrefix(db + "/")
    }

    // MARK: - Contacts

    /// Reload contacts only if contact.db mtime changed since last load.
    @discardableResult
    func refreshContactsIfChanged(strict: Bool = false) throws -> Bool {
        try lock.withLock {
            let rel = "contact/contact.db"
            let encPath = "\(dbDir)/\(rel)"
            guard FileManager.default.fileExists(atPath: encPath) else {
                if strict { throw ReaderError.dbNotFound(encPath) }
                return false
            }
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
        // Cached handle, for the same reason as getMessages: contact.db carries
        // the whole contact schema and this runs on every scan.
        lock.lock()
        defer { lock.unlock() }
        let db = try acquireReadonly(path: decPath)

        var stmt: OpaquePointer?
        let prepRc = sqlite3_prepare_v2(db, "SELECT username, nick_name, remark FROM contact", -1, &stmt, nil)
        guard prepRc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReaderError.sqlError("Cannot query contacts (rc=\(prepRc)): \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var contactRecords: [ContactIdentityIndex.Record] = []
        var contactStep = sqlite3_step(stmt)
        while contactStep == SQLITE_ROW {
            let username = columnText(stmt, 0)
            let nickName = columnText(stmt, 1)
            let remark = columnText(stmt, 2)
            contactRecords.append(ContactIdentityIndex.Record(username: username, nickName: nickName, remark: remark))
            contactStep = sqlite3_step(stmt)
        }
        guard contactStep == SQLITE_DONE else {
            throw ReaderError.sqlError("Cannot finish reading contacts")
        }
        let identityIndex = ContactIdentityIndex.build(records: contactRecords)
        contactIdentityIndex = identityIndex
        contactCache = identityIndex.displayNameByUsername
        loadGroupMemberNames(db: db, knownNames: identityIndex.displayNameByUsername)

        // Rebuild self-name aliases. Merge the base set (wxid + legacy
        // short ID + contact.db display name) WITH any group-chat
        // nicknames previously learned via `getMessages`'s
        // realSenderId==0 branch — previously we `= [me]`'d which
        // threw away every learned alias on every contact.db refresh.
        // That's why the AI summarizer kept seeing the user's own
        // messages labelled as the group nickname (e.g. "哆啦") and
        // mis-attributing them to a bystander of the same name.
        let me = myUsername()
        if !me.isEmpty {
            var names = mySelfNames  // preserve learned aliases
            names.insert(me)
            // WeChat DB Name2Id may store the legacy short ID (without _xxxx suffix).
            // Add it so isFromSelf can match group messages using the old format.
            if let shortId = Self.legacyShortUsername(for: me) {
                names.insert(shortId)
                if let shortDisplay = contactCache[shortId], shortDisplay != shortId {
                    names.insert(shortDisplay)
                }
            }
            if let myDisplay = contactCache[me], myDisplay != me {
                names.insert(myDisplay)
            }
            mySelfNames = names
        }
    }

    /// Recover a member list for groups WeChat never named. `contact` has no
    /// row value for them (only `chat_room`/`chatroom_member` membership), so
    /// without this the UI would have to show a raw `…@chatroom` id.
    ///
    /// Runs while `contact.db` is already open in `loadContacts()`.
    private func loadGroupMemberNames(db: OpaquePointer?, knownNames: [String: String]) {
        var result: [String: [String]] = [:]
        var stmt: OpaquePointer?
        let sql = """
            SELECT r.username, n.username, c.nick_name, c.remark
            FROM chat_room r
            JOIN chatroom_member m ON m.room_id = r.id
            JOIN name2id n ON n.rowid = m.member_id
            LEFT JOIN contact c ON c.username = n.username
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let me = myUsername()
        let myShortId = Self.legacyShortUsername(for: me)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let room = columnText(stmt, 0)
            guard room.contains("@chatroom") else { continue }
            // Only nameless groups need the fallback; named groups keep
            // whatever WeChat itself shows.
            if let known = knownNames[room], known != ContactIdentityIndex.unnamedGroupPlaceholder { continue }

            let memberUsername = columnText(stmt, 1)
            // The user's own nickname says nothing about which group this is.
            if !me.isEmpty, memberUsername == me || memberUsername == myShortId { continue }

            let candidates = [columnText(stmt, 3), columnText(stmt, 2), knownNames[memberUsername] ?? ""]
            guard let name = candidates
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty && !$0.hasPrefix("wxid_") }) else { continue }

            var names = result[room] ?? []
            if !names.contains(name), names.count < 8 { names.append(name) }
            result[room] = names
        }
        groupMemberNamesCache = result

        // `contactCache` holds the placeholder for these rooms, and
        // `displayName(for:)` returns the first cache hit — so promote the
        // member-derived label into the cache, otherwise the placeholder
        // would keep winning.
        for (room, members) in result {
            guard let label = ContactIdentityIndex.memberDerivedGroupLabel(memberNames: members) else { continue }
            contactCache[room] = label
        }
    }

    func displayName(for username: String) -> String {
        lock.withLock {
            if let exact = contactCache[username] {
                return exact
            }
            if let shortId = Self.legacyShortUsername(for: username),
               let shortDisplay = contactCache[shortId] {
                return shortDisplay
            }
            if let display = contactIdentityIndex.displayName(for: username) {
                return display
            }
            if username.contains("@chatroom") {
                // WeChat has no name for this room. Fall back to who is in it
                // rather than the raw id, which means nothing to the user.
                if let members = groupMemberNamesCache[username],
                   let label = ContactIdentityIndex.memberDerivedGroupLabel(memberNames: members) {
                    return label
                }
                return ContactIdentityIndex.unnamedGroupPlaceholder
            }
            return username
        }
    }

    /// Member display names recovered for an unnamed group, if any.
    func groupMemberNames(for username: String) -> [String] {
        lock.withLock { groupMemberNamesCache[username] ?? [] }
    }

    /// True when WeChat itself has no name for this chat — `contact.db`
    /// carries the row but with an empty `nick_name`/`remark`. Whatever the
    /// UI shows for such a chat is a placeholder or a member-derived guess.
    func hasWeChatName(for username: String) -> Bool {
        lock.withLock {
            guard let name = contactIdentityIndex.weChatNameByUsername[username] else { return false }
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func canonicalContactUsername(for usernameOrAlias: String) -> String? {
        lock.withLock {
            contactIdentityIndex.canonicalUsername(for: usernameOrAlias)
        }
    }

    func normalizeContactMentions(in text: String) -> String {
        lock.withLock {
            contactIdentityIndex.normalizeMentions(in: text)
        }
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

    static func legacyShortUsername(for username: String) -> String? {
        guard let underscoreRange = username.range(of: "_", options: .backwards) else {
            return nil
        }
        let suffix = username[underscoreRange.upperBound...]
        guard suffix.count == 4, suffix.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let shortId = String(username[..<underscoreRange.lowerBound])
        return shortId.isEmpty ? nil : shortId
    }

    // MARK: - Sessions (unread state)

    /// Read `session/session.db` → `SessionTable`. Returns one row per
    /// chat; callers typically filter on `unreadCount > 0`.
    func getSessions() throws -> [SessionInfo] {
        let rel = "session/session.db"
        guard keys[rel] != nil else { return [] }
        _ = try? refreshIfChanged(relPath: rel)
        let decPath = try getDecryptedDB(relativePath: rel)
        // Reuse the cached handle: a throwaway connection re-parsed session.db's
        // whole schema on every scan, twice per scan here.
        lock.lock()
        defer { lock.unlock() }
        let db = try acquireReadonly(path: decPath)

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
            .filter {
                $0.contains("message/message_") && $0.hasSuffix(".db")
                && !$0.contains("message_fts") && !$0.contains("message_resource")
            }
            .sorted()
    }

    /// Probe for a chat's `Msg_<md5>` table on an already-open handle.
    static func msgTableName(chatUsername: String, db: OpaquePointer) -> String? {
        let hash = md5Hex(chatUsername)
        let tableName = "Msg_\(hash)"

        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let result = sqlite3_step(stmt)
        return result == SQLITE_ROW ? tableName : nil
    }

    func findMsgTable(chatUsername: String, dbPath: String) throws -> String? {
        try withReadonlyDB(path: dbPath) { db in
            Self.msgTableName(chatUsername: chatUsername, db: db)
        }
    }

    // MARK: - Message Queries

    func getMessages(chatUsername: String, limit: Int = 50, sinceLocalId: Int? = nil) throws -> [MessageInfo] {
        try getMessages(chatUsername: chatUsername, limit: limit, sinceLocalId: sinceLocalId,
                        afterCursor: nil)
    }

    func getMessages(chatUsername: String, limit: Int = 50, sinceLocalId: Int? = nil,
                     afterCursor: (lastCreateTime: Int, lastLocalId: Int)?,
                     oldestFirst: Bool = false,
                     startTime: Int? = nil, endTime: Int? = nil,
                     beforeCursor: (lastCreateTime: Int, lastLocalId: Int)? = nil) throws -> [MessageInfo] {
        lock.lock()
        defer { lock.unlock() }
        var results: [MessageInfo] = []
        var foundTable = false
        let usedCachedMapping = chatDBCache[chatUsername] != nil

        // Negative cache: we already scanned all DBs and this chat has no table.
        if chatDBNegativeCache.contains(chatUsername) {
            return []
        }

        // Determine which DB(s) to search. Fast path: use cached mapping.
        let dbsToSearch: [String]
        if let cachedRel = chatDBCache[chatUsername] {
            dbsToSearch = [cachedRel]
        } else {
            dbsToSearch = findMessageDBs()
        }

        for relPath in dbsToSearch {
            let decPath = try getDecryptedDB(relativePath: relPath)
            // One handle serves both the table probe and the query, and stays
            // cached for later calls. This method already holds `lock`, so the
            // handle cannot be invalidated mid-query.
            let db = try acquireReadonly(path: decPath)
            guard let tableName = Self.msgTableName(chatUsername: chatUsername, db: db) else {
                continue
            }
            foundTable = true
            // Remember this mapping for future calls.
            chatDBCache[chatUsername] = relPath

            var sql = """
                SELECT local_id, local_type, create_time, real_sender_id,
                       message_content, WCDB_CT_message_content
                FROM [\(tableName)]
            """
            sql += Self.messageQuerySuffix(limit: limit, sinceLocalId: sinceLocalId,
                                           afterCursor: afterCursor, oldestFirst: oldestFirst,
                                           startTime: startTime, endTime: endTime,
                                           beforeCursor: beforeCursor)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ReaderError.sqlError("Cannot query messages: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }

            let name2id = loadName2Id(db: db)
            let isGroup = chatUsername.contains("@chatroom")
            let chatName = displayName(for: chatUsername)

            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
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
                let me = myUsername()

                // Any known self-identity marker (wxid, short ID,
                // contact.db display name, or a previously-learned
                // group nickname) that shows up as senderUsername
                // gets promoted to the canonical wxid immediately.
                // This catches the case where WeChat's Name2Id stores
                // the user's OWN row with value = group nickname —
                // without this, the nickname stayed as the sender
                // and the AI summarizer couldn't tell it was the
                // user talking.
                if !senderUsername.isEmpty {
                    if senderUsername == me || mySelfNames.contains(senderUsername) {
                        senderUsername = me
                    } else if let canonical = canonicalContactUsername(for: senderUsername) {
                        senderUsername = canonical
                    }
                }

                // In group chats where the lookup yielded nothing
                // (name2id hit nothing), we try additional heuristics:
                //   1. `parsed.senderHint` is already a known self
                //      alias → promote.
                //   2. `realSenderId == 0` — WeChat stores 0 for the
                //      user's own messages in Name2Id-indexed group
                //      tables. Learn the hint so future lookups are
                //      fast, and persist it so a restart doesn't
                //      reset the knowledge.
                if isGroup && name2id[realSenderId] == nil {
                    let hint = parsed.senderHint
                    if mySelfNames.contains(hint) {
                        senderUsername = me
                    } else if let canonical = canonicalContactUsername(for: hint) {
                        senderUsername = canonical
                    } else if realSenderId == 0 && !hint.isEmpty {
                        learnSelfAlias(hint)
                        senderUsername = me
                    }
                }
                let senderName = displayName(for: senderUsername)

                let uid = "\(relPath)/\(tableName)/\(localId)"
                let msg = MessageInfo(
                    id: uid,
                    localId: localId,
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
                stepResult = sqlite3_step(stmt)
            }
            guard stepResult == SQLITE_DONE else {
                throw ReaderError.sqlError("Message query interrupted: \(String(cString: sqlite3_errmsg(db)))")
            }
            break  // Msg_<hash> table lives in exactly one DB — no need to check others.
        }

        // Cache miss: cached DB no longer has this table. Retry with full scan.
        if !foundTable && usedCachedMapping {
            chatDBCache.removeValue(forKey: chatUsername)
            return try getMessages(chatUsername: chatUsername, limit: limit, sinceLocalId: sinceLocalId,
                                   afterCursor: afterCursor, oldestFirst: oldestFirst,
                                           startTime: startTime, endTime: endTime,
                                           beforeCursor: beforeCursor)
        }

        // Full scan found nothing — remember so we skip next time.
        if !foundTable {
            chatDBNegativeCache.insert(chatUsername)
        }

        // SQLite has already applied the requested composite ordering.
        return results
    }

    /// A bounded oldest-first page ensures a scan advances only over messages it read.
    /// The local ID tie-breaker preserves messages sharing the same second.
    static func messageQuerySuffix(
        limit: Int, sinceLocalId: Int? = nil,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)? = nil,
        oldestFirst: Bool = false,
        startTime: Int? = nil, endTime: Int? = nil,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)? = nil
    ) -> String {
        var predicates: [String] = []
        if let sinceLocalId { predicates.append("local_id > \(sinceLocalId)") }
        if let cursor = afterCursor {
            predicates.append("(create_time > \(cursor.lastCreateTime) OR (create_time = \(cursor.lastCreateTime) AND local_id > \(cursor.lastLocalId)))")
        }
        // The upper composite bound includes the anchor and excludes later rows
        // in its second before LIMIT is applied.
        if let cursor = beforeCursor {
            predicates.append("(create_time < \(cursor.lastCreateTime) OR (create_time = \(cursor.lastCreateTime) AND local_id <= \(cursor.lastLocalId)))")
        }
        // Date filters belong in SQL before LIMIT, so historical days remain reachable.
        if let startTime { predicates.append("create_time >= \(startTime)") }
        if let endTime { predicates.append("create_time < \(endTime)") }
        let direction = oldestFirst ? "ASC" : "DESC"
        let condition = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        return condition + " ORDER BY create_time \(direction), local_id \(direction) LIMIT \(max(1, limit))"
    }

    /// Bulk stats across all message tables for given chat usernames.
    /// Much faster than calling getMessages per chat — scans each DB file once.
    struct BulkChatStats {
        let chatUsername: String
        let totalCount: Int
        let selfCount: Int
        let senderCounts: [String: Int]  // senderUsername → count
        let hourlyBuckets: [Int]         // 24 hours
        let weekdayBuckets: [Int]        // 7 days (0=Sun, 1=Mon, ..., 6=Sat)
        let typeCounts: [Int: Int]       // baseType → count
        let selfInitiated: Bool          // first message in window is from self
        let earliestTs: Int
        let latestTs: Int
    }

    func bulkMessageStats(
        chatUsernames: [String],
        selfNames: Set<String>,
        sinceTsEpoch: Int = 0
    ) -> [String: BulkChatStats] {
        // Build chatUsername → (tableName, chatUsername) map
        let chatToTable: [(chatUsername: String, tableName: String)] = chatUsernames.map {
            ($0, "Msg_\(Self.md5Hex($0))")
        }
        // Group by table name for O(1) lookup
        let tableToChat = Dictionary(uniqueKeysWithValues: chatToTable.map { ($0.tableName, $0.chatUsername) })
        let targetTables = Set(chatToTable.map(\.tableName))

        let msgDBs = findMessageDBs()
        var result: [String: BulkChatStats] = [:]

        for relPath in msgDBs {
            guard let decPath = try? getDecryptedDB(relativePath: relPath) else { continue }
            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else { continue }
            defer { sqlite3_close(db) }

            // Find which target tables exist in this DB
            var tableStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'", -1, &tableStmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(tableStmt) }

            var foundTables: [String] = []
            while sqlite3_step(tableStmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(tableStmt, 0))
                if targetTables.contains(name) { foundTables.append(name) }
            }
            guard !foundTables.isEmpty else { continue }

            let name2id = loadName2Id(db: db)

            for table in foundTables {
                guard let chatUsername = tableToChat[table] else { continue }
                let whereClause = sinceTsEpoch > 0 ? "WHERE create_time >= \(sinceTsEpoch)" : ""

                let sql = "SELECT real_sender_id, create_time, local_type FROM [\(table)] \(whereClause) ORDER BY create_time ASC"
                var sStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &sStmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(sStmt) }

                let cal = Calendar.current
                var senderCounts: [String: Int] = [:]
                var hourly = Array(repeating: 0, count: 24)
                var weekday = Array(repeating: 0, count: 7)
                var typeCounts: [Int: Int] = [:]
                var total = 0
                var selfCount = 0
                var firstSenderIsSelf = false
                var earliestTs = Int.max
                var latestTs = 0

                while sqlite3_step(sStmt) == SQLITE_ROW {
                    let senderId = Int(sqlite3_column_int64(sStmt, 0))
                    let createTime = Int(sqlite3_column_int64(sStmt, 1))
                    let localType = Int(sqlite3_column_int64(sStmt, 2))
                    let baseType = localType & 0xFFFFFFFF

                    let senderKey = name2id[senderId] ?? "id_\(senderId)"
                    let isSelf = selfNames.contains(senderKey) || senderId == 0
                    senderCounts[senderKey, default: 0] += 1
                    if isSelf { selfCount += 1 }
                    if total == 0 { firstSenderIsSelf = isSelf }

                    let date = Date(timeIntervalSince1970: Double(createTime))
                    hourly[cal.component(.hour, from: date)] += 1
                    weekday[cal.component(.weekday, from: date) - 1] += 1  // 1=Sun→0
                    typeCounts[baseType, default: 0] += 1

                    if createTime < earliestTs { earliestTs = createTime }
                    if createTime > latestTs { latestTs = createTime }
                    total += 1
                }
                guard total > 0 else { continue }

                result[chatUsername] = BulkChatStats(
                    chatUsername: chatUsername,
                    totalCount: total,
                    selfCount: selfCount,
                    senderCounts: senderCounts,
                    hourlyBuckets: hourly,
                    weekdayBuckets: weekday,
                    typeCounts: typeCounts,
                    selfInitiated: firstSenderIsSelf,
                    earliestTs: earliestTs,
                    latestTs: latestTs
                )
            }
        }
        return result
    }

    func countNewMessages(relPath: String, tableName: String, sinceLocalId: Int) throws -> Int {
        let decPath = try getDecryptedDB(relativePath: relPath)
        lock.lock()
        defer { lock.unlock() }
        guard let db = try? acquireReadonly(path: decPath) else { return 0 }

        let sql = "SELECT COUNT(*) FROM [\(tableName)] WHERE local_id > \(sinceLocalId)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func maxLocalId(relPath: String, tableName: String) throws -> Int {
        let decPath = try getDecryptedDB(relativePath: relPath)
        lock.lock()
        defer { lock.unlock() }
        guard let db = try? acquireReadonly(path: decPath) else { return 0 }

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
    func topActiveContacts(limit: Int = 20, strict: Bool = false) throws -> [ActiveContact] {
        lock.lock()
        defer { lock.unlock() }
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
        for u in eligible { hashToUsername[Self.md5Hex(u)] = u }

        // ---- 2. Pass 1: sqlite_sequence → total + table location ------
        struct TableRef { let relPath: String; let tableName: String }
        var tablesByUsername: [String: [TableRef]] = [:]
        var totalCounts: [String: Int] = [:]

        let msgDBs = findMessageDBs()
        if strict && msgDBs.isEmpty {
            throw ReaderError.dbNotFound("\(dbDir)/message")
        }
        for relPath in msgDBs {
            do {
                _ = try refreshIfChanged(relPath: relPath)
            } catch {
                if strict { throw error }
                continue
            }
            let decPath: String
            do { decPath = try getDecryptedDB(relativePath: relPath) }
            catch {
                if strict { throw error }
                continue
            }

            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else {
                if strict { throw ReaderError.sqlError("Cannot open message database") }
                continue
            }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "SELECT name, seq FROM sqlite_sequence WHERE name LIKE 'Msg_%'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if strict { throw ReaderError.sqlError("Cannot query sqlite_sequence: \(String(cString: sqlite3_errmsg(db)))") }
                continue
            }
            defer { sqlite3_finalize(stmt) }

            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(stmt, 0) else {
                    stepResult = sqlite3_step(stmt)
                    continue
                }
                let table = String(cString: namePtr)
                if table.hasPrefix("Msg_") {
                    let hash = String(table.dropFirst(4))
                    if let username = hashToUsername[hash] {
                        let seq = Int(sqlite3_column_int64(stmt, 1))
                        totalCounts[username, default: 0] += seq
                        tablesByUsername[username, default: []].append(
                            TableRef(relPath: relPath, tableName: table)
                        )
                    }
                }
                stepResult = sqlite3_step(stmt)
            }
            if strict && stepResult != SQLITE_DONE {
                throw ReaderError.sqlError("Message table scan interrupted: \(String(cString: sqlite3_errmsg(db)))")
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
            catch {
                if strict { throw error }
                continue
            }

            var db: OpaquePointer?
            guard Self.openReadonly(path: decPath, db: &db) else {
                if strict { throw ReaderError.sqlError("Cannot open message database") }
                continue
            }
            defer { sqlite3_close(db) }

            for (username, table) in work {
                var stmt: OpaquePointer?
                let sql = "SELECT COUNT(*) FROM [\(table)] WHERE create_time > \(cutoff)"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    if strict { throw ReaderError.sqlError("Cannot query message table: \(String(cString: sqlite3_errmsg(db)))") }
                    continue
                }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    recentCounts[username, default: 0] += Int(sqlite3_column_int64(stmt, 0))
                } else if strict {
                    let message = String(cString: sqlite3_errmsg(db))
                    sqlite3_finalize(stmt)
                    throw ReaderError.sqlError("Message count query failed: \(message)")
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
            let tableNames = try withReadonlyDB(path: decPath) { db -> [String] in
                var stmt: OpaquePointer?
                let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                var names: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    names.append(columnText(stmt, 0))
                }
                return names
            }
            for tableName in tableNames { results.append((relPath, tableName, "")) }
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
            invalidateHandles()
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
                  entry["accountIdentity"] as? String == Self.accountCacheIdentity(dbDir),
                  URL(fileURLWithPath: cachedPath).deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: cacheDir).standardizedFileURL.path,
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
            var entry: [String: Any] = ["cachedPath": cachedPath, "accountIdentity": Self.accountCacheIdentity(dbDir)]
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
        try? data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath)
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

    // MARK: - Reusable read handles

    /// Open (or reuse) a read-only handle for a decrypted DB.
    ///
    /// Callers must hold `lock` for as long as they use the handle: a
    /// concurrent `refreshIfChanged` rewrites decrypted files in place, and a
    /// handle is only guaranteed to match the snapshot that was current when it
    /// was opened. `withReadonlyDB` is the safe wrapper.
    private func acquireReadonly(path: String) throws -> OpaquePointer {
        handleTick &+= 1
        if let cached = handleCache[path] {
            handleCache[path]?.lastUsed = handleTick
            return cached.db
        }
        var db: OpaquePointer?
        guard Self.openReadonly(path: path, db: &db), let opened = db else {
            throw ReaderError.sqlError("Cannot open \(path)")
        }
        evictStaleHandles()
        readHandleOpenCount += 1
        handleCache[path] = CachedHandle(db: opened, lastUsed: handleTick)
        return opened
    }

    /// Least-recently-used eviction, so a large corpus cannot pin an unbounded
    /// number of SQLite page caches.
    private func evictStaleHandles() {
        while handleCache.count >= Self.handleCacheLimit,
              let victim = handleCache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            if let stale = handleCache.removeValue(forKey: victim) { sqlite3_close(stale.db) }
        }
    }

    /// Close cached handles whose file has been rewritten. `immutable=1`
    /// disables SQLite's own change detection, so a handle left open across a
    /// re-decrypt would keep serving the superseded snapshot.
    private func invalidateHandles(path: String? = nil) {
        if let path {
            if let stale = handleCache.removeValue(forKey: path) { sqlite3_close(stale.db) }
            return
        }
        for (_, stale) in handleCache { sqlite3_close(stale.db) }
        handleCache.removeAll(keepingCapacity: true)
    }

    /// Run `body` against a reusable read-only handle, holding `lock` so the
    /// decrypted file cannot be rewritten underneath it.
    func withReadonlyDB<T>(path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            let db = try acquireReadonly(path: path)
            return try body(db)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }

    static func md5Hex(_ input: String) -> String {
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
