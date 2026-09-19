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

    /// Debounced manifest persistence (`.persistent` strategy only).
    ///
    /// `refreshIfChanged` used to rewrite the entire manifest synchronously, so
    /// a scan that touched a dozen message DBs paid a dozen full JSON
    /// serializations, atomic writes and `setAttributes` calls. The trade-off is
    /// explicit: a crash inside the debounce window loses at most the entries
    /// recorded during that window, and a lost entry only means the next launch
    /// re-decrypts that DB because the manifest is an index over the cache, not
    /// the cache itself.
    private static let manifestFlushDebounce: TimeInterval = 4.0
    private var manifestDirty = false
    private var manifestFlushWorkItem: DispatchWorkItem?
    /// Serial queue the debounced flush runs on, off the scan's critical path.
    private let manifestFlushQueue = DispatchQueue(label: "com.wechathud.reader.manifest-flush")
    /// Manifest writes actually performed. Exposed so tests can assert that a
    /// burst of refreshes collapses into one write.
    private(set) var manifestWriteCount = 0

    /// Recursive lock protecting all mutable dictionary state from concurrent access.
    /// ChatMonitor runs scans on a detached task while the main actor may read state;
    /// this lock serialises those accesses without requiring full actor isolation.
    /// Recursive because public methods (e.g. refreshIfChanged) call other locked
    /// methods (e.g. getDecryptedDB) internally.
    private let lock = NSRecursiveLock()

    /// Guards the three naming caches below (`contactCache`,
    /// `contactIdentityIndex`, `groupMemberNamesCache`) for readers that never
    /// touch a database — the name every inbox row renders.
    ///
    /// Those lookups used to take `lock`, which `getDecryptedDB` holds across a
    /// whole-shard read plus a page-by-page AES pass. A background scan
    /// therefore froze the island mid-animation for as long as that shard took,
    /// for a lookup that reads no database at all. Readers take `namingLock`
    /// and nothing else; writers take `lock` first and then `namingLock`, so no
    /// path can hold `namingLock` while waiting for `lock`.
    private let namingLock = NSRecursiveLock()

    private var keys: [String: Data] = [:]           // relative path → 32-byte key

    /// Precomputed candidate sets for `findKey(for:)`, keyed by file name.
    ///
    /// `findKey` used to filter the entire key dictionary on every call, and a
    /// scan calls it several times per DB (`getDecryptedDB`, the WAL apply,
    /// `getSessions`). Candidate selection can only ever accept keys whose
    /// `lastPathComponent` equals the queried file name — an exact-path match
    /// always carries the same file name — so one bucket per file name answers
    /// the query without touching the rest of the key file.
    private struct KeyCandidateBucket {
        /// Distinct `enc_key` values across all candidates. `findKey` only
        /// returns a value when this collapses to exactly one entry.
        var distinctValues: Set<Data> = []
        /// Distinct values among candidates whose absolute path lives under
        /// `dbDir` — the scoped branch of `findKey`.
        var scopedValues: Set<Data> = []
        /// Whether any candidate is written as an absolute path. A key file
        /// that already names another account must not fall back to a
        /// relative entry.
        var hasAbsolute = false
    }

    private var keyIndex: [String: KeyCandidateBucket] = [:]
    /// True once `loadKeys` has built `keyIndex` for the current `keys`
    /// dictionary. Distinguishes "no candidate for this file name" (nil, no
    /// scan needed) from "index not built" (fall back to scanning).
    private var keyIndexIsWarm = false
    /// Keys addressed by database header salt instead of by path.
    ///
    /// Populated from a schema-2 salt map, and consulted when a path lookup
    /// fails. This is what makes a lookup survive a database that was renamed
    /// or moved, and what lets a key set collected without paths be used at
    /// all. The salt is already present in this project’s own key
    /// files, so this needs no new material from anyone.
    private var saltKeys: [String: Data] = [:]
    /// Entries in the loaded key file that were recognised and usable.
    private(set) var recognizedKeyEntryCount = 0
    /// Entries that looked like keys but could not be read.
    ///
    /// Exposed so onboarding can say "this file is not in a shape I read"
    /// instead of the much more alarming "your key does not match".
    private(set) var rejectedKeyEntryCount = 0
    /// Key-file permissions are weaker than owner-only.
    ///
    /// Computed, not stored. Two reasons, and the second is the one that bit:
    ///
    /// 1. There must be exactly one implementation. As a stored flag it was
    ///    *declared and read but never assigned*, so it was permanently false
    ///    and the whole `looseKeyPermissions` diagnosis could never fire — a
    ///    state that exists, is tested on both halves, and is unreachable in
    ///    the app. That is the same class of silent defect this round was
    ///    meant to remove from the key loader.
    /// 2. Permissions change while the process runs. A user who runs
    ///    `chmod 600` to fix the warning must see it clear immediately; a
    ///    value captured at load time would keep reporting the old mode until
    ///    the key file happened to be reloaded.
    var keyFilePermissionsAreLoose: Bool {
        Self.hasLoosePermissions(atPath: keysPath)
    }

    /// Full `keys` dictionary walks performed by `findKey`. Stays at zero once
    /// the index is warm; exposed so tests can prove lookups use the index.
    private(set) var keyLookupLinearScanCount = 0
    /// Times the file-name index was rebuilt — once per key (re)load.
    private(set) var keyIndexBuildCount = 0
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
    private var mainSizes: [String: Int64] = [:]     // relative path → last-seen enc DB size
    private var walSizes: [String: Int64] = [:]      // relative path → last-seen WAL size
    private var contactsMtime: Date?                 // last-seen contact.db mtime
    private var keysMtime: Date?                     // last-seen all_keys.json mtime
    /// Cache: chatUsername → every message DB that contains its `Msg_` table.
    ///
    /// WeChat shards message history: the same table exists in up to ten
    /// `message_N.db` files, split by time, in *addition* to one table per
    /// chat. A real library measured 932 of 2572 tables living in more than one
    /// shard, and 103 of 115 whitelisted chats were multi-shard. An empty array
    /// is the negative cache (scanned, nothing found). Cleared when keys are
    /// reloaded, which is also when the set of DBs can change.
    private var chatShardCache: [String: [String]] = [:]

    /// Content generation per message shard, bumped by `refreshIfChanged`
    /// every time that shard's decrypted snapshot is rewritten. A positive
    /// `chatShardCache` entry alone cannot tell whether a shard that lacked
    /// the chat's table at probe time has since gained it — WeChat creates
    /// `Msg_` tables lazily inside an already-keyed file, and the key list
    /// does not change. `chatShardCacheGen` snapshots the generations seen
    /// when a mapping was built; a later probe re-checks only the shards whose
    /// generation moved (or that were never probed), instead of trusting the
    /// stale mapping or re-probing the world on every write.
    private var messageShardGen: [String: Int] = [:]
    private var chatShardCacheGen: [String: [String: Int]] = [:]

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
    /// Invocations of `getSessions()`. A full scan reads the session table once;
    /// exposed so tests can prove a second full pass over every session is not
    /// being performed.
    private(set) var sessionQueryCount = 0
    /// Fresh decrypted snapshots published by `getDecryptedDB` (cache misses and
    /// refreshes). Exposed so tests can prove an unchanged DB is not decrypted
    /// again — including right after `purgeEphemeralCache()`, when the snapshot
    /// is gone but the encryption mtime is still known.
    private(set) var decryptedSnapshotWriteCount = 0

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
        SecureFileManager.ensureDirectory(at: cacheDir)
        // The decrypted message corpus must not ride into Time Machine or
        // Spotlight — exclude the cache root once at setup.
        var exclusion = URL(fileURLWithPath: cacheDir)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? exclusion.setResourceValues(values)
        if cacheStrategy == .persistent {
            loadManifest()
        }
        // Hydrate learned group-chat self-aliases from last run so the
        // first scan after a restart already knows "我" vs a group nickname and
        // the AI summarizer doesn't mis-attribute the user's own
        // messages on day one. Aliases expire: a nickname I stopped
        // using (or never owned — a mislearned hint) must not mark a
        // member's messages as mine forever.
        let now = Date().timeIntervalSince1970
        if let saved = aliasDefaults.dictionary(forKey: learnedAliasesKey) as? [String: Double] {
            self.mySelfNames = Set(saved.filter { now - $0.value < Self.learnedAliasTTL }.keys)
        } else if let saved = aliasDefaults.stringArray(forKey: learnedAliasesKey) {
            // Legacy array format predates expiry — accept once, it
            // rewrites into the dated form on the next learnSelfAlias.
            self.mySelfNames = Set(saved)
        }
    }

    deinit {
        // Last-chance flush: a debounced write can still be pending when the
        // reader goes away (app quit, account switch, tests tearing down).
        flushManifestIfNeeded()
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

    /// How long a learned self-alias stays valid. Group nicknames change;
    /// an alias learned months ago can collide with a member who later
    /// took that name, so learned names decay instead of living forever.
    static let learnedAliasTTL: TimeInterval = 90 * 24 * 3600

    /// Persist the current `mySelfNames` set to UserDefaults so it
    /// survives relaunches. Called after `getMessages` learns a new
    /// alias from a realSenderId==0 + hint pair.
    func learnSelfAlias(_ alias: String) {
        guard !alias.isEmpty else { return }
        mySelfNames.insert(alias)
        guard persistLearnedAliases else { return }
        // Merge over whatever is stored so aliases learned in a prior
        // run keep their original timestamps.
        var saved = aliasDefaults.dictionary(forKey: learnedAliasesKey) as? [String: Double] ?? [:]
        for name in mySelfNames where saved[name] == nil {
            saved[name] = Date().timeIntervalSince1970
        }
        saved[alias] = Date().timeIntervalSince1970
        // Never persist a name older than the TTL — a stale entry
        // dropped by hydration shouldn't linger in storage forever.
        let now = Date().timeIntervalSince1970
        saved = saved.filter { now - $0.value < Self.learnedAliasTTL }
        aliasDefaults.set(saved, forKey: learnedAliasesKey)
    }

    /// Drop a learned alias that a group member demonstrably shares.
    /// Keeping it would let `isFromSelf` turn that member's messages into
    /// ours everywhere; losing self-attribution is the safe failure mode.
    func forgetSelfAlias(_ alias: String) {
        guard mySelfNames.remove(alias) != nil else { return }
        guard persistLearnedAliases else { return }
        var saved = aliasDefaults.dictionary(forKey: learnedAliasesKey) as? [String: Double] ?? [:]
        saved.removeValue(forKey: alias)
        aliasDefaults.set(saved, forKey: learnedAliasesKey)
    }

    static func cacheDir(for strategy: CacheStrategy) -> String {
        let home = NSHomeDirectory()
        switch strategy {
        case .persistent: return "\(home)/.wechat-hud/cache"
        // Shared /tmp is world-writable — a local attacker pre-creating the
        // predictable directory owns it (can unlink/replace snapshots).
        // NSTemporaryDirectory is per-user.
        case .temporary:  return NSTemporaryDirectory() + "wechat_hud_cache"
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
        /// Present and readable, but readable by more than its owner.
        ///
        /// A database key in a file another local account can read is a key
        /// disclosed. The reference implementation treats this as its own
        /// state rather than a footnote, so onboarding can ask for a chmod
        /// instead of leaving a silently weak setup in place.
        case loosePermissions
    }

    /// Availability only; successful database reads establish whether keys match.
    var accessMaterialState: AccessMaterialState {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: keysPath, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue, fm.isReadableFile(atPath: keysPath) else { return .unreadable }
        return Self.hasLoosePermissions(atPath: keysPath) ? .loosePermissions : .available
    }

    /// True when a file is readable by anyone other than its owner.
    ///
    /// Only the group and other bits are inspected. A file the owner cannot
    /// read is already reported as `.unreadable`, and failing on a missing
    /// owner-read bit here would report one problem as two different states.
    static func hasLoosePermissions(atPath path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let mode = attributes?[.posixPermissions] as? NSNumber else { return false }
        return mode.intValue & 0o077 != 0
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
            chatShardCache.removeAll()
            chatShardCacheGen.removeAll()
            messageShardGen.removeAll()
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
                mainSizes.removeAll()
                walSizes.removeAll()
                contactsMtime = nil
            }
            keys.removeAll(keepingCapacity: true)
            saltKeys.removeAll(keepingCapacity: true)
            rejectedKeyEntryCount = 0
            recognizedKeyEntryCount = 0

            // Shape 3 first: a schema-2 salt map keys its entries by each
            // database’s own header salt, so its top-level `keys`
            // dictionary is an envelope field rather than a database path and
            // must not be fed to the path loop below.
            var recognized = 0
            if let saltMap = WeChatKeyMaterial.saltMap(from: json) {
                saltKeys = saltMap.keys
                recognized += saltMap.keys.count
                rejectedKeyEntryCount += saltMap.rejectedEntries
            }

            for (path, value) in json {
                guard !WeChatKeyMaterial.isEnvelopeKey(path) else { continue }
                guard let keyData = WeChatKeyMaterial.keyData(from: value) else {
                    // Counted, not skipped. A file whose entries are all in an
                    // unread shape used to load zero keys in silence and then
                    // report “no key for this database”, which sends the user
                    // hunting for a new key when nothing was wrong with theirs.
                    rejectedKeyEntryCount += 1
                    continue
                }
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                keys[normalized] = keyData
                recognized += 1
            }
            recognizedKeyEntryCount = recognized
            // The index is derived state: it must be rebuilt in lockstep with
            // `keys` (new material, changed file, or an explicit force reload).
            rebuildKeyIndex()
            keysMtime = curMtime
        }
    }

    /// Rebuild the per-file-name candidate index from the current `keys`.
    ///
    /// Every key is stored already normalized by `loadKeys`; the extra
    /// backslash pass keeps this correct if a future writer forgets that.
    private func rebuildKeyIndex() {
        let databaseRoot = URL(fileURLWithPath: dbDir).standardizedFileURL.path
        var index: [String: KeyCandidateBucket] = [:]
        index.reserveCapacity(keys.count)
        for (keyPath, keyData) in keys {
            let normalized = keyPath.replacingOccurrences(of: "\\", with: "/")
            let filename = (normalized as NSString).lastPathComponent
            var bucket = index[filename] ?? KeyCandidateBucket()
            bucket.distinctValues.insert(keyData)
            if normalized.hasPrefix("/") {
                bucket.hasAbsolute = true
                let absolute = URL(fileURLWithPath: normalized).standardizedFileURL.path
                if Self.keyPath(absolute, isUnderDatabaseRoot: databaseRoot) {
                    bucket.scopedValues.insert(keyData)
                }
            }
            index[filename] = bucket
        }
        keyIndex = index
        keyIndexIsWarm = true
        keyIndexBuildCount += 1
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
            // A crafted key file can carry `..`/absolute paths that would
            // steer decryption outside dbDir into our cache — reject them.
            guard !normalized.hasPrefix("/"),
                  !normalized.split(separator: "/").contains("..") else { return false }
            let encPath = "\(dbDir)/\(normalized)"
            let walPath = encPath + "-wal"
            let fm = FileManager.default

            guard fm.fileExists(atPath: encPath) else { return false }

            let mainAttrs = try? fm.attributesOfItem(atPath: encPath)
            let walAttrs = try? fm.attributesOfItem(atPath: walPath)
            let mainMtime = mainAttrs?[.modificationDate] as? Date
            let walMtime = walAttrs?[.modificationDate] as? Date
            // mtime alone misses `cp -p`/restored/cloned replacements —
            // include size in the fingerprint.
            let mainSize = (mainAttrs?[.size] as? NSNumber)?.int64Value
            let walSize = (walAttrs?[.size] as? NSNumber)?.int64Value

            let mainChanged = mainMtime != mainMtimes[normalized]
                || mainSize != mainSizes[normalized]
            let walChanged = walMtime != walMtimes[normalized]
                || walSize != walSizes[normalized]

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
            // the last checkpoint (rare but possible on rapid writes). A WAL
            // apply failure must not fail the whole refresh: the main decrypt
            // already produced a usable snapshot, and skipping the mtime record
            // re-decrypts the main DB on every cycle.
            if fm.fileExists(atPath: walPath), let key = findKey(for: normalized) {
                do {
                    try WeChatDecryptor.applyWAL(dbPath: decPath, walPath: walPath, key: key)
                } catch {
                    print("[WCHUD] WAL apply failed for \(normalized): \(error)")
                }
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
                // Drop the "this chat has no table anywhere" entries: a rewrite
                // can introduce a table that was not there before. Positive
                // shard lists survive, for the reason above; a shard added later
                // (WeChat rotating in a new message_N.db) arrives with the key
                // file that describes it, and `loadKeys` clears the whole cache.
                chatShardCache = chatShardCache.filter { !$0.value.isEmpty }
                // Bump the shard's content generation so positive mappings get
                // their uncached shards re-probed on next read — a rewrite can
                // *add* this chat's table to a shard the probe skipped.
                messageShardGen[normalized, default: 0] += 1
            }
            mainMtimes[normalized] = mainMtime
            walMtimes[normalized] = walMtime
            mainSizes[normalized] = mainSize
            walSizes[normalized] = walSize
            // Persisting the manifest is a full JSON serialization + atomic
            // write per changed DB. Record the change instead and let the
            // debounced flush below collapse a burst of refreshes into one
            // write — see `markManifestDirty`.
            markManifestDirty()
            return true
        }
    }

    // MARK: - DB Access

    /// Get a decrypted, readable SQLite DB for the given relative path.
    func getDecryptedDB(relativePath: String) throws -> String {
        try lock.withLock {
            let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
            // Reject `..`/absolute relPaths — a crafted key file could steer
            // decryption outside dbDir into our cache (see refreshIfChanged).
            guard !normalized.hasPrefix("/"),
                  !normalized.split(separator: "/").contains("..") else {
                throw ReaderError.dbNotFound(normalized)
            }

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
            decryptedSnapshotWriteCount += 1
            return decPath
        }
    }

    /// Resolve the 32-byte key for a DB path.
    ///
    /// Uses the per-file-name index built by `loadKeys`; the branch structure is
    /// the historical one, kept verbatim so a key file that describes several
    /// accounts still resolves exactly as before:
    ///   1. candidates are every key matching by exact path or by file name;
    ///   2. if any candidate is an absolute path under `dbDir`, the answer must
    ///      be unambiguous among those;
    ///   3. absolute candidates that are *not* under `dbDir` mean this key file
    ///      belongs to another account → no relative fallback, nil;
    ///   4. otherwise the answer must be unambiguous across candidates.
    ///
    /// Equivalence with the previous linear filter follows from (1) being
    /// exactly the index bucket for `lastPathComponent(normalized)`: an exact
    /// path match always has that same file name, and a raw `path` containing a
    /// backslash can never equal a normalized key.
    func findKey(for path: String) -> Data? {
        lock.withLock {
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            let filename = (normalized as NSString).lastPathComponent

            // Path first: an exact match is the strongest evidence, and it
            // is what every key file written by this project provides.
            if let byPath = keyByPath(normalized: normalized, filename: filename) {
                return byPath
            }
            // Then the same file by its own header salt. This is not a
            // convenience: it is what makes a renamed or moved database
            // still open, and the only way a key set collected without
            // paths can be used at all.
            return keyByHeaderSalt(normalized: normalized)
        }
    }

    /// Path-keyed lookup, exactly as before the salt fallback existed.
    private func keyByPath(normalized: String, filename: String) -> Data? {
        if keyIndexIsWarm {
            guard let bucket = keyIndex[filename] else { return nil }
            if !bucket.scopedValues.isEmpty {
                return bucket.scopedValues.count == 1 ? bucket.scopedValues.first : nil
            }
            if bucket.hasAbsolute { return nil }
            return bucket.distinctValues.count == 1 ? bucket.distinctValues.first : nil
        }

        // Cold index: either no keys are loaded yet, or a future writer of
        // `keys` forgot to rebuild the index. Fall back to the dictionary
        // filter so a missing index can never turn into a wrong "no key"
        // verdict; the counter is a canary for exactly that situation.
        guard !keys.isEmpty else { return nil }
        keyLookupLinearScanCount += 1
        return findKeyByScanning(normalized: normalized, filename: filename)
    }

    /// Look the database up by the salt in its own first 16 bytes.
    ///
    /// Reads at most 16 bytes, and only when a salt-keyed entry exists — so
    /// a path-keyed key file pays one empty-dictionary check and no I/O.
    private func keyByHeaderSalt(normalized: String) -> Data? {
        guard !saltKeys.isEmpty else { return nil }
        // No database root means nothing to read a salt from. Without this the
        // relative branch below would build `/message/message_0.db` — an
        // absolute path at the filesystem root — because `dbDir` is a plain
        // string that is empty when account detection failed.
        guard !dbDir.isEmpty else { return nil }
        let candidate = normalized.hasPrefix("/")
            ? normalized
            : "\(dbDir)/\(normalized)"
        guard let salt = WeChatKeyMaterial.headerSaltHex(atPath: candidate) else { return nil }
        return saltKeys[salt.lowercased()]
    }

    /// The original dictionary filter, kept as the cold-path reference
    /// implementation for `findKey`.
    private func findKeyByScanning(normalized: String, filename: String) -> Data? {
        let candidates = keys.filter { keyPath, _ in
            let kp = keyPath.replacingOccurrences(of: "\\", with: "/")
            return kp == normalized || (kp as NSString).lastPathComponent == filename
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
        // One critical section for the whole publish: a reader must never see
        // the new index without the group labels promoted into `contactCache`,
        // or an unnamed room flickers to its placeholder mid-refresh.
        namingLock.withLock {
            contactIdentityIndex = identityIndex
            contactCache = identityIndex.displayNameByUsername
            loadGroupMemberNames(db: db, knownNames: identityIndex.displayNameByUsername)
        }

        // Rebuild self-name aliases. Merge the base set (wxid + legacy
        // short ID + contact.db display name) WITH any group-chat
        // nicknames previously learned via `getMessages`'s
        // realSenderId==0 branch — previously we `= [me]`'d which
        // threw away every learned alias on every contact.db refresh.
        // That's why the AI summarizer kept seeing the user's own
        // messages labelled as the group nickname (e.g. a group alias) and
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
    /// Internal rather than private: the member-name JOIN is what turns a
    /// nameless group into a usable label, and the only way to test the query
    /// the app actually runs is to hand it a fixture database.
    func loadGroupMemberNames(db: OpaquePointer?, knownNames: [String: String]) {
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
            guard MessageHelpers.isGroupChat(room) else { continue }
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
        namingLock.withLock {
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
    }

    func displayName(for username: String) -> String {
        namingLock.withLock {
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
            if MessageHelpers.isGroupChat(username) {
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

    /// Names WeChat's own search can match: current remark, then nickname, then username.
    func weChatSearchNames(for username: String) -> [String] {
        namingLock.withLock { contactIdentityIndex.searchNames(for: username) }
    }

    func weChatRemark(for username: String) -> String? {
        namingLock.withLock { contactIdentityIndex.remarkByUsername[username] }
    }

    func weChatNickName(for username: String) -> String? {
        namingLock.withLock { contactIdentityIndex.nickNameByUsername[username] }
    }

    /// Member display names recovered for an unnamed group, if any.
    func groupMemberNames(for username: String) -> [String] {
        namingLock.withLock { groupMemberNamesCache[username] ?? [] }
    }

    /// True when WeChat itself has no name for this chat — `contact.db`
    /// carries the row but with an empty `nick_name`/`remark`. Whatever the
    /// UI shows for such a chat is a placeholder or a member-derived guess.
    func hasWeChatName(for username: String) -> Bool {
        namingLock.withLock {
            guard let name = contactIdentityIndex.weChatNameByUsername[username] else { return false }
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func canonicalContactUsername(for usernameOrAlias: String) -> String? {
        namingLock.withLock {
            contactIdentityIndex.canonicalUsername(for: usernameOrAlias)
        }
    }

    func normalizeContactMentions(in text: String) -> String {
        namingLock.withLock {
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
        // The key/index check and the counter used to run before the lock —
        // a concurrent `loadKeys` (FSEvents reload during a scan) could swap
        // `keys` mid-read. The lock is recursive, so the inner calls that
        // re-acquire it (`refreshIfChanged`, `getDecryptedDB`) are safe.
        try lock.withLock {
            let rel = "session/session.db"
            sessionQueryCount += 1
            guard keys[rel] != nil else { return [] }
            _ = try? refreshIfChanged(relPath: rel)
            let decPath = try getDecryptedDB(relativePath: rel)
            // Reuse the cached handle: a throwaway connection re-parsed
            // session.db's whole schema on every scan, twice per scan here.
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
                    isGroup: MessageHelpers.isGroupChat(username),
                    unreadCount: unread,
                    lastTimestamp: ts
                ))
            }
            return results
        }
    }

    func allContacts() -> [String: String] {
        lock.withLock { contactCache }
    }

    // MARK: - Message DB Discovery

    func findMessageDBs() -> [String] {
        lock.withLock {
            let keyed = keys.keys.filter {
                $0.contains("message/message_") && $0.hasSuffix(".db")
                && !$0.contains("message_fts") && !$0.contains("message_resource")
            }
            if !keyed.isEmpty { return keyed.sorted() }
            // Salt-map key files carry no path entries — discover shards by
            // scanning the message/ directory itself.
            let messageDir = (dbDir as NSString).appendingPathComponent("message")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: messageDir)) ?? []
            return names.compactMap { name -> String? in
                guard name.hasPrefix("message_"), name.hasSuffix(".db"),
                      !name.contains("message_fts"), !name.contains("message_resource"),
                      name != "message.db" else { return nil }
                return "message/\(name)"
            }.sorted()
        }
    }

    /// Probe for a chat's `Msg_<md5>` table on an already-open handle.
    /// Throws on a prepare/step failure so a corrupt shard is distinguishable
    /// from "the table is genuinely absent" — a nil return is trustworthy.
    static func msgTableName(chatUsername: String, db: OpaquePointer) throws -> String? {
        let hash = md5Hex(chatUsername)
        let tableName = "Msg_\(hash)"

        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("table probe: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let result = sqlite3_step(stmt)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw ReaderError.sqlError("table probe step: \(String(cString: sqlite3_errmsg(db)))")
        }
        return result == SQLITE_ROW ? tableName : nil
    }

    func findMsgTable(chatUsername: String, dbPath: String) throws -> String? {
        try withReadonlyDB(path: dbPath) { db in
            try Self.msgTableName(chatUsername: chatUsername, db: db)
        }
    }

    // MARK: - Message Queries

    /// One chat's page request for `getMessagesBatch`.
    struct MessageBatchRequest: Sendable {
        let chatUsername: String
        let limit: Int
        var startTime: Int? = nil
        var endTime: Int? = nil
    }

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
        return try getMessagesLocked(
            chatUsername: chatUsername,
            limit: limit,
            sinceLocalId: sinceLocalId,
            afterCursor: afterCursor,
            oldestFirst: oldestFirst,
            startTime: startTime,
            endTime: endTime,
            beforeCursor: beforeCursor
        )
    }

    /// Fetch recent pages for many chats under a single lock acquisition.
    /// ScanEngine unread/autopilot loops use this so shard/handle caches warm once
    /// and MainActor readers are not interleaved between every chat.
    func getMessagesBatch(_ requests: [MessageBatchRequest]) throws -> [String: [MessageInfo]] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: [MessageInfo]] = [:]
        out.reserveCapacity(requests.count)
        for req in requests {
            // Per-chat isolation: a single chat whose shards all fail
            // (deleted file still keyed, corrupt handle) must not poison
            // the batch — callers wrap the whole batch in `try?`, so a
            // throw here would empty every other chat's results too.
            out[req.chatUsername] = (try? getMessagesLocked(
                chatUsername: req.chatUsername,
                limit: req.limit,
                sinceLocalId: nil,
                afterCursor: nil,
                oldestFirst: false,
                startTime: req.startTime,
                endTime: req.endTime,
                beforeCursor: nil
            )) ?? []
        }
        return out
    }

    /// Assumes `lock` is already held (recursive OK for nested helpers).
    private func getMessagesLocked(
        chatUsername: String,
        limit: Int,
        sinceLocalId: Int?,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)?,
        oldestFirst: Bool,
        startTime: Int?,
        endTime: Int?,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    ) throws -> [MessageInfo] {
        var results: [MessageInfo] = []
        var seenIDs = Set<String>()
        let effectiveLimit = max(1, limit)
        // Negative cache: we already scanned all DBs and this chat has no table.
        let usedCachedMapping = chatShardCache[chatUsername] != nil
        if usedCachedMapping, chatShardCache[chatUsername]?.isEmpty == true {
            return []
        }

        // Which DBs hold this chat's table. On a miss every message DB is
        // probed and *all* hits are recorded — a chat's history is split across
        // shards by time, so stopping at the first hit (the old behaviour)
        // returned only the slice that happened to live in whichever DB was
        // probed first, and a day whose messages sat in another shard came back
        // empty.
        //
        // Each shard is probed independently and a failure only skips that
        // shard: a keyed-but-missing or corrupt `message_N.db` used to throw
        // out of the probe loop, which failed the query for *every* chat —
        // not just the ones that might live there.
        let dbPaths: [String]
        if var cached = chatShardCache[chatUsername] {
            // Positive mapping. Shards not listed were probed once and lacked
            // the table — but the probe is only valid for the content that was
            // there at the time. Re-probe a shard when its generation moved or
            // when it was never probed (e.g. it failed to decrypt back then).
            let probedGen = chatShardCacheGen[chatUsername] ?? [:]
            var gen = probedGen
            var discovered: [String] = []
            for relPath in findMessageDBs() where !cached.contains(relPath) {
                let currentGen = messageShardGen[relPath] ?? 0
                if let seen = probedGen[relPath], seen == currentGen {
                    continue  // this exact content was probed: table absent then
                }
                if let decPath = try? getDecryptedDB(relativePath: relPath),
                   let db = try? acquireReadonly(path: decPath) {
                    // Mark the generation only once the probe actually
                    // succeeds — a throwing probe means a broken shard, not a
                    // provably-absent table, and must retry next call.
                    do {
                        let probed = try Self.msgTableName(chatUsername: chatUsername, db: db)
                        gen[relPath] = currentGen
                        if probed != nil { discovered.append(relPath) }
                    } catch { /* broken shard — leave gen unmarked */ }
                }
            }
            if !discovered.isEmpty {
                cached.append(contentsOf: discovered)
                cached.sort()
                chatShardCache[chatUsername] = cached
            }
            chatShardCacheGen[chatUsername] = gen
            dbPaths = cached
        } else {
            let allDBs = findMessageDBs()
            var found: [String] = []
            var probedGen: [String: Int] = [:]
            var firstError: Error?
            for relPath in allDBs {
                do {
                    let decPath = try getDecryptedDB(relativePath: relPath)
                    let db = try acquireReadonly(path: decPath)
                    let tableName = try Self.msgTableName(chatUsername: chatUsername, db: db)
                    // Mark the generation only AFTER a successful probe — a
                    // shard that opened but failed the schema read must stay
                    // unmarked so the next call re-probes it instead of
                    // trusting a hole.
                    probedGen[relPath] = messageShardGen[relPath] ?? 0
                    if tableName != nil {
                        found.append(relPath)
                    }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if firstError == nil {
                chatShardCache[chatUsername] = found
                chatShardCacheGen[chatUsername] = probedGen
            } else if !found.isEmpty {
                // Partial probe: the found list is trustworthy (those shards
                // did hold the table), and shards that failed to decrypt have
                // no recorded generation, so the positive path above re-probes
                // them on the next call instead of trusting a hole.
                chatShardCache[chatUsername] = found
                chatShardCacheGen[chatUsername] = probedGen
            }
            dbPaths = found
            if dbPaths.isEmpty, let firstError {
                // Every shard failed — surface the real error rather than
                // reporting "no messages" for a chat we could not even read.
                throw firstError
            }
        }

        var foundTable = false
        var queriedShards = 0
        var lastShardError: Error?
        for relPath in dbPaths {
            do {
                let decPath = try getDecryptedDB(relativePath: relPath)
                // One handle serves both the table probe and the query, and stays
                // cached for later calls. This method already holds `lock`, so the
                // handle cannot be invalidated mid-query.
                let db = try acquireReadonly(path: decPath)
                guard let tableName = try? Self.msgTableName(chatUsername: chatUsername, db: db) else {
                    continue
                }
                foundTable = true
                // Rows from a shard are only merged when its query completes:
                // a mid-step error would otherwise leak a partial slice that
                // looks like the shard's whole answer.
                let rows = try collectShardRows(
                    db: db, tableName: tableName, relPath: relPath,
                    chatUsername: chatUsername, effectiveLimit: effectiveLimit,
                    sinceLocalId: sinceLocalId, afterCursor: afterCursor,
                    oldestFirst: oldestFirst, startTime: startTime,
                    endTime: endTime, beforeCursor: beforeCursor
                )
                queriedShards += 1
                for msg in rows {
                    guard seenIDs.insert(msg.id).inserted else { continue }
                    // Cross-shard dedup: while WCDB checkpoints pages into the
                    // main file, the same row is visible in two shards — with
                    // different relPaths, so the uid above cannot catch it. The
                    // content key does: two rows that agree on everything
                    // user-visible are the same message, not a collision
                    // (per-shard localIds restart per file, so the key must
                    // include content, not just ids).
                    let contentKey = "\(msg.createTime)-\(msg.localId)-\(msg.baseType)-\(msg.subType)-\(msg.senderUsername)-\(msg.text)"
                    guard seenIDs.insert(contentKey).inserted else { continue }
                    results.append(msg)
                }
            } catch {
                lastShardError = error
            }
        }
        if queriedShards == 0, let lastShardError {
            // Every mapped shard threw — possibly because the mapping is
            // stale (shard deleted/rotated while still keyed). A full
            // re-probe self-heals that case; only surface the error when a
            // fresh probe truly cannot read anything.
            if usedCachedMapping {
                chatShardCache.removeValue(forKey: chatUsername)
                return try getMessagesLocked(
                    chatUsername: chatUsername,
                    limit: limit,
                    sinceLocalId: sinceLocalId,
                    afterCursor: afterCursor,
                    oldestFirst: oldestFirst,
                    startTime: startTime,
                    endTime: endTime,
                    beforeCursor: beforeCursor
                )
            }
            throw lastShardError
        }

        // Cache miss: the cached shards no longer hold this table (WeChat moved
        // or dropped it). Retry with a full probe.
        if !foundTable && usedCachedMapping {
            chatShardCache.removeValue(forKey: chatUsername)
            return try getMessagesLocked(
                chatUsername: chatUsername,
                limit: limit,
                sinceLocalId: sinceLocalId,
                afterCursor: afterCursor,
                oldestFirst: oldestFirst,
                startTime: startTime,
                endTime: endTime,
                beforeCursor: beforeCursor
            )
        }

        // Full scan found nothing — remember so we skip next time.
        if !foundTable {
            chatShardCache[chatUsername] = []
        }

        // Each shard applied its own LIMIT, so merge them into one page: the
        // newest (or oldest, when ascending) rows across all shards, in the
        // requested composite order.
        results.sort { lhs, rhs in
            if lhs.createTime != rhs.createTime {
                return oldestFirst ? lhs.createTime < rhs.createTime : lhs.createTime > rhs.createTime
            }
            return oldestFirst ? lhs.localId < rhs.localId : lhs.localId > rhs.localId
        }
        return results.count > effectiveLimit ? Array(results.prefix(effectiveLimit)) : results
    }

    /// Query one shard's `Msg_` table for this chat. Runs inside
    /// `getMessagesLocked` (lock held). Throws on any sqlite failure so the
    /// caller can discard the whole shard slice — a mid-step abort would
    /// otherwise merge a partial page indistinguishable from the full answer.
    private func collectShardRows(
        db: OpaquePointer,
        tableName: String,
        relPath: String,
        chatUsername: String,
        effectiveLimit: Int,
        sinceLocalId: Int?,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)?,
        oldestFirst: Bool,
        startTime: Int?,
        endTime: Int?,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    ) throws -> [MessageInfo] {
        var sql = """
            SELECT local_id, local_type, create_time, real_sender_id,
                   message_content, WCDB_CT_message_content
            FROM [\(tableName)]
        """
        sql += Self.messageQuerySuffix(limit: effectiveLimit, sinceLocalId: sinceLocalId,
                                       afterCursor: afterCursor, oldestFirst: oldestFirst,
                                       startTime: startTime, endTime: endTime,
                                       beforeCursor: beforeCursor)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReaderError.sqlError("Cannot query messages: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        let name2id = loadName2Id(db: db)
        let isGroup = MessageHelpers.isGroupChat(chatUsername)
        let chatName = displayName(for: chatUsername)
        // name2id value → claimant count. A group nickname claimed by two
        // different member ids is ambiguous — promoting rows via that alias
        // would turn the other member's messages into "self" (dropped from
        // unread, fed to commitment tracking as our own words).
        var aliasClaimants: [String: Int] = [:]
        if isGroup {
            for value in name2id.values { aliasClaimants[value, default: 0] += 1 }
        }

        var rows: [MessageInfo] = []
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
            //
            // Ambiguity guard: when the resolved alias is claimed by more
            // than one name2id id in this group, at least one claimant is
            // a different member sharing our nickname — promotion would
            // silently turn their messages into ours. The alias itself is
            // poison: evict it so the senderName/name-only checks in
            // isFromSelf can't misfile either.
            if !senderUsername.isEmpty && senderUsername != me {
                let contested = (aliasClaimants[senderUsername] ?? 0) > 1
                if contested && mySelfNames.contains(senderUsername) {
                    forgetSelfAlias(senderUsername)
                }
                if mySelfNames.contains(senderUsername) && !contested {
                    senderUsername = me
                } else if let canonical = canonicalContactUsername(for: senderUsername) {
                    senderUsername = canonical
                }
            }

            // In group chats where the lookup yielded nothing
            // (name2id hit nothing), we try additional heuristics:
            //   1. `parsed.senderHint` is a known self alias that NO
            //      name2id entry claims → promote. A hint already claimed
            //      by another member's row is their nickname, not ours.
            //   2. `realSenderId == 0` — WeChat stores 0 for the
            //      user's own messages in Name2Id-indexed group
            //      tables. Learn the hint so future lookups are
            //      fast, and persist it so a restart doesn't
            //      reset the knowledge. Restricted to real content
            //      types: system rows (10000) also carry
            //      realSenderId 0 but their "hint" is parser noise,
            //      not a nickname.
            if isGroup && name2id[realSenderId] == nil {
                let hint = parsed.senderHint
                // A hint claimed by a member's name2id entry is THEIR
                // nickname — an alias that collides with it is unsafe and
                // gets evicted, not promoted.
                let hintContested = !hint.isEmpty && (aliasClaimants[hint] ?? 0) > 0
                if hintContested && mySelfNames.contains(hint) {
                    forgetSelfAlias(hint)
                }
                if !hint.isEmpty && mySelfNames.contains(hint)
                    && !hintContested {
                    senderUsername = me
                } else if let canonical = canonicalContactUsername(for: hint) {
                    senderUsername = canonical
                } else if realSenderId == 0 && !hint.isEmpty
                    && (baseType == 1 || baseType == 49) {
                    learnSelfAlias(hint)
                    senderUsername = me
                }
            }
            let senderName = displayName(for: senderUsername)

            let uid = "\(relPath)/\(tableName)/\(localId)"
            rows.append(MessageInfo(
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
                appType: parsed.appType,
                sysKind: parsed.sysKind.isEmpty ? nil : parsed.sysKind
            ))
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw ReaderError.sqlError("Message query interrupted: \(String(cString: sqlite3_errmsg(db)))")
        }
        return rows
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
        /// Messages at or after the caller's recent-window cutoff.
        ///
        /// This exists because "近期" needs to mean a span, not a property of
        /// the whole window: the insight overview used to infer it from
        /// `latestTs >= cutoff`, which counts a chat's *entire* history as
        /// recent the moment one message lands inside the window.
        let recentCount: Int

        /// Folds another shard's stats for the same chat in.
        ///
        /// A `Msg_<md5>` table legitimately appears in more than one
        /// `message_N.db`, and `findMessageDBs` walks them all. Assigning per
        /// DB (which this used to do) left every insight number — total volume,
        /// active chats, density — describing whichever shard happened to be
        /// read last, silently.
        func merged(with other: BulkChatStats) -> BulkChatStats {
            var senders = senderCounts
            for (key, value) in other.senderCounts { senders[key, default: 0] += value }
            var types = typeCounts
            for (key, value) in other.typeCounts { types[key, default: 0] += value }
            // Whichever shard holds the oldest message also holds the one that
            // decides who spoke first.
            let earlier = earliestTs <= other.earliestTs ? self : other
            return BulkChatStats(
                chatUsername: chatUsername,
                totalCount: totalCount + other.totalCount,
                selfCount: selfCount + other.selfCount,
                senderCounts: senders,
                hourlyBuckets: zip(hourlyBuckets, other.hourlyBuckets).map(+),
                weekdayBuckets: zip(weekdayBuckets, other.weekdayBuckets).map(+),
                typeCounts: types,
                selfInitiated: earlier.selfInitiated,
                earliestTs: min(earliestTs, other.earliestTs),
                latestTs: max(latestTs, other.latestTs),
                recentCount: recentCount + other.recentCount
            )
        }
    }

    /// Build the reverse tableName → chatUsername map used to attribute rows
    /// scanned from a `Msg_<md5>` table back to a chat.
    ///
    /// Duplicate table names are expected, not exceptional:
    /// - callers pass one entry per `chatUsernames` element, and a caller that
    ///   feeds the session list can repeat the same username across accounts;
    /// - two different usernames can resolve to the same `Msg_<md5>` table in
    ///   a merged DB snapshot.
    /// `Dictionary(uniqueKeysWithValues:)` traps on duplicates, and that trap
    /// is uncatchable (it kills the process instead of throwing), so this
    /// helper must never be replaced with it. First-wins keeps the caller's
    /// original name, which is deterministic for a given input, while the
    /// reverse lookup only needs *a* plausible owner for the SQL hit.
    static func tableToChatMap(_ pairs: [(chatUsername: String, tableName: String)]) -> [String: String] {
        Dictionary(pairs.map { ($0.tableName, $0.chatUsername) }, uniquingKeysWith: { first, _ in first })
    }

    func bulkMessageStats(
        chatUsernames: [String],
        selfNames: Set<String>,
        sinceTsEpoch: Int = 0,
        myUsername: String = "",
        myDisplayName: String = "",
        recentSinceTs: Int = 0
    ) -> [String: BulkChatStats] {
        // Build chatUsername → (tableName, chatUsername) map
        let chatToTable: [(chatUsername: String, tableName: String)] = chatUsernames.map {
            ($0, "Msg_\(Self.md5Hex($0))")
        }
        // Group by table name for O(1) lookup. See `tableToChatMap` for why
        // this must tolerate duplicate table names (it used to trap).
        let tableToChat = Self.tableToChatMap(chatToTable)
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
                var recent = 0

                while sqlite3_step(sStmt) == SQLITE_ROW {
                    let senderId = Int(sqlite3_column_int64(sStmt, 0))
                    let createTime = Int(sqlite3_column_int64(sStmt, 1))
                    let localType = Int(sqlite3_column_int64(sStmt, 2))
                    let baseType = localType & 0xFFFFFFFF

                    let senderKey = name2id[senderId] ?? "id_\(senderId)"
                    let isSelf = MessageHelpers.isSelfSender(
                        senderKey: senderKey,
                        senderId: senderId,
                        chatUsername: chatUsername,
                        selfNames: selfNames,
                        myUsername: myUsername,
                        myDisplayName: myDisplayName
                    )
                    senderCounts[senderKey, default: 0] += 1
                    if isSelf { selfCount += 1 }
                    if total == 0 { firstSenderIsSelf = isSelf }

                    let date = Date(timeIntervalSince1970: Double(createTime))
                    hourly[cal.component(.hour, from: date)] += 1
                    weekday[cal.component(.weekday, from: date) - 1] += 1  // 1=Sun→0
                    typeCounts[baseType, default: 0] += 1

                    if createTime < earliestTs { earliestTs = createTime }
                    if createTime > latestTs { latestTs = createTime }
                    if recentSinceTs > 0, createTime >= recentSinceTs { recent += 1 }
                    total += 1
                }
                guard total > 0 else { continue }

                let shard = BulkChatStats(
                    chatUsername: chatUsername,
                    totalCount: total,
                    selfCount: selfCount,
                    senderCounts: senderCounts,
                    hourlyBuckets: hourly,
                    weekdayBuckets: weekday,
                    typeCounts: typeCounts,
                    selfInitiated: firstSenderIsSelf,
                    earliestTs: earliestTs,
                    latestTs: latestTs,
                    recentCount: recent
                )
                // Same chat, next `message_N.db`: fold, never replace.
                result[chatUsername] = result[chatUsername].map { $0.merged(with: shard) } ?? shard
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
            let isGroup = MessageHelpers.isGroupChat(username)
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
            let isGroup = MessageHelpers.isGroupChat(username)
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
    ///
    /// Deliberately keeps `mainMtimes` / `walMtimes`. Dropping them made every
    /// encrypted DB look "never seen" on the next scan (`mtime != nil == nil`),
    /// so `refreshIfChanged` reported a change for files that had not moved and
    /// the scan re-decrypted + re-parsed the schema of the whole corpus.
    ///
    /// Keeping a record for a file whose plaintext was just deleted is safe, and
    /// the two cases that matter both hold:
    ///   * encrypted DB unchanged → `refreshIfChanged` correctly reports "nothing
    ///     moved", and `getDecryptedDB` falls through to a fresh decrypt because
    ///     the `decryptedCache` entry is gone and its `fileExists` check fails;
    ///     a stale snapshot is never served.
    ///   * encrypted DB changed → `mainChanged` is true, so the re-decrypt path
    ///     runs exactly as before.
    /// The privacy promise is unchanged: every file listed in `decryptedCache`
    /// is deleted and every cached handle is closed before this returns.
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
            // mtimes intentionally survive the purge — see the note above.
        }
    }

    /// Whether the reader still remembers this DB's encryption mtime after its
    /// plaintext copy was purged. `.memory`-strategy observability for the
    /// "no plaintext on disk, no re-decrypt storm" contract.
    func tracksEncryptionMtime(forRelativePath relPath: String) -> Bool {
        lock.withLock {
            let normalized = relPath.replacingOccurrences(of: "\\", with: "/")
            return mainMtimes[normalized] != nil || walMtimes[normalized] != nil
        }
    }

    /// Number of DBs the reader believes it has a decrypted snapshot for.
    /// Zero after `purgeEphemeralCache()`.
    var decryptedCacheCount: Int {
        lock.withLock { decryptedCache.count }
    }

    /// Plaintext files the reader still tracks. Tests assert the cache directory
    /// holds none of them after a purge.
    var decryptedFilePaths: [String] {
        lock.withLock { Array(decryptedCache.values) }
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
            let encAttrs = try? fm.attributesOfItem(atPath: encPath)
            let walAttrs = try? fm.attributesOfItem(atPath: walPath)
            let curEnc = encAttrs?[.modificationDate] as? Date
            let curWal = walAttrs?[.modificationDate] as? Date
            let curEncSize = (encAttrs?[.size] as? NSNumber)?.int64Value ?? 0
            let curWalSize = (walAttrs?[.size] as? NSNumber)?.int64Value ?? 0
            let savedEncSize = (entry["encSize"] as? NSNumber)?.int64Value
            let savedWalSize = (entry["walSize"] as? NSNumber)?.int64Value

            // Current encryption mtime+size must match what we cached — a
            // same-mtime/different-size replacement (`cp -p`, clone restore)
            // is a different database.
            guard let curEnc = curEnc, curEnc.timeIntervalSince1970 == encMtimeRaw,
                  savedEncSize == nil || savedEncSize == curEncSize else {
                try? fm.removeItem(atPath: cachedPath)
                continue
            }

            decryptedCache[relPath] = cachedPath
            mainMtimes[relPath] = curEnc
            mainSizes[relPath] = curEncSize
            // WAL may have moved since; we'll detect via refreshIfChanged on first use
            if let walMtimeRaw = walMtimeRaw, let curWal = curWal,
               curWal.timeIntervalSince1970 == walMtimeRaw,
               savedWalSize == nil || savedWalSize == curWalSize {
                walMtimes[relPath] = curWal
                walSizes[relPath] = curWalSize
            } else if curWal != nil {
                // WAL differs — record current so refreshIfChanged will detect change
                walMtimes[relPath] = nil
                walSizes[relPath] = nil
            }
        }
    }

    /// Mark the manifest as needing a write and make sure a debounced flush is
    /// scheduled. Called from the scan's hot path while `lock` is held.
    ///
    /// The flush is timer-backed rather than caller-driven because nothing in
    /// the scan loop is guaranteed to call `flushManifestIfNeeded()`: the dirty
    /// flag can therefore never be lost "until someone remembers to flush".
    private func markManifestDirty() {
        guard cacheStrategy == .persistent else { return }
        manifestDirty = true
        guard manifestFlushWorkItem == nil else {
            return  // already scheduled; that write will pick up this change
        }
        let item = DispatchWorkItem { [weak self] in
            self?.flushManifestIfNeeded()
        }
        manifestFlushWorkItem = item
        manifestFlushQueue.asyncAfter(deadline: .now() + Self.manifestFlushDebounce, execute: item)
    }

    /// Write the manifest now if anything changed since the last successful
    /// write. Safe to call from any thread; call sites that flush eagerly
    /// (a scan boundary, `deinit`) pay nothing when the manifest is clean.
    func flushManifestIfNeeded() {
        lock.withLock {
            manifestFlushWorkItem?.cancel()
            manifestFlushWorkItem = nil
            guard cacheStrategy == .persistent, manifestDirty else { return }
            // Keep the flag when the write fails so the next change (or the
            // next explicit flush) retries instead of silently dropping state.
            if writeManifestNow() {
                manifestDirty = false
            }
        }
    }

    /// Serialize and atomically replace the manifest. Callers hold `lock`.
    /// Returns false when nothing was written; the caller keeps the dirty flag.
    @discardableResult
    private func writeManifestNow() -> Bool {
        var json: [String: [String: Any]] = [:]
        for (relPath, cachedPath) in decryptedCache {
            var entry: [String: Any] = ["cachedPath": cachedPath, "accountIdentity": Self.accountCacheIdentity(dbDir)]
            if let m = mainMtimes[relPath] {
                entry["encMtime"] = m.timeIntervalSince1970
            }
            // mtime+size is the change fingerprint — restore must carry both
            // or every restart re-decrypts the corpus once.
            entry["encSize"] = mainSizes[relPath] ?? 0
            if let w = walMtimes[relPath] {
                entry["walMtime"] = w.timeIntervalSince1970
            } else {
                entry["walMtime"] = 0.0
            }
            entry["walSize"] = walSizes[relPath] ?? 0
            json[relPath] = entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
        } catch {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath)
        manifestWriteCount += 1
        return true
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
