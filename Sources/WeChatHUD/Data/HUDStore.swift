import Foundation
import SQLite3

final class HUDStore: ObservableObject, @unchecked Sendable {
    private let dbPath: String
    private let cleanupPath: String?
    /// Serial executor for every SQLite hop. FULLMUTEX still protects the
    /// connection; this queue also serializes Swift wrapper state
    /// (statement cache, transactionDepth, secret hydration).
    private let serialQueue = DispatchQueue(label: "com.wechathud.hudstore")
    private static let serialQueueKey = DispatchSpecificKey<UInt8>()
    let secretStore: SecretStore
    private var db: OpaquePointer?
    /// Protected by sqlite3_db_mutex. This lets helpers called from an
    /// existing transaction use savepoints without releasing the connection
    /// mutex or attempting a nested BEGIN.
    private var transactionDepth = 0
    var deviceSettings: DeviceSettingsStore?

    // MARK: - Prepared statement cache
    //
    // Why: every call to exec / executeInsert / executeUpdate / queryOne /
    // queryAll used to run sqlite3_prepare_v2 + sqlite3_finalize. The hot
    // paths (scan ingest, whitelist lookups, autopilot polling) re-run the
    // same handful of SQL strings hundreds of times per scan, so the
    // parse/plan work was pure overhead. Caching the prepared statements
    // removes the recompile while keeping every failure semantic identical:
    // a miss still prepares with the same flags and reports the same
    // HUDStoreError.sqlError / nil / empty-result behavior.
    //
    // Concurrency: the cache is a Swift dictionary, and sqlite3's FULLMUTEX
    // serializes sqlite3 calls but not Swift state. So every cache access
    // runs inside withDatabaseMutex, which funnels through FULLMUTEX's
    // recursive connection mutex. A cache hit therefore holds the mutex
    // across reset/bind/step, which also stops two threads from interleaving
    // binds on one shared statement (bind values are not covered by the
    // connection mutex). That mutex is recursive, so cached statements used
    // from inside withTransaction re-enter safely on the same thread.
    private var statementCache: [String: OpaquePointer] = [:]
    /// LRU bookkeeping: least-recently-used SQL string first.
    private var statementCacheLRU: [String] = []
    /// Reused statements are bounded so a long-lived app cannot pin an
    /// unbounded number of VMs/plans. 24 comfortably covers every SQL string
    /// the scan/autopilot loops hit per pass.
    private static let statementCacheCapacity = 24
    /// On overflow, drop the least-recently-used half instead of a single
    /// entry. One eviction pass then costs a bounded number of finalizes and
    /// the loop keeps its working set warm; dropping the whole cache would
    /// recompile every hot statement on the next pass.
    private static let statementCacheEvictCount = 12

    /// Observability for tests: how many times SQL had to be compiled.
    /// A cache hit never increments this, so a test can assert that a
    /// repeated call prepared the statement only once.
    private(set) var statementPrepareCount = 0

    /// Observability for tests: how many write statements were *executed*
    /// (counted per execution, never per prepare, so the statement cache
    /// cannot mask the work). Read-only statements (SELECT/PRAGMA) do not
    /// count. Used to assert "no stale rows means zero write transactions".
    private(set) var writeStatementCount = 0

    init(
        dbPath: String? = nil,
        createParentDirectory: Bool = true,
        cleanupPath: String? = nil,
        secretStore: SecretStore? = nil
    ) {
        let home = NSHomeDirectory()
        let dir = dbPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? "\(home)/.wechat-hud"
        self.dbPath = dbPath ?? "\(dir)/hud.sqlite3"
        self.cleanupPath = cleanupPath
        if let secretStore {
            self.secretStore = secretStore
        } else if NSClassFromString("XCTestCase") != nil {
            self.secretStore = InMemorySecretStore()
        } else if PreviewRuntime.isEnabled {
            // The preview build runs under its own bundle identifier and
            // ad-hoc signature, so a Keychain read would raise the
            // "WeChatHUD Preview wants to use com.wechathud.secrets" system
            // prompt and block every surface behind a password field. The
            // preview never talks to a real provider, so it keeps its
            // secrets process-local instead of borrowing the shipping
            // app's item.
            self.secretStore = InMemorySecretStore()
        } else {
            self.secretStore = KeychainSecretStore.shared
        }
        serialQueue.setSpecific(key: Self.serialQueueKey, value: 1)
        if createParentDirectory {
            SecureFileManager.ensureDirectory(at: dir)
        }
    }

    func open() throws {
        // A second open would overwrite `db` and leak the first handle —
        // close it first so the call is idempotent. If the close could not
        // finish (SQLITE_BUSY — a live statement elsewhere), `db` is still
        // non-nil; overwriting it here would orphan that handle with its WAL
        // uncheckpointed.
        if db != nil { close() }
        guard db == nil else {
            throw HUDStoreError.openFailed("previous connection still open (SQLITE_BUSY)")
        }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            // Even on failure SQLite may allocate a handle — close it or the
            // store is left pointing at a half-open connection.
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle = db { sqlite3_close(handle); db = nil }
            throw HUDStoreError.openFailed(msg)
        }
        // A previous connection's cached statements belong to that handle.
        prepareStatementCacheForNewConnection()
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA busy_timeout=5000")
        // Cap the WAL file so long-running sessions don't accumulate
        // unbounded -wal pages. 256 pages (~1MB) is a good balance between
        // write throughput and disk usage.
        try exec("PRAGMA wal_autocheckpoint=256")
        SecureFileManager.ensureFilePermissions(at: dbPath)
        let parent = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        if parent.lastPathComponent == ".wechat-hud" {
            SecureFileManager.hardenTree(at: parent.path)
        }
        try createTables()
        try SchemaMigrator.apply(to: self)
        try exec("""
            CREATE TABLE IF NOT EXISTS classification_queue (
                msg_uid TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                source_timestamp INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                retry_after INTEGER NOT NULL DEFAULT 0
            )
        """)
        // Queue dedup on shard-independent identity: WCDB checkpointing can
        // move a row between message_N.db files, changing its relPath/localId
        // (and thus msg_uid). content_key survives the move.
        _ = try? exec("ALTER TABLE classification_queue ADD COLUMN content_key TEXT NOT NULL DEFAULT ''")
        _ = try? exec("CREATE INDEX IF NOT EXISTS idx_classification_content_key ON classification_queue(content_key)")

        // Seed AI configs to the settings table on first launch. After
        // this runs, every code path reads its AI config from the DB —
        // source files no longer carry endpoint URLs or model names.
        self.seedAISettingsIfMissing()

        // One-time migration: copy legacy whitelist entries into contacts.
        migrateWhitelistToContacts()
        repairVIPTrackingAlignment()

        // Best-effort housekeeping. Failures are non-fatal — the app
        // still starts, we just leave old audit rows around.
        try? pruneAIAudit(olderThanDays: 14)

        // Retrospective tab migration + crash recovery (Plan M1.2 / M1.6).
        // Idempotent CREATE TABLE IF NOT EXISTS for 7 tables + indexes.
        // Then mark stale 'running' runs as failed and clean expired undo.
        migrateRetrospective()
        try SchemaMigrator.applyAfterRetrospective(to: self)
        let reapedRuns = reapStaleRuns()
        let reapedUndo = reapStaleUndo(olderThanSeconds: 30 * 60)
        if reapedRuns > 0 || reapedUndo > 0 {
            print("[HUDStore] reaped \(reapedRuns) stale review_runs + \(reapedUndo) old undo entries")
        }

        migrateDailyReportState()

        // User-chosen conversation names. Must exist before any reader
        // resolution runs so `repairStaleChatNames` can consult it.
        migrateChatAliases()

        normalizeDiscussionDueDates()
        migratePlaintextAPIKeysToKeychain()
    }

    /// Rewrites `due_at` values that were stored as an empty string into real
    /// NULLs.
    ///
    /// The insert and edit paths used to bind "" when an item had no deadline.
    /// The column is INTEGER, so SQLite could not convert it and kept the value
    /// as TEXT — and because every TEXT value sorts after every number,
    /// `due_at > 0` was true for every row while `due_at IS NULL` was true for
    /// none. The Swift reader already treats those rows as undated (the value
    /// parses to 0), so this is not a behaviour change today; it makes the
    /// stored data mean what the schema says, so queries written later cannot
    /// be misled the way this one was.
    ///
    /// Idempotent: after the first run no rows match. Scoped to the empty
    /// string, so a row that legitimately holds a timestamp is untouched.
    @discardableResult
    func normalizeDiscussionDueDates() -> Int {
        let before = writeStatementCount
        try? exec("""
            UPDATE discussion_items SET due_at = NULL
            WHERE due_at IS NOT NULL AND typeof(due_at) = 'text' AND TRIM(due_at) = ''
            """)
        // Belt and braces: any TEXT value sorts after every number in SQLite,
        // so a stray non-empty TEXT (only non-numeric garbage can survive the
        // INTEGER column affinity — all-digit strings are stored as INTEGER)
        // would make `due_at > 0` true for a dateless row while Swift reads
        // nil. NULL out whatever TEXT is left.
        try? exec("""
            UPDATE discussion_items SET due_at = NULL
            WHERE typeof(due_at) = 'text'
            """)
        return writeStatementCount - before
    }

    /// Opens an existing business store without schema migration, PRAGMA
    /// changes, housekeeping, or any other write-capable operation.
    func openReadOnly() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw HUDStoreError.openFailed("Database does not exist")
        }
        // `mode=ro` permits SQLite to consult an existing WAL for current
        // data while keeping the primary database connection read-only.
        // Do not use immutable=1 here: it would silently ignore an active WAL.
        if db != nil { close() }
        // Same guard as open(): a BUSY close leaves db non-nil — overwriting
        // it would orphan the old handle and its un-checkpointed WAL.
        guard db == nil else {
            throw HUDStoreError.openFailed("existing database handle could not be closed")
        }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            // SQLite can allocate a handle even on failure — close it or the
            // store is left pointing at a half-open connection.
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle = db { sqlite3_close(handle); db = nil }
            throw HUDStoreError.openFailed(msg)
        }
        prepareStatementCacheForNewConnection()
    }

    func close() {
        // sqlite3_close returns SQLITE_BUSY while any statement is still
        // alive, so every cached statement must be finalized first. Without
        // this the connection would leak and the on-disk WAL would never be
        // checkpointed on the final close. Finalize + close must share one
        // serial-queue section — a racing exec between them would
        // re-prepare a statement, sqlite3_close would return SQLITE_BUSY,
        // and the handle would leak while `db` tombstoned to nil.
        // Do NOT wrap this in withDatabaseMutex: its defer calls
        // sqlite3_mutex_leave on the connection mutex, which is freed by
        // sqlite3_close inside — a use-after-free.
        perform {
            finalizeCachedStatements()
            if let db = db {
                if sqlite3_close(db) == SQLITE_OK {
                    self.db = nil
                }
                // SQLITE_BUSY: leave `db` in place — a future close() can
                // retry once whatever prepared the statement finalizes.
            }
        }
        if let cleanupPath { try? FileManager.default.removeItem(atPath: cleanupPath) }
    }

    deinit { close() }

    // MARK: - Schema

    /// Column names of a table in declared order; empty if it does not exist.
    ///
    /// A PRAGMA cannot take a bound parameter, so the name is interpolated —
    /// which is only safe while callers pass literals, hence the identifier
    /// check instead of a comment asking for one.
    func tableInfo(_ table: String) -> [String] {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        var names: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        while sqlite3_step(stmt) == SQLITE_ROW, let name = sqlite3_column_text(stmt, 1) {
            names.append(String(cString: name))
        }
        sqlite3_finalize(stmt)
        return names
    }

    private func createTables() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS whitelist (
                username        TEXT PRIMARY KEY,
                display_name    TEXT NOT NULL,
                is_group        INTEGER NOT NULL DEFAULT 0,
                category        TEXT NOT NULL CHECK(category IN ('work','life','other')),
                attention_level TEXT NOT NULL DEFAULT 'vip' CHECK(attention_level IN ('watch','vip')),
                added_at        INTEGER NOT NULL,
                auto_suggested  INTEGER NOT NULL DEFAULT 0
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS suggestions (
                username        TEXT PRIMARY KEY,
                display_name    TEXT NOT NULL,
                is_group        INTEGER NOT NULL DEFAULT 0,
                predicted_category TEXT NOT NULL,
                score           REAL NOT NULL,
                reason          TEXT,
                suggested_at    INTEGER NOT NULL,
                dismissed_until INTEGER
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS analysis_cache (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_username   TEXT NOT NULL,
                analysis_type   TEXT NOT NULL,
                input_hash      TEXT NOT NULL,
                result          TEXT NOT NULL,
                created_at      INTEGER NOT NULL,
                expires_at      INTEGER NOT NULL,
                UNIQUE(chat_username, analysis_type, input_hash)
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS reports (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                report_type     TEXT NOT NULL,
                category        TEXT,
                period_start    INTEGER NOT NULL,
                period_end      INTEGER NOT NULL,
                content         TEXT NOT NULL,
                created_at      INTEGER NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_state (
                source_key      TEXT PRIMARY KEY,
                last_local_id   INTEGER NOT NULL DEFAULT 0,
                last_check_at   INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Migration: add last_create_time for whitelist-scan baselines.
        // `last_local_id` can't be used as a cross-table cursor because
        // each `Msg_<hash>` table in each message_N.db has an independent
        // AUTOINCREMENT sequence — an id from one table has no meaning in
        // another. `create_time` is a unix timestamp so it's globally
        // comparable. Failure means the column already exists (older DB).
        _ = try? exec("ALTER TABLE sync_state ADD COLUMN last_create_time INTEGER NOT NULL DEFAULT 0")
        _ = try? exec("ALTER TABLE whitelist ADD COLUMN attention_level TEXT NOT NULL DEFAULT 'vip'")
        // Shard-aware + resumable backlog state:
        //  last_shard — the message_N.db relPath of the watermark row, so a
        //      same-second row written to a *different* shard isn't filtered
        //      by a localId comparison that only means something in-shard.
        //  backfill_* — the deepest point reached by an interrupted backlog
        //      walk, so a multi-page gap converges over scans instead of
        //      restarting at the page bottom every time.
        _ = try? exec("ALTER TABLE sync_state ADD COLUMN last_shard TEXT NOT NULL DEFAULT ''")
        _ = try? exec("ALTER TABLE sync_state ADD COLUMN backfill_create_time INTEGER NOT NULL DEFAULT 0")
        _ = try? exec("ALTER TABLE sync_state ADD COLUMN backfill_local_id INTEGER NOT NULL DEFAULT 0")

        // Self messages are scanned for commitments off the durable queues,
        // so a chat whose watermark is held (backlog still walking) would
        // re-run the same AI analysis every scan. This table marks each
        // analyzed msg_uid once.
        try exec("""
            CREATE TABLE IF NOT EXISTS commitment_scans (
                msg_uid     TEXT PRIMARY KEY,
                created_at  INTEGER NOT NULL,
                attempts    INTEGER NOT NULL DEFAULT 3
            )
        """)
        // Pre-migration rows were already marked-and-analyzed — they must
        // not gain retries. DEFAULT 3 = exhausted; new claims insert 1.
        _ = try? exec("ALTER TABLE commitment_scans ADD COLUMN attempts INTEGER NOT NULL DEFAULT 3")

        // Per-chat HUD-side action state (silence / snooze). Independent
        // from WeChat's own read state — we're layering our own triage
        // on top of whatever WeChat reports. Cleared only by explicit
        // action or a newer message (timestamp > silenced_at).
        try exec("""
            CREATE TABLE IF NOT EXISTS chat_actions (
                chat_username  TEXT PRIMARY KEY,
                silenced_at    INTEGER NOT NULL DEFAULT 0,
                snoozed_until  INTEGER NOT NULL DEFAULT 0,
                updated_at     INTEGER NOT NULL
            )
        """)

        // Per-chat sender ignores. More precise than `chat_actions`:
        // users can mute one noisy participant in a group without
        // suppressing the whole room.
        try exec("""
            CREATE TABLE IF NOT EXISTS ignored_senders (
                chat_username      TEXT NOT NULL,
                chat_name          TEXT NOT NULL,
                sender_identifier  TEXT NOT NULL,
                sender_username    TEXT NOT NULL,
                sender_name        TEXT NOT NULL,
                created_at         INTEGER NOT NULL,
                PRIMARY KEY(chat_username, sender_identifier)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ignored_senders_created_at ON ignored_senders(created_at DESC)")

        // Ignore rules gained a scope: a person can now be muted everywhere
        // ("global"), not only inside the one conversation where the rule was
        // created. Existing rows keep the old, narrower meaning.
        _ = try? exec("ALTER TABLE ignored_senders ADD COLUMN scope TEXT NOT NULL DEFAULT 'chat'")

        // Members the user wants to hear from inside one group, even when the
        // message is not an @. The room may be noisy overall while two or three
        // people in it are the reason to keep following it.
        try exec("""
            CREATE TABLE IF NOT EXISTS group_member_rules (
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                sender_username TEXT NOT NULL,
                sender_name     TEXT NOT NULL,
                created_at      INTEGER NOT NULL,
                PRIMARY KEY(chat_username, sender_username)
            )
        """)

        try exec("""
            CREATE TABLE IF NOT EXISTS scan_dismissed (
                username     TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                dismissed_at INTEGER NOT NULL
            )
        """)

        // AI subsystem tables. See:
        //   docs/superpowers/plans/2026-04-12-wechathud-ai-subsystem.md
        //
        // pending_asks: structured "what does this message ask of me"
        // records produced by the classifier. Drives the 待决 tab.
        try exec("""
            CREATE TABLE IF NOT EXISTS pending_asks (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                msg_uid         TEXT UNIQUE NOT NULL,
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                sender_name     TEXT NOT NULL,
                raw_text        TEXT NOT NULL,
                summary         TEXT NOT NULL,
                ask_type        TEXT NOT NULL,
                deadline_at     INTEGER,
                confidence      REAL NOT NULL,
                bucket          TEXT NOT NULL,
                status          TEXT NOT NULL,
                prompt_version  TEXT NOT NULL,
                created_at      INTEGER NOT NULL,
                updated_at      INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_pending_asks_status ON pending_asks(status, deadline_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_pending_asks_msg_uid ON pending_asks(msg_uid)")

        // ai_audit: one row per AI call across ALL roles. Used for debug
        // and weekly false-positive review. Pruned to last 14 days on open().
        try exec("""
            CREATE TABLE IF NOT EXISTS ai_audit (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                ts              INTEGER NOT NULL,
                role            TEXT NOT NULL,
                model           TEXT NOT NULL,
                prompt_version  TEXT NOT NULL,
                input_text      TEXT NOT NULL,
                output_text     TEXT NOT NULL,
                latency_ms      INTEGER NOT NULL,
                status          TEXT NOT NULL,
                error_message   TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_audit_ts ON ai_audit(ts DESC)")

        // ai_feedback: explicit user signals about classifier output.
        // Drives the manual weekly prompt-tuning loop.
        try exec("""
            CREATE TABLE IF NOT EXISTS ai_feedback (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                ts              INTEGER NOT NULL,
                msg_uid         TEXT NOT NULL,
                feedback_type   TEXT NOT NULL,
                original_output TEXT NOT NULL,
                user_action     TEXT,
                note            TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_ai_feedback_msg_uid ON ai_feedback(msg_uid)")

        // -- contacts table (four-tier system)
        try exec("""
            CREATE TABLE IF NOT EXISTS contacts (
                username            TEXT PRIMARY KEY,
                display_name        TEXT NOT NULL,
                attention_level     TEXT NOT NULL DEFAULT 'stranger',
                role                TEXT NOT NULL DEFAULT '',
                role_note           TEXT NOT NULL DEFAULT '',
                reply_window_minutes INTEGER NOT NULL DEFAULT 120,
                level_changed_at    INTEGER,
                created_at          INTEGER NOT NULL,
                updated_at          INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_contacts_level ON contacts(attention_level)")

        // -- vip_traces table
        try exec("""
            CREATE TABLE IF NOT EXISTS vip_traces (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                vip_username    TEXT NOT NULL,
                vip_name        TEXT NOT NULL,
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                msg_uid         TEXT UNIQUE NOT NULL,
                raw_text        TEXT NOT NULL,
                msg_time        INTEGER NOT NULL,
                batch_id        TEXT,
                created_at      INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_vip_traces_vip ON vip_traces(vip_username, msg_time)")
        try exec("CREATE INDEX IF NOT EXISTS idx_vip_traces_batch ON vip_traces(batch_id)")

        // -- recalled_messages table
        try exec("""
            CREATE TABLE IF NOT EXISTS recalled_messages (
                id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                msg_uid               TEXT UNIQUE NOT NULL,
                sender_username       TEXT NOT NULL,
                sender_name           TEXT NOT NULL,
                sender_level          TEXT NOT NULL,
                sender_role           TEXT NOT NULL,
                chat_username         TEXT NOT NULL,
                chat_name             TEXT NOT NULL,
                chat_type             TEXT NOT NULL,
                original_text         TEXT NOT NULL,
                sent_at               INTEGER NOT NULL,
                recalled_at           INTEGER NOT NULL,
                recall_delay_seconds  INTEGER NOT NULL,
                ai_reason             TEXT,
                ai_intelligence_value TEXT,
                ai_detail             TEXT,
                ai_should_notify      INTEGER,
                ai_notify_level       TEXT,
                ai_analyzed_at        INTEGER,
                ai_attempts           INTEGER NOT NULL DEFAULT 0,
                created_at            INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_recalled_sender ON recalled_messages(sender_username, recalled_at)")
        _ = try? exec("ALTER TABLE recalled_messages ADD COLUMN ai_attempts INTEGER NOT NULL DEFAULT 0")
        try exec("CREATE INDEX IF NOT EXISTS idx_recalled_time ON recalled_messages(recalled_at)")

        // -- commitments table
        try exec("""
            CREATE TABLE IF NOT EXISTS commitments (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                msg_uid         TEXT UNIQUE NOT NULL,
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                content         TEXT NOT NULL,
                commit_to       TEXT NOT NULL,
                deadline_at     INTEGER,
                confidence      REAL NOT NULL,
                status          TEXT NOT NULL DEFAULT 'pending',
                prompt_version  TEXT NOT NULL,
                source_text     TEXT NOT NULL DEFAULT '',
                context_text    TEXT NOT NULL DEFAULT '',
                capture_reason  TEXT NOT NULL DEFAULT '',
                next_step       TEXT NOT NULL DEFAULT '',
                deadline_label  TEXT NOT NULL DEFAULT '',
                commitment_kind TEXT NOT NULL DEFAULT '',
                created_at      INTEGER NOT NULL,
                updated_at      INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_commitments_status ON commitments(status, deadline_at)")
        _ = try? exec("ALTER TABLE commitments ADD COLUMN source_text TEXT NOT NULL DEFAULT ''")
        _ = try? exec("ALTER TABLE commitments ADD COLUMN context_text TEXT NOT NULL DEFAULT ''")
        _ = try? exec("ALTER TABLE commitments ADD COLUMN capture_reason TEXT NOT NULL DEFAULT ''")
        _ = try? exec("ALTER TABLE commitments ADD COLUMN next_step TEXT NOT NULL DEFAULT ''")
        _ = try? exec("ALTER TABLE commitments ADD COLUMN deadline_label TEXT NOT NULL DEFAULT ''")
        _ = try? exec("ALTER TABLE commitments ADD COLUMN commitment_kind TEXT NOT NULL DEFAULT ''")

        // -- discussion_items table (bidirectional work-item extraction)
        // Keyed by (chat_username, anchor_msg_uid, content) to dedupe
        // across re-scans of the same conversation window. Status is
        // mutable; everything else is write-once by the extractor.
        try exec("""
            CREATE TABLE IF NOT EXISTS discussion_items (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_username     TEXT NOT NULL,
                chat_name         TEXT NOT NULL,
                kind              TEXT NOT NULL,
                owner             TEXT NOT NULL,
                content           TEXT NOT NULL,
                detail            TEXT,
                anchor_msg_uid    TEXT NOT NULL,
                source_timestamp  INTEGER NOT NULL,
                due_at            INTEGER,
                status            TEXT NOT NULL DEFAULT 'pending',
                confidence        REAL NOT NULL,
                prompt_version    TEXT NOT NULL,
                created_at        INTEGER NOT NULL,
                updated_at        INTEGER NOT NULL,
                UNIQUE(chat_username, anchor_msg_uid, content)
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_disc_chat ON discussion_items(chat_username, source_timestamp)")
        try exec("CREATE INDEX IF NOT EXISTS idx_disc_status_time ON discussion_items(status, source_timestamp)")

        // -- autopilot_sessions table
        try exec("""
            CREATE TABLE IF NOT EXISTS autopilot_sessions (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at      INTEGER NOT NULL,
                ended_at        INTEGER,
                total_handled   INTEGER NOT NULL DEFAULT 0,
                total_pending   INTEGER NOT NULL DEFAULT 0,
                total_sent      INTEGER NOT NULL DEFAULT 0
            )
        """)

        // -- autopilot_log table
        try exec("""
            CREATE TABLE IF NOT EXISTS autopilot_log (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id      INTEGER NOT NULL,
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                sender_username TEXT NOT NULL,
                sender_name     TEXT NOT NULL,
                trigger_msg_uid TEXT NOT NULL,
                trigger_text    TEXT NOT NULL,
                generated_reply TEXT,
                confidence      REAL NOT NULL DEFAULT 0,
                risk_level      TEXT NOT NULL DEFAULT 'low',
                action          TEXT NOT NULL,
                ai_reasoning    TEXT,
                sent_at         INTEGER,
                created_at      INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_autopilot_log_session ON autopilot_log(session_id, created_at DESC)")
        try exec("CREATE INDEX IF NOT EXISTS idx_autopilot_log_action ON autopilot_log(action)")
        // The log row ↔ pending_sends row twin link. Rows written before
        // this column existed keep NULL and fall back to (chat, reply) text
        // matching — new rows always carry the queue item's UUID, so an
        // identical reply ("好的") can never resolve its sibling's twin.
        _ = try? exec("ALTER TABLE autopilot_log ADD COLUMN queue_id TEXT")
        // Best-effort, exactly like the column it indexes. The comment above
        // already declares a missing `queue_id` a runnable state (old rows
        // keep NULL and fall back to (chat, reply) text matching), so a hard
        // `try` here let one failed ALTER — another process holding the write
        // lock, a full or read-only volume — turn into `createTables()`
        // throwing, `store.open()` throwing, and AppDelegate terminating the
        // app on every launch for every existing database. A swallowed
        // failure is only honest if someone can see it, so print it.
        if (try? exec("CREATE INDEX IF NOT EXISTS idx_autopilot_log_queue_id ON autopilot_log(queue_id)")) == nil {
            print("[WCHUD] hud.sqlite3: idx_autopilot_log_queue_id unavailable; twin matching stays on (chat, reply) text")
        }

        // -- autopilot_pending_sends table
        try exec("""
            CREATE TABLE IF NOT EXISTS autopilot_pending_sends (
                id                  TEXT PRIMARY KEY,
                session_id          INTEGER NOT NULL,
                chat_username       TEXT NOT NULL,
                chat_name           TEXT NOT NULL,
                sender_name         TEXT NOT NULL,
                reply_text          TEXT NOT NULL,
                confidence          REAL NOT NULL DEFAULT 0,
                risk_level          TEXT NOT NULL DEFAULT 'low',
                reasoning           TEXT NOT NULL DEFAULT '',
                style_score         INTEGER NOT NULL DEFAULT 0,
                scheduled_send_at   INTEGER NOT NULL,
                created_at          INTEGER NOT NULL,
                peer_last_message   TEXT,
                topic               TEXT,
                auto_send_attempts  INTEGER NOT NULL DEFAULT 0,
                manual_only_reason  TEXT
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_autopilot_pending_session ON autopilot_pending_sends(session_id, scheduled_send_at)")

        // -- autopilot_inbound_queue table
        try exec("""
            CREATE TABLE IF NOT EXISTS autopilot_inbound_queue (
                msg_uid         TEXT PRIMARY KEY,
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                sender_username TEXT NOT NULL,
                sender_name     TEXT NOT NULL,
                text            TEXT NOT NULL,
                is_group        INTEGER NOT NULL DEFAULT 0,
                is_at_mention   INTEGER NOT NULL DEFAULT 0,
                attention_level TEXT NOT NULL DEFAULT 'stranger',
                contact_role    TEXT NOT NULL DEFAULT 'acquaintance',
                msg_timestamp   INTEGER NOT NULL,
                message_type    INTEGER NOT NULL DEFAULT 1,
                app_type        INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_autopilot_inbound_time ON autopilot_inbound_queue(msg_timestamp ASC, created_at ASC)")
        // Same message reappearing under a different msg_uid after a
        // cross-shard move must not enqueue twice.
        _ = try? exec("ALTER TABLE autopilot_inbound_queue ADD COLUMN content_key TEXT NOT NULL DEFAULT ''")
        _ = try? exec("CREATE INDEX IF NOT EXISTS idx_autopilot_content_key ON autopilot_inbound_queue(content_key)")

        // Migrations for pending_asks new columns (four-tier system)
        _ = try? exec("ALTER TABLE pending_asks ADD COLUMN sender_level TEXT")
        _ = try? exec("ALTER TABLE pending_asks ADD COLUMN sender_role TEXT")
        _ = try? exec("ALTER TABLE pending_asks ADD COLUMN urgency TEXT")

        // Reply drafts
        try exec("""
            CREATE TABLE IF NOT EXISTS reply_drafts (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_username   TEXT NOT NULL,
                chat_name       TEXT NOT NULL,
                text            TEXT NOT NULL,
                send_at         INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL
            )
        """)

        // Conversation memory — rolling 7-day summary per chat
        try exec("""
            CREATE TABLE IF NOT EXISTS conversation_memory (
                chat_username   TEXT PRIMARY KEY,
                summary         TEXT NOT NULL DEFAULT '',
                key_topics      TEXT NOT NULL DEFAULT '[]',
                pending_items   TEXT NOT NULL DEFAULT '[]',
                shared_context  TEXT NOT NULL DEFAULT '[]',
                communication_notes TEXT NOT NULL DEFAULT '[]',
                mood_trend      TEXT NOT NULL DEFAULT '',
                message_count_7d INTEGER NOT NULL DEFAULT 0,
                last_updated    INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Migrate: add whichever of the memory columns this file lacks, each on
        // its own. The previous shape probed only `shared_context` and then
        // applied the pair as a block, so a database where the first ALTER
        // landed and the second hit a busy or I/O error stayed missing
        // `communication_notes` for good — the guard was satisfied on every
        // later launch, no code path re-added the column, and the writer and
        // reader of that column failed silently for the life of the file.
        let memoryColumns = Set(tableInfo("conversation_memory"))
        for definition in [
            "shared_context TEXT NOT NULL DEFAULT '[]'",
            "communication_notes TEXT NOT NULL DEFAULT '[]'",
            "conversation_phase TEXT NOT NULL DEFAULT ''",
            "stance TEXT NOT NULL DEFAULT ''",
        ] where !memoryColumns.contains(String(definition.prefix(while: { $0 != " " }))) {
            try? exec("ALTER TABLE conversation_memory ADD COLUMN \(definition)")
        }

        // Prune stale conversation memories (not updated in 90 days)
        let ninetyDaysAgo = Int(Date().timeIntervalSince1970) - 90 * 86400
        try? exec("DELETE FROM conversation_memory WHERE last_updated > 0 AND last_updated < ?", params: [String(ninetyDaysAgo)])

        // Reply timing profiles — per-contact delay distribution
        try exec("""
            CREATE TABLE IF NOT EXISTS reply_timing_profiles (
                chat_username    TEXT PRIMARY KEY,
                work_hours       TEXT NOT NULL DEFAULT '{}',
                evening          TEXT NOT NULL DEFAULT '{}',
                weekend          TEXT NOT NULL DEFAULT '{}',
                late_night       TEXT NOT NULL DEFAULT '{}',
                silent_at_night  INTEGER NOT NULL DEFAULT 0,
                sample_count     INTEGER NOT NULL DEFAULT 0,
                last_updated     INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Relationship profiles — AI-inferred + user-edited relationship metadata
        try exec("""
            CREATE TABLE IF NOT EXISTS relationship_profiles (
                username         TEXT PRIMARY KEY,
                display_name     TEXT NOT NULL,
                relationship     TEXT NOT NULL,
                hierarchy        TEXT NOT NULL,
                tone_preference  TEXT NOT NULL,
                context          TEXT,
                confidence       REAL NOT NULL,
                user_note        TEXT,
                user_edited      INTEGER NOT NULL DEFAULT 0,
                inferred_at      INTEGER NOT NULL,
                updated_at       INTEGER NOT NULL
            )
        """)
    }

    // MARK: - Settings

    func getSetting(_ key: String) -> String? {
        if DeviceSettingsStore.sharedKeys.contains(key), let deviceSettings {
            return deviceSettings.get(key)
        }
        return queryOne(
            "SELECT value FROM settings WHERE key=?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
            },
            decode: { stmt in Self.textColumn(stmt, 0) }
        )
    }

    func setSetting(_ key: String, value: String) throws {
        if DeviceSettingsStore.sharedKeys.contains(key), let deviceSettings {
            try deviceSettings.set(key, value: value)
            return
        }
        try exec("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", params: [key, value])
    }

    /// Remove a row from the local `settings` table. Deliberately NOT routed
    /// through `deviceSettings`: this exists to scrub stale local copies
    /// (e.g. a plaintext API key) that the device store now shadows.
    func deleteSetting(_ key: String) throws {
        try exec("DELETE FROM settings WHERE key=?", params: [key])
    }

    func getSettingJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let raw = getSetting(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setSettingJSON<T: Encodable>(_ key: String, value: T) throws {
        if key == "ai", let config = value as? AIConfig {
            try persistAIConfig(config)
            return
        }
        let data = try JSONEncoder().encode(value)
        try setSetting(key, value: String(data: data, encoding: .utf8)!)
    }

    // MARK: - Whitelist

    func hasWhitelistEntries() -> Bool {
        queryOne("SELECT 1 FROM whitelist LIMIT 1", bind: { _ in }, decode: { _ in true }) ?? false
    }

    func whitelistCount() -> Int {
        queryOne("SELECT COUNT(*) FROM whitelist", bind: { _ in }, decode: { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }) ?? 0
    }

    func getWhitelist() -> [WhitelistEntry] {
        queryAll("""
            SELECT username, display_name, is_group, category, attention_level, added_at, auto_suggested
            FROM whitelist
            ORDER BY CASE attention_level WHEN 'vip' THEN 0 ELSE 1 END, category, display_name
        """, bind: { _ in }, decode: decodeWhitelistEntry)
    }

    func addToWhitelist(
        username: String,
        displayName: String,
        isGroup: Bool,
        category: WhitelistCategory,
        attentionLevel: WhitelistAttentionLevel = .watch
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT OR REPLACE INTO whitelist(
                username, display_name, is_group, category, attention_level, added_at, auto_suggested
            )
            VALUES(?,?,?,?,?,?,0)
        """, params: [
            username,
            displayName,
            isGroup ? "1" : "0",
            category.rawValue,
            attentionLevel.rawValue,
            "\(now)"
        ])

        let existingContact = getContact(username: username)
        let contactLevel: AttentionLevel = attentionLevel == .vip ? .vip : .whitelist
        let contactRole = existingContact?.role ?? defaultContactRole(for: category)
        let roleNote = existingContact?.roleNote ?? ""
        let replyWindow = existingContact?.replyWindowMinutes ?? contactRole.defaultReplyWindowMinutes

        try upsertContact(
            username: username,
            displayName: displayName,
            attentionLevel: contactLevel,
            role: contactRole,
            roleNote: roleNote,
            replyWindowMinutes: replyWindow
        )
    }

    /// Un-following a chat clears everything derived from that scope at once.
    /// These statements used to run one by one under `try?`, so a failure in
    /// the middle left the chat un-followed while its commitments kept firing
    /// and its todos stayed in the list — a half-applied state the UI had no
    /// way to show. One transaction means either the scope change is complete
    /// or nothing moved.
    func removeFromWhitelist(username: String) throws {
        try withTransaction {
            try untrackContact(username: username)
            try deleteContact(username: username)
            try clearDerivedArtifacts(chatUsername: username)
        }
    }

    func isWhitelisted(_ username: String) -> Bool {
        queryOne("SELECT 1 FROM whitelist WHERE username=?", bind: { stmt in
            sqlite3_bind_text(stmt, 1, username, -1, Self.sqliteTransient)
        }, decode: { _ in true }) ?? false
    }

    func getWhitelistEntry(username: String) -> WhitelistEntry? {
        queryOne("""
            SELECT username, display_name, is_group, category, attention_level, added_at, auto_suggested
            FROM whitelist
            WHERE username=?
            LIMIT 1
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, username, -1, Self.sqliteTransient)
        }, decode: decodeWhitelistEntry)
    }

    private func decodeWhitelistEntry(_ stmt: OpaquePointer?) -> WhitelistEntry? {
        guard let stmt else { return nil }
        let username = Self.textColumn(stmt, 0)
        guard !username.isEmpty else { return nil }
        return WhitelistEntry(
            id: username,
            displayName: Self.textColumn(stmt, 1),
            isGroup: sqlite3_column_int(stmt, 2) != 0,
            category: WhitelistCategory(rawValue: Self.textColumn(stmt, 3)) ?? .other,
            attentionLevel: WhitelistAttentionLevel(rawValue: Self.textColumn(stmt, 4)) ?? .vip,
            addedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5))),
            autoSuggested: sqlite3_column_int(stmt, 6) != 0
        )
    }

    // MARK: - Sync State

    func getSyncState(_ sourceKey: String) -> (lastLocalId: Int, lastCheckAt: Int)? {
        queryOne("SELECT last_local_id, last_check_at FROM sync_state WHERE source_key=?", bind: { stmt in
            sqlite3_bind_text(stmt, 1, sourceKey, -1, Self.sqliteTransient)
        }, decode: { stmt in
            (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        })
    }

    func updateSyncState(_ sourceKey: String, lastLocalId: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT OR REPLACE INTO sync_state(source_key, last_local_id, last_check_at)
            VALUES(?,?,?)
        """, params: [sourceKey, "\(lastLocalId)", "\(now)"])
    }

    /// Whitelist baseline — the max `create_time` we've already seen for a
    /// given whitelist username. `nil` means we've never scanned this
    /// entry before, in which case the caller MUST baseline it (without
    /// firing notifications) to prevent historical messages from being
    /// replayed as "new".
    func getWhitelistBaseline(username: String) -> Int? {
        getWhitelistCursor(username: username)?.lastCreateTime
    }

    func getWhitelistCursor(username: String) -> (lastCreateTime: Int, lastLocalId: Int, lastShard: String)? {
        getMessageCursor(sourceKey: "wl/\(username)")
    }

    func getAutopilotCursor(username: String) -> (lastCreateTime: Int, lastLocalId: Int, lastShard: String)? {
        getMessageCursor(sourceKey: "ap/\(username)")
    }

    private func getMessageCursor(sourceKey key: String) -> (lastCreateTime: Int, lastLocalId: Int, lastShard: String)? {
        guard let row: (time: Int, localId: Int, shard: String) = queryOne(
            "SELECT last_create_time, last_local_id, last_shard FROM sync_state WHERE source_key=?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
            },
            decode: { stmt in
                (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)), Self.textColumn(stmt, 2))
            }
        ) else { return nil }
        let time = row.time
        let localId = row.localId
        // DEFAULT 0 from the migration means "never baselined" — treat it
        // exactly the same as a missing row so migration from old state
        // forces a fresh baseline instead of replaying history.
        // Rows created before the cursor carried local_id have 0 here.
        // Treat that as "all messages in this second were already seen"
        // to avoid a one-time replay of historical same-second rows after
        // upgrading.
        let safeLocalId = localId > 0 ? localId : Int.max
        return time > 0 ? (time, safeLocalId, row.shard) : nil
    }

    /// Deepest point an interrupted backlog walk reached for this chat.
    /// nil means no backfill is in flight.
    func getBackfillCursor(username: String) -> (lastCreateTime: Int, lastLocalId: Int)? {
        guard let row: (time: Int, localId: Int) = queryOne(
            "SELECT backfill_create_time, backfill_local_id FROM sync_state WHERE source_key=?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, "wl/\(username)", -1, Self.sqliteTransient)
            },
            decode: { stmt in
                (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
            }
        ), row.time > 0 else { return nil }
        return (row.time, row.localId)
    }

    /// A scan watermark must never sit ahead of the wall clock. `create_time` is
    /// WeChat's column: one future-dated row (clock-jacked client, corrupt or
    /// future-schema DB) written into the cursor makes every later real message
    /// look already seen, and the cursor only moves forward — that chat stops
    /// feeding classification, todos, commitments and autopilot with no retry
    /// and no self-heal until wall time catches up. The notification path already
    /// caps at `now` for the same reason; the persisted cursors must too.
    nonisolated static func clampedCursorTime(_ value: Int, now: Int) -> Int {
        min(max(value, 0), now)
    }

    func setBackfillCursor(username: String, lastCreateTime: Int, lastLocalId: Int) throws {
        let cursorTime = Self.clampedCursorTime(
            lastCreateTime, now: Int(Date().timeIntervalSince1970))
        try exec("""
            INSERT INTO sync_state(source_key, backfill_create_time, backfill_local_id)
            VALUES(?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                backfill_create_time = excluded.backfill_create_time,
                backfill_local_id    = excluded.backfill_local_id
        """, params: ["wl/\(username)", "\(cursorTime)", "\(lastLocalId)"])
    }

    func clearBackfillCursor(username: String) throws {
        try exec("""
            UPDATE sync_state SET backfill_create_time=0, backfill_local_id=0
            WHERE source_key=?
        """, params: ["wl/\(username)"])
    }

    func setWhitelistBaseline(username: String, lastCreateTime: Int) throws {
        try setWhitelistCursor(username: username, lastCreateTime: lastCreateTime, lastLocalId: 0)
    }

    func setWhitelistCursor(username: String, lastCreateTime: Int, lastLocalId: Int, lastShard: String = "") throws {
        try setMessageCursor(sourceKey: "wl/\(username)", lastCreateTime: lastCreateTime, lastLocalId: lastLocalId, lastShard: lastShard)
    }

    func setAutopilotCursor(username: String, lastCreateTime: Int, lastLocalId: Int, lastShard: String = "") throws {
        try setMessageCursor(sourceKey: "ap/\(username)", lastCreateTime: lastCreateTime, lastLocalId: lastLocalId, lastShard: lastShard)
    }

    private func setMessageCursor(sourceKey key: String, lastCreateTime: Int, lastLocalId: Int, lastShard: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        let cursorTime = Self.clampedCursorTime(lastCreateTime, now: now)
        try exec("""
            INSERT INTO sync_state(source_key, last_local_id, last_check_at, last_create_time, last_shard)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                last_local_id    = excluded.last_local_id,
                last_create_time = excluded.last_create_time,
                last_check_at    = excluded.last_check_at,
                last_shard       = excluded.last_shard
        """, params: [key, "\(lastLocalId)", "\(now)", "\(cursorTime)", lastShard])
    }

    // MARK: - Chat actions (HUD-side triage state)

    struct ChatActionState {
        let silencedAt: Int    // unix seconds; items with ts ≤ this are hidden
        let snoozedUntil: Int  // unix seconds; entire chat suppressed until this
    }

    static func senderIdentifier(senderUsername: String, senderName: String) -> String {
        let normalizedUsername = senderUsername
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedUsername.isEmpty {
            return "username:\(normalizedUsername)"
        }
        let normalizedName = senderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "name:\(normalizedName)"
    }

    func loadChatActions() -> [String: ChatActionState] {
        let rows: [(String, ChatActionState)] = queryAll(
            "SELECT chat_username, silenced_at, snoozed_until FROM chat_actions",
            bind: { _ in },
            decode: { stmt in
                let username = Self.textColumn(stmt, 0)
                guard !username.isEmpty else { return nil }
                return (
                    username,
                    ChatActionState(
                        silencedAt: Int(sqlite3_column_int64(stmt, 1)),
                        snoozedUntil: Int(sqlite3_column_int64(stmt, 2))
                    )
                )
            }
        )
        return rows.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    /// Silence a chat up to and including `silencedAt` — any unread item
    /// whose timestamp is ≤ this value is suppressed. Newer messages in
    /// the same chat pass through unaffected.
    func silenceChat(chatUsername: String, silencedAt: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO chat_actions(chat_username, silenced_at, snoozed_until, updated_at)
            VALUES(?, ?, 0, ?)
            ON CONFLICT(chat_username) DO UPDATE SET
                silenced_at   = excluded.silenced_at,
                snoozed_until = 0,
                updated_at    = excluded.updated_at
        """, params: [chatUsername, "\(silencedAt)", "\(now)"])
    }

    /// Snooze an entire chat (regardless of message timestamps) until
    /// the given unix second. All unread items from that chat are hidden
    /// while `now < snoozed_until`.
    func snoozeChat(chatUsername: String, until: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO chat_actions(chat_username, silenced_at, snoozed_until, updated_at)
            VALUES(?, 0, ?, ?)
            ON CONFLICT(chat_username) DO UPDATE SET
                snoozed_until = excluded.snoozed_until,
                silenced_at   = 0,
                updated_at    = excluded.updated_at
        """, params: [chatUsername, "\(until)", "\(now)"])
    }

    func clearChatAction(chatUsername: String) throws {
        try exec("DELETE FROM chat_actions WHERE chat_username=?", params: [chatUsername])
    }

    func loadIgnoredSenders() -> [IgnoredSenderRule] {
        queryAll("""
            SELECT chat_username, chat_name, sender_identifier, sender_username, sender_name, created_at, scope
            FROM ignored_senders
            ORDER BY created_at DESC, chat_name ASC, sender_name ASC
        """, bind: { _ in }, decode: { stmt in
            IgnoredSenderRule(
                chatUsername: Self.textColumn(stmt, 0),
                chatName: Self.textColumn(stmt, 1),
                senderIdentifier: Self.textColumn(stmt, 2),
                senderUsername: Self.textColumn(stmt, 3),
                senderName: Self.textColumn(stmt, 4),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5))),
                scope: IgnoredSenderScope(rawValue: Self.textColumn(stmt, 6)) ?? .chat
            )
        })
    }

    /// Sentinel conversation key for a rule that follows the person everywhere.
    /// A sentinel keeps the existing composite primary key meaningful instead of
    /// widening it to nullable columns.
    static let globalIgnoreScopeKey = "*"

    func loadIgnoredSenderMap() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for rule in loadIgnoredSenders() where rule.scope == .chat {
            map[rule.chatUsername, default: []].insert(rule.senderIdentifier)
        }
        return map
    }

    /// Senders muted in every conversation.
    func loadGlobalIgnoredSenders() -> Set<String> {
        Set(
            loadIgnoredSenders()
                .filter { $0.scope == .global }
                .map(\.senderIdentifier)
        )
    }

    /// Mute a person everywhere. Independent of any single conversation, so it
    /// survives the user leaving or re-adding a chat.
    func ignoreSenderEverywhere(
        senderUsername: String,
        senderName: String
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        let identifier = HUDStore.senderIdentifier(
            senderUsername: senderUsername,
            senderName: senderName
        )
        try exec("""
            INSERT INTO ignored_senders(
                chat_username, chat_name, sender_identifier,
                sender_username, sender_name, created_at, scope
            )
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(chat_username, sender_identifier) DO UPDATE SET
                chat_name       = excluded.chat_name,
                sender_username = excluded.sender_username,
                sender_name     = excluded.sender_name,
                scope           = excluded.scope
        """, params: [
            Self.globalIgnoreScopeKey,
            senderName,
            identifier,
            senderUsername,
            senderName,
            "\(now)",
            IgnoredSenderScope.global.rawValue
        ])
    }

    func ignoreSender(
        chatUsername: String,
        chatName: String,
        senderUsername: String,
        senderName: String
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        let identifier = HUDStore.senderIdentifier(
            senderUsername: senderUsername,
            senderName: senderName
        )
        try exec("""
            INSERT INTO ignored_senders(
                chat_username, chat_name, sender_identifier,
                sender_username, sender_name, created_at
            )
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(chat_username, sender_identifier) DO UPDATE SET
                chat_name       = excluded.chat_name,
                sender_username = excluded.sender_username,
                sender_name     = excluded.sender_name
        """, params: [
            chatUsername,
            chatName,
            identifier,
            senderUsername,
            senderName,
            "\(now)"
        ])
    }

    func unignoreSender(
        chatUsername: String,
        senderUsername: String,
        senderName: String
    ) throws {
        try exec("""
            DELETE FROM ignored_senders
            WHERE chat_username=? AND sender_identifier=?
        """, params: [
            chatUsername,
            HUDStore.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
        ])
    }

    func isSenderIgnored(
        chatUsername: String,
        senderUsername: String,
        senderName: String
    ) -> Bool {
        let identifier = HUDStore.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
        return queryOne("""
            SELECT 1
            FROM ignored_senders
            WHERE chat_username=? AND sender_identifier=?
            LIMIT 1
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 2, identifier, -1, Self.sqliteTransient)
        }, decode: { _ in true }) ?? false
    }

    // MARK: - Message admission

    func loadAdmissionConfig() -> AdmissionConfig {
        getSettingJSON("admission", as: AdmissionConfig.self) ?? AdmissionConfig()
    }

    func saveAdmissionConfig(_ config: AdmissionConfig) throws {
        try setSettingJSON("admission", value: config)
    }

    // MARK: - Group member rules

    func loadGroupMemberRules() -> [GroupMemberRule] {
        queryAll("""
            SELECT chat_username, chat_name, sender_username, sender_name, created_at
            FROM group_member_rules
            ORDER BY created_at DESC, chat_name ASC, sender_name ASC
        """, bind: { _ in }, decode: { stmt in
            GroupMemberRule(
                chatUsername: Self.textColumn(stmt, 0),
                chatName: Self.textColumn(stmt, 1),
                senderUsername: Self.textColumn(stmt, 2),
                senderName: Self.textColumn(stmt, 3),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
            )
        })
    }

    /// group username → members whose messages should surface.
    func loadGroupMemberMap() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for rule in loadGroupMemberRules() {
            map[rule.chatUsername, default: []].insert(rule.senderUsername)
        }
        return map
    }

    func addGroupMemberRule(
        chatUsername: String,
        chatName: String,
        senderUsername: String,
        senderName: String
    ) throws {
        guard !senderUsername.isEmpty else { return }
        try exec("""
            INSERT INTO group_member_rules(
                chat_username, chat_name, sender_username, sender_name, created_at
            )
            VALUES(?,?,?,?,?)
            ON CONFLICT(chat_username, sender_username) DO UPDATE SET
                chat_name   = excluded.chat_name,
                sender_name = excluded.sender_name
        """, params: [
            chatUsername,
            chatName,
            senderUsername,
            senderName,
            "\(Int(Date().timeIntervalSince1970))"
        ])
    }

    func removeGroupMemberRule(chatUsername: String, senderUsername: String) throws {
        try exec("""
            DELETE FROM group_member_rules
            WHERE chat_username=? AND sender_username=?
        """, params: [chatUsername, senderUsername])
    }

    // MARK: - Scan Dismissed

    func dismissScanResult(username: String, displayName: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT OR REPLACE INTO scan_dismissed(username, display_name, dismissed_at)
            VALUES(?,?,?)
        """, params: [username, displayName, "\(now)"])
    }

    func undismissScanResult(username: String) throws {
        try exec("DELETE FROM scan_dismissed WHERE username=?", params: [username])
    }

    func loadDismissedScanResults() -> [ScanDismissedEntry] {
        queryAll("""
            SELECT username, display_name, dismissed_at
            FROM scan_dismissed ORDER BY dismissed_at DESC
        """, bind: { _ in }, decode: { stmt in
            ScanDismissedEntry(
                username: Self.textColumn(stmt, 0),
                displayName: Self.textColumn(stmt, 1),
                dismissedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
            )
        })
    }

    func dismissedScanUsernames() -> Set<String> {
        Set(queryAll(
            "SELECT username FROM scan_dismissed",
            bind: { _ in },
            decode: { stmt in Self.textColumn(stmt, 0) }
        ))
    }

    // MARK: - AI: pending_asks

    /// Insert or update an ask. Dedup is by `msg_uid`. The provided
    /// `ask.id` is ignored — SQLite assigns one on insert; on conflict
    /// the existing row is updated in place (preserving its id and
    /// `created_at`, refreshing everything else and `updated_at`).
    func upsertPendingAsk(_ ask: PendingAsk) throws {
        let now = Int(Date().timeIntervalSince1970)
        let createdAt = Int(ask.createdAt.timeIntervalSince1970)
        // NULL, not '' — an empty string stores as TEXT in this INTEGER-
        // affinity column, outranks every number in comparisons, and makes
        // `deadline_at IS NULL` / `= 0` predicates misjudge the row.
        // COALESCE keeps a previously stored deadline when a re-extraction
        // (queue replay under a surviving msg_uid) comes back without one —
        // unconditional overwrite would silently wipe it.
        let deadline: String? = ask.deadlineAt.map { String(Int($0.timeIntervalSince1970)) }
        try exec("""
            INSERT INTO pending_asks(
                msg_uid, chat_username, chat_name, sender_name, raw_text,
                summary, ask_type, deadline_at, confidence, bucket, status,
                prompt_version, created_at, updated_at,
                sender_level, sender_role, urgency
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(msg_uid) DO UPDATE SET
                summary        = excluded.summary,
                ask_type       = excluded.ask_type,
                deadline_at    = COALESCE(excluded.deadline_at, pending_asks.deadline_at),
                confidence     = excluded.confidence,
                bucket         = excluded.bucket,
                status         = CASE
                    WHEN pending_asks.status IN ('done', 'dismissed')
                    THEN pending_asks.status
                    ELSE excluded.status
                END,
                prompt_version = excluded.prompt_version,
                updated_at     = excluded.updated_at,
                sender_level   = excluded.sender_level,
                sender_role    = excluded.sender_role,
                urgency        = excluded.urgency
        """, params: [
            ask.msgUID,
            ask.chatUsername,
            ask.chatName,
            ask.senderName,
            ask.rawText,
            ask.summary,
            ask.askType.rawValue,
            deadline,
            String(ask.confidence),
            ask.bucket.rawValue,
            ask.status.rawValue,
            ask.promptVersion,
            String(createdAt),
            String(now),
            ask.senderLevel?.rawValue ?? "",
            ask.senderRole?.rawValue ?? "",
            ask.urgency?.rawValue ?? ""
        ])
    }

    /// Load asks filtered by bucket and/or status. Pass nil to skip a
    /// filter. Sort: items with a deadline come first (earliest deadline
    /// first), then dateless items by creation time descending.
    func loadPendingAsks(
        bucket: AskBucket? = nil,
        status: AskStatus? = nil,
        relevantSince: Int? = nil
    ) -> [PendingAsk] {
        let decode: (OpaquePointer?) -> PendingAsk? = { stmt in
            guard let stmt else { return nil }
            let deadlineRaw = sqlite3_column_int64(stmt, 8)
            let deadline: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL || deadlineRaw == 0
                ? nil
                : Date(timeIntervalSince1970: TimeInterval(deadlineRaw))
            let senderLevelStr: String? = sqlite3_column_type(stmt, 15) == SQLITE_NULL
                ? nil : Self.textColumn(stmt, 15)
            let senderRoleStr: String? = sqlite3_column_type(stmt, 16) == SQLITE_NULL
                ? nil : Self.textColumn(stmt, 16)
            let urgencyStr: String? = sqlite3_column_type(stmt, 17) == SQLITE_NULL
                ? nil : Self.textColumn(stmt, 17)
            return PendingAsk(
                id: sqlite3_column_int64(stmt, 0),
                msgUID: Self.textColumn(stmt, 1),
                chatUsername: Self.textColumn(stmt, 2),
                chatName: Self.textColumn(stmt, 3),
                senderName: Self.textColumn(stmt, 4),
                rawText: Self.textColumn(stmt, 5),
                summary: Self.textColumn(stmt, 6),
                askType: AskType(rawValue: Self.textColumn(stmt, 7)) ?? .none,
                deadlineAt: deadline,
                confidence: sqlite3_column_double(stmt, 9),
                bucket: AskBucket(rawValue: Self.textColumn(stmt, 10)) ?? .review,
                status: AskStatus(rawValue: Self.textColumn(stmt, 11)) ?? .pending,
                promptVersion: Self.textColumn(stmt, 12),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 13))),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 14))),
                senderLevel: senderLevelStr.flatMap { s in s.isEmpty ? nil : AttentionLevel(rawValue: s) },
                senderRole: senderRoleStr.flatMap { s in s.isEmpty ? nil : ContactRole(rawValue: s) },
                urgency: urgencyStr.flatMap { s in s.isEmpty ? nil : AskUrgency(rawValue: s) }
            )
        }
        let results: [PendingAsk]
        switch (bucket, status) {
        case (nil, nil):
            results = queryAll("""
                SELECT id, msg_uid, chat_username, chat_name, sender_name, raw_text,
                       summary, ask_type, deadline_at, confidence, bucket, status,
                       prompt_version, created_at, updated_at,
                       sender_level, sender_role, urgency
                FROM pending_asks
                ORDER BY (deadline_at IS NULL OR deadline_at = 0), deadline_at ASC, created_at DESC
                """, bind: { _ in }, decode: decode)
        case let (bucket?, nil):
            results = queryAll("""
                SELECT id, msg_uid, chat_username, chat_name, sender_name, raw_text,
                       summary, ask_type, deadline_at, confidence, bucket, status,
                       prompt_version, created_at, updated_at,
                       sender_level, sender_role, urgency
                FROM pending_asks
                WHERE bucket=?
                ORDER BY (deadline_at IS NULL OR deadline_at = 0), deadline_at ASC, created_at DESC
                """, bind: { sqlite3_bind_text($0, 1, bucket.rawValue, -1, Self.sqliteTransient) }, decode: decode)
        case let (nil, status?):
            results = queryAll("""
                SELECT id, msg_uid, chat_username, chat_name, sender_name, raw_text,
                       summary, ask_type, deadline_at, confidence, bucket, status,
                       prompt_version, created_at, updated_at,
                       sender_level, sender_role, urgency
                FROM pending_asks
                WHERE status=?
                ORDER BY (deadline_at IS NULL OR deadline_at = 0), deadline_at ASC, created_at DESC
                """, bind: { sqlite3_bind_text($0, 1, status.rawValue, -1, Self.sqliteTransient) }, decode: decode)
        case let (bucket?, status?):
            results = queryAll("""
                SELECT id, msg_uid, chat_username, chat_name, sender_name, raw_text,
                       summary, ask_type, deadline_at, confidence, bucket, status,
                       prompt_version, created_at, updated_at,
                       sender_level, sender_role, urgency
                FROM pending_asks
                WHERE bucket=? AND status=?
                ORDER BY (deadline_at IS NULL OR deadline_at = 0), deadline_at ASC, created_at DESC
                """, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, bucket.rawValue, -1, Self.sqliteTransient)
                    sqlite3_bind_text(stmt, 2, status.rawValue, -1, Self.sqliteTransient)
                }, decode: decode)
        }
        if let relevantSince {
            return results.filter { DiscussionLiveWindow.contains($0, cutoff: relevantSince) }
        }
        return results
    }

    /// Has the classifier already produced a row for this message? Used
    /// by `ChatMonitor` to avoid re-classifying messages on every scan.
    func hasPendingAsk(msgUID: String) -> Bool {
        queryOne(
            "SELECT 1 FROM pending_asks WHERE msg_uid=? LIMIT 1",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, msgUID, -1, Self.sqliteTransient)
            },
            decode: { _ in true }
        ) ?? false
    }

    func updatePendingAskStatus(msgUID: String, status: AskStatus) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE pending_asks SET status=?, updated_at=? WHERE msg_uid=?
        """, params: [status.rawValue, "\(now)", msgUID])
    }

    func dismissPendingAsk(msgUID: String) throws {
        try updatePendingAskStatus(msgUID: msgUID, status: .dismissed)
    }

    // MARK: - AI: ai_audit

    /// Append one row to the audit log. Called from every AI service on
    /// every call (success and failure). Best-effort — if this throws,
    /// the caller logs and moves on; we never want audit failures to
    /// break a real user flow.
    func writeAIAudit(_ entry: AIAuditEntry) throws {
        let ts = Int(entry.ts.timeIntervalSince1970)
        try exec("""
            INSERT INTO ai_audit(
                ts, role, model, prompt_version, input_text, output_text,
                latency_ms, status, error_message
            )
            VALUES(?,?,?,?,?,?,?,?,?)
        """, params: [
            "\(ts)",
            entry.role.rawValue,
            entry.model,
            entry.promptVersion,
            AIAuditPrivacy.persistableText(entry.inputText),
            AIAuditPrivacy.persistableText(entry.outputText),
            "\(entry.latencyMs)",
            entry.status.rawValue,
            // Error strings embed raw provider bodies — an endpoint can echo
            // anything (including secrets) into them, unbounded. Redact +
            // cap; no sha prefix — there is no raw row to correlate it with.
            String(Redactor.applyMasks(entry.errorMessage ?? "")
                .prefix(AIAuditPrivacy.snippetLimit))
        ])
    }

    /// Most recent audit entries, newest first. For debug viewing only —
    /// the table can grow large so always pass a sane limit.
    func loadRecentAIAudit(
        limit: Int = 100,
        role: AIRole? = nil,
        promptVersionPrefix: String? = nil
    ) -> [AIAuditEntry] {
        let prefix = (promptVersionPrefix?.isEmpty == false) ? promptVersionPrefix : nil
        let decode: (OpaquePointer?) -> AIAuditEntry? = { stmt in
            guard let stmt else { return nil }
            let errMsg: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil : Self.textColumn(stmt, 9)
            return AIAuditEntry(
                id: sqlite3_column_int64(stmt, 0),
                ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                role: AIRole(rawValue: Self.textColumn(stmt, 2)) ?? .classifier,
                model: Self.textColumn(stmt, 3),
                promptVersion: Self.textColumn(stmt, 4),
                inputText: Self.textColumn(stmt, 5),
                outputText: Self.textColumn(stmt, 6),
                latencyMs: Int(sqlite3_column_int64(stmt, 7)),
                status: AIAuditStatus(rawValue: Self.textColumn(stmt, 8)) ?? .ok,
                errorMessage: (errMsg?.isEmpty == true) ? nil : errMsg
            )
        }
        switch (role, prefix) {
        case (nil, nil):
            return queryAll("""
                SELECT id, ts, role, model, prompt_version, input_text, output_text,
                       latency_ms, status, error_message
                FROM ai_audit
                ORDER BY ts DESC
                LIMIT ?
                """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }, decode: decode)
        case let (role?, nil):
            return queryAll("""
                SELECT id, ts, role, model, prompt_version, input_text, output_text,
                       latency_ms, status, error_message
                FROM ai_audit
                WHERE role=?
                ORDER BY ts DESC
                LIMIT ?
                """, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, role.rawValue, -1, Self.sqliteTransient)
                    sqlite3_bind_int64(stmt, 2, Int64(limit))
                }, decode: decode)
        case let (nil, prefix?):
            let like = "\(prefix)%"
            return queryAll("""
                SELECT id, ts, role, model, prompt_version, input_text, output_text,
                       latency_ms, status, error_message
                FROM ai_audit
                WHERE prompt_version LIKE ?
                ORDER BY ts DESC
                LIMIT ?
                """, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, like, -1, Self.sqliteTransient)
                    sqlite3_bind_int64(stmt, 2, Int64(limit))
                }, decode: decode)
        case let (role?, prefix?):
            let like = "\(prefix)%"
            return queryAll("""
                SELECT id, ts, role, model, prompt_version, input_text, output_text,
                       latency_ms, status, error_message
                FROM ai_audit
                WHERE role=? AND prompt_version LIKE ?
                ORDER BY ts DESC
                LIMIT ?
                """, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, role.rawValue, -1, Self.sqliteTransient)
                    sqlite3_bind_text(stmt, 2, like, -1, Self.sqliteTransient)
                    sqlite3_bind_int64(stmt, 3, Int64(limit))
                }, decode: decode)
        }
    }

    // MARK: - AI housekeeping

    /// Best-effort retention for verbose AI audit logs. Keeps the table
    /// bounded without turning startup into a migration workflow.
    func pruneAIAudit(olderThanDays days: Int) throws {
        let cutoff = Int(Date().timeIntervalSince1970) - max(0, days) * 24 * 3600
        try exec("DELETE FROM ai_audit WHERE ts < ?", params: ["\(cutoff)"])
    }

    // MARK: - Analysis cache

    func loadAnalysisCache(
        chatUsername: String,
        analysisType: String,
        inputHash: String,
        now: Date = Date()
    ) -> String? {
        let nowTs = Int64(now.timeIntervalSince1970)
        let cached: (result: String, expiresAt: Int64)? = queryOne("""
            SELECT result, expires_at
            FROM analysis_cache
            WHERE chat_username=? AND analysis_type=? AND input_hash=?
            LIMIT 1
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 2, analysisType, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 3, inputHash, -1, Self.sqliteTransient)
        }, decode: { stmt in
            (Self.textColumn(stmt, 0), sqlite3_column_int64(stmt, 1))
        })
        guard let cached else { return nil }
        if cached.expiresAt <= nowTs {
            try? exec("""
                DELETE FROM analysis_cache
                WHERE chat_username=? AND analysis_type=? AND input_hash=?
            """, params: [chatUsername, analysisType, inputHash])
            return nil
        }
        return cached.result
    }

    func writeAnalysisCache(
        chatUsername: String,
        analysisType: String,
        inputHash: String,
        result: String,
        ttlHours: Int,
        now: Date = Date()
    ) throws {
        let createdAt = Int(now.timeIntervalSince1970)
        let expiresAt = createdAt + max(1, ttlHours) * 3600
        try exec("""
            INSERT INTO analysis_cache(
                chat_username, analysis_type, input_hash, result, created_at, expires_at
            )
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(chat_username, analysis_type, input_hash)
            DO UPDATE SET
                result = excluded.result,
                created_at = excluded.created_at,
                expires_at = excluded.expires_at
        """, params: [
            chatUsername,
            analysisType,
            inputHash,
            result,
            "\(createdAt)",
            "\(expiresAt)"
        ])
    }

    // MARK: - AI: ai_feedback

    func writeAIFeedback(_ entry: AIFeedbackEntry) throws {
        let ts = Int(entry.ts.timeIntervalSince1970)
        try exec("""
            INSERT INTO ai_feedback(
                ts, msg_uid, feedback_type, original_output, user_action, note
            )
            VALUES(?,?,?,?,?,?)
        """, params: [
            "\(ts)",
            entry.msgUID,
            entry.feedbackType.rawValue,
            // Model output can echo raw message text — redact + cap it like
            // the audit table does rather than persisting it verbatim.
            AIAuditPrivacy.persistableText(entry.originalOutput),
            entry.userAction ?? "",
            entry.note ?? ""
        ])
    }

    func loadAIFeedback(limit: Int = 200, msgUIDPrefix: String? = nil) -> [AIFeedbackEntry] {
        let decode: (OpaquePointer?) -> AIFeedbackEntry? = { stmt in
            guard let stmt else { return nil }
            let userAction: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : Self.textColumn(stmt, 5)
            let note: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil : Self.textColumn(stmt, 6)
            return AIFeedbackEntry(
                id: sqlite3_column_int64(stmt, 0),
                ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                msgUID: Self.textColumn(stmt, 2),
                feedbackType: AIFeedbackType(rawValue: Self.textColumn(stmt, 3)) ?? .truePositive,
                originalOutput: Self.textColumn(stmt, 4),
                userAction: (userAction?.isEmpty == true) ? nil : userAction,
                note: (note?.isEmpty == true) ? nil : note
            )
        }
        if let msgUIDPrefix, !msgUIDPrefix.isEmpty {
            let like = "\(msgUIDPrefix)%"
            return queryAll("""
                SELECT id, ts, msg_uid, feedback_type, original_output, user_action, note
                FROM ai_feedback
                WHERE msg_uid LIKE ?
                ORDER BY ts DESC
                LIMIT ?
                """, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, like, -1, Self.sqliteTransient)
                    sqlite3_bind_int64(stmt, 2, Int64(limit))
                }, decode: decode)
        }
        return queryAll("""
            SELECT id, ts, msg_uid, feedback_type, original_output, user_action, note
            FROM ai_feedback
            ORDER BY ts DESC
            LIMIT ?
            """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }, decode: decode)
    }

    func loadLatestAIFeedbackByMsgUID(
        limit: Int = 200,
        msgUIDPrefix: String? = nil
    ) -> [String: AIFeedbackEntry] {
        var latest: [String: AIFeedbackEntry] = [:]
        for entry in loadAIFeedback(limit: limit, msgUIDPrefix: msgUIDPrefix) {
            if latest[entry.msgUID] == nil {
                latest[entry.msgUID] = entry
            }
        }
        return latest
    }

    // MARK: - AI: config seed (single source of truth)
    //
    // This section is the ONLY place in the codebase that knows the
    // factory values for AI endpoints and model names. Everywhere else
    // reads via `loadAIConfig()`. Editing the values below is the only
    // way to change "what model do we ship with" — runtime management
    // after first launch happens through the settings table (or future UI).

    private static let factoryAIConfig: AIConfig = {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKey: ""
        )
        cfg.maxTokens = 2048
        cfg.temperature = 0.3
        return cfg
    }()

    func seedAISettingsIfMissing() {
        if getSetting("ai") == nil {
            // First launch or migrate from "classifier" key
            if let oldCls = getSetting("classifier"),
               let data = oldCls.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var cfg = HUDStore.factoryAIConfig
                if let url = json["baseURL"] as? String { cfg.provider.baseURL = url }
                if let model = json["model"] as? String { cfg.provider.model = model }
                if let key = json["apiKey"] as? String { cfg.provider.apiKey = key }
                try? setSettingJSON("ai", value: cfg)
                // The legacy row holds the API key in plaintext — copying it
                // without deleting keeps the secret at rest forever.
                try? deleteSetting("classifier")
                print("[WCHUD] migrated classifier config → ai config")
            } else {
                try? setSettingJSON("ai", value: HUDStore.factoryAIConfig)
                print("[WCHUD] seeded settings.ai (first launch)")
            }
        } else {
            // Existing config — migrate from single-provider to dual-provider if needed
            var cfg = loadAIConfig()
            if cfg.provider.baseURL.isEmpty, cfg.provider.providerID != "openai-codex", let url = cfg._legacyBaseURL, !url.isEmpty {
                cfg.migrateIfNeeded()
                try? setSettingJSON("ai", value: cfg)
                print("[WCHUD] migrated single-provider ai config")
            }
        }

        if getSetting("role_configs") == nil {
            let configs: [String: RoleConfig] = [
                "boss": RoleConfig(replyWindow: 30, notifyLevel: "strong", classifierStrictness: "high", replyTone: "reporting", vipTrackDimensions: ["decisions", "mood", "dissatisfaction", "directives"]),
                "key_client": RoleConfig(replyWindow: 60, notifyLevel: "strong", classifierStrictness: "high", replyTone: "professional", vipTrackDimensions: ["complaints", "needs", "competitor_mentions", "praise"]),
                "family": RoleConfig(replyWindow: 120, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "casual", vipTrackDimensions: ["health", "safety", "life_arrangements", "emotions"]),
                "partner": RoleConfig(replyWindow: 120, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "professional", vipTrackDimensions: ["project_progress", "attitude_shifts", "competitor_activity"]),
                "colleague": RoleConfig(replyWindow: 240, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "collaborative", vipTrackDimensions: []),
                "client": RoleConfig(replyWindow: 120, notifyLevel: "standard", classifierStrictness: "high", replyTone: "professional", vipTrackDimensions: []),
                "friend": RoleConfig(replyWindow: 240, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "casual", vipTrackDimensions: []),
                "supplier": RoleConfig(replyWindow: 480, notifyLevel: "standard", classifierStrictness: "normal", replyTone: "collaborative", vipTrackDimensions: []),
                "acquaintance": RoleConfig(replyWindow: 0, notifyLevel: "light", classifierStrictness: "normal", replyTone: "polite", vipTrackDimensions: []),
                "group_only": RoleConfig(replyWindow: 0, notifyLevel: "light", classifierStrictness: "normal", replyTone: "polite", vipTrackDimensions: []),
                "service": RoleConfig(replyWindow: 0, notifyLevel: "none", classifierStrictness: "normal", replyTone: "polite", vipTrackDimensions: []),
            ]
            do {
                try setSettingJSON("role_configs", value: configs)
                print("[WCHUD] seeded settings.role_configs (first launch)")
            } catch {
                print("[WCHUD] failed to seed role_configs: \(error)")
            }
        }

        if getSetting("notification") == nil {
            try? setSettingJSON("notification", value: NotificationConfig())
            print("[WCHUD] seeded settings.notification (first launch)")
        }
    }

    /// Single read point for the unified AI config. Always returns a
    /// usable config (post-seed) or the empty struct defaults. The API
    /// key is hydrated from the secret store; SQLite only holds a ref.
    func loadAIConfig() -> AIConfig {
        var cfg = getSettingJSON("ai", as: AIConfig.self) ?? AIConfig()
        cfg.migrateIfNeeded()
        hydrateAPIKey(&cfg)
        return cfg
    }

    static let defaultAIKeyAccount = "ai.provider.apiKey"

    /// Two-phase commit: write+read-back the Keychain item, then persist
    /// `settings.ai` with an empty `apiKey` and a `keychainItemRef`.
    func persistAIConfig(_ config: AIConfig) throws {
        var persistable = config
        persistable.migrateIfNeeded()
        let plaintext = persistable.provider.apiKey
        let account = persistable.provider.keychainItemRef
            ?? Self.defaultAIKeyAccount

        if plaintext.isEmpty {
            persistable.provider.apiKey = ""
            // A persisted JSON round-trip (empty key + existing ref) must not
            // delete the Keychain item. A UI save with a blank key and no ref
            // is an explicit clear.
            if persistable.provider.keychainItemRef == nil {
                try? secretStore.delete(account: account)
            }
        } else {
            try secretStore.save(account: account, secret: plaintext)
            guard try secretStore.load(account: account) == plaintext else {
                throw SecretStoreError.readbackMismatch
            }
            persistable.provider.apiKey = ""
            persistable.provider.keychainItemRef = account
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(persistable)
        try setSetting("ai", value: String(data: data, encoding: .utf8)!)
    }

    /// One-shot upgrade for databases that still have a plaintext `apiKey`
    /// in `settings.ai`. Failure leaves the plaintext row in place so the
    /// user does not lose the key.
    @discardableResult
    func migratePlaintextAPIKeysToKeychain() -> Bool {
        guard var cfg = getSettingJSON("ai", as: AIConfig.self) else { return true }
        cfg.migrateIfNeeded()
        guard !cfg.provider.apiKey.isEmpty else { return true }
        do {
            try persistAIConfig(cfg)
            if let raw = getSetting("ai"), raw.contains(cfg.provider.apiKey) {
                return false
            }
            return true
        } catch {
            print("[HUDStore] API key Keychain migration deferred: \(error)")
            return false
        }
    }

    func persistedAIConfigJSON() -> String? {
        getSetting("ai")
    }

    private func hydrateAPIKey(_ cfg: inout AIConfig) {
        if !cfg.provider.apiKey.isEmpty { return }
        let account = cfg.provider.keychainItemRef ?? Self.defaultAIKeyAccount
        do {
            guard let secret = try secretStore.load(account: account), !secret.isEmpty else { return }
            cfg.provider.apiKey = secret
            cfg.provider.keychainItemRef = account
        } catch {
            return
        }
    }

    // MARK: - Contacts

    func upsertContact(
        username: String,
        displayName: String,
        attentionLevel: AttentionLevel,
        role: ContactRole,
        roleNote: String = "",
        replyWindowMinutes: Int = 120
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO contacts(
                username, display_name, attention_level, role, role_note,
                reply_window_minutes, level_changed_at, created_at, updated_at
            )
            VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(username) DO UPDATE SET
                display_name         = excluded.display_name,
                attention_level      = excluded.attention_level,
                role                 = excluded.role,
                role_note            = excluded.role_note,
                reply_window_minutes = excluded.reply_window_minutes,
                level_changed_at     = CASE
                    WHEN contacts.attention_level != excluded.attention_level
                    THEN excluded.level_changed_at
                    ELSE contacts.level_changed_at
                END,
                updated_at           = excluded.updated_at
        """, params: [
            username,
            displayName,
            attentionLevel.rawValue,
            role.rawValue,
            roleNote,
            "\(replyWindowMinutes)",
            "\(now)",
            "\(now)",
            "\(now)"
        ])
    }

    func getContact(username: String) -> ContactEntry? {
        queryOne("""
            SELECT username, display_name, attention_level, role, role_note,
                   reply_window_minutes, level_changed_at, created_at, updated_at
            FROM contacts
            WHERE username=?
            LIMIT 1
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, username, -1, Self.sqliteTransient)
        }, decode: { stmt in
            readContactRow(stmt)
        })
    }

    func loadContacts(level: AttentionLevel? = nil) -> [ContactEntry] {
        var sql = """
            SELECT username, display_name, attention_level, role, role_note,
                   reply_window_minutes, level_changed_at, created_at, updated_at
            FROM contacts
        """
        if level != nil {
            sql += " WHERE attention_level=?"
        }
        sql += " ORDER BY updated_at DESC"
        return queryAll(sql, bind: { stmt in
            if let level {
                sqlite3_bind_text(stmt, 1, level.rawValue, -1, Self.sqliteTransient)
            }
        }, decode: { stmt in
            readContactRow(stmt)
        })
    }

    func updateContactLevel(username: String, level: AttentionLevel, role: ContactRole) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE contacts SET attention_level=?, role=?, level_changed_at=?, updated_at=?
            WHERE username=?
        """, params: [level.rawValue, role.rawValue, "\(now)", "\(now)", username])
    }

    func deleteContact(username: String) throws {
        try exec("DELETE FROM contacts WHERE username=?", params: [username])
    }

    /// Product-facing contact save used by the contacts settings UI.
    ///
    /// `contacts` is the rich relationship/profile table while the scan engine
    /// still reads `whitelist`. Keep both in sync here so a level change in the
    /// UI immediately affects monitoring. Greylist/stranger keeps the contact
    /// profile but stops tracking; explicit deletion can use
    /// `deleteContactAndTracking`.
    func saveContactTracking(
        username: String,
        displayName: String,
        isGroup: Bool,
        category: WhitelistCategory,
        attentionLevel: AttentionLevel,
        role: ContactRole,
        roleNote: String = "",
        replyWindowMinutes: Int = 120
    ) throws {
        try withTransaction {
            try upsertContact(
                username: username,
                displayName: displayName,
                attentionLevel: attentionLevel,
                role: role,
                roleNote: roleNote,
                replyWindowMinutes: replyWindowMinutes
            )

            switch attentionLevel {
            case .vip, .whitelist:
                let whitelistLevel: WhitelistAttentionLevel = attentionLevel == .vip ? .vip : .watch
                try upsertWhitelistTracking(
                    username: username,
                    displayName: displayName,
                    isGroup: isGroup,
                    category: category,
                    attentionLevel: whitelistLevel
                )
            case .greylist, .stranger:
                try untrackContact(username: username)
            }
        }
    }

    /// Remove a contact from both product tables and scan-side state.
    ///
    /// Same scope as `removeFromWhitelist`: this is the 联系人 page's delete, and
    /// a contact removed from here must not keep firing 承诺到期 alerts for
    /// commitments the user can no longer reach.
    func deleteContactAndTracking(username: String) throws {
        try withTransaction {
            try untrackContact(username: username)
            try deleteContact(username: username)
            try clearDerivedArtifacts(chatUsername: username)
            try exec("DELETE FROM relationship_profiles WHERE username=?", params: [username])
        }
    }

    private func upsertWhitelistTracking(
        username: String,
        displayName: String,
        isGroup: Bool,
        category: WhitelistCategory,
        attentionLevel: WhitelistAttentionLevel
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO whitelist(
                username, display_name, is_group, category, attention_level, added_at, auto_suggested
            )
            VALUES(?,?,?,?,?,?,0)
            ON CONFLICT(username) DO UPDATE SET
                display_name    = excluded.display_name,
                is_group        = excluded.is_group,
                category        = excluded.category,
                attention_level = excluded.attention_level
        """, params: [
            username,
            displayName,
            isGroup ? "1" : "0",
            category.rawValue,
            attentionLevel.rawValue,
            "\(now)"
        ])
    }

    private func untrackContact(username: String) throws {
        try exec("DELETE FROM whitelist WHERE username=?", params: [username])
        // Also clear this chat's baseline — otherwise re-adding the
        // same contact to the whitelist later would reuse the stale
        // watermark and silently swallow every message that arrived
        // while it was off the list.
        try exec("DELETE FROM sync_state WHERE source_key=?", params: ["wl/\(username)"])
        // Drop any snooze/silence state too: "removed from whitelist"
        // is the strongest reset signal we have, and leaving those
        // behind would make a re-added chat come back already muted.
        try exec("DELETE FROM chat_actions WHERE chat_username=?", params: [username])
    }

    /// Derived artifacts die with an explicit untrack — otherwise a removed
    /// chat's pending commitments keep firing overdue alerts, its 待办 stay in
    /// the list, and its memory rows persist until the model overwrites them.
    ///
    /// Deliberately separate from `untrackContact`: moving a contact to
    /// 灰名单 is a level change that can be reversed, while deleting the
    /// follow is the confirmation the copy promises.
    private func clearDerivedArtifacts(chatUsername: String) throws {
        try exec(
            "UPDATE commitments SET status='cancelled' WHERE chat_username=? AND status IN ('pending','overdue')",
            params: [chatUsername])
        try exec(
            "UPDATE discussion_items SET status='dismissed' WHERE chat_username=? AND status='pending'",
            params: [chatUsername])
        try exec("DELETE FROM pending_asks WHERE chat_username=?", params: [chatUsername])
        // The discussion queue table is created on first use, so the raw
        // DELETE would fail on a database that never queued anything.
        try clearDiscussionMessages(chatUsername: chatUsername)
    }

    func loadVIPUsernames() -> Set<String> {
        Set(queryAll(
            "SELECT username FROM contacts WHERE attention_level='vip'",
            bind: { _ in },
            decode: { stmt in
                let name = Self.textColumn(stmt, 0)
                return name.isEmpty ? nil : name
            }
        ))
    }

    private func readContactRow(_ stmt: OpaquePointer?) -> ContactEntry {
        let levelChangedRaw = sqlite3_column_int64(stmt, 6)
        let levelChangedAt: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL || levelChangedRaw == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(levelChangedRaw))
        let roleStr = String(cString: sqlite3_column_text(stmt, 3))
        let username = String(cString: sqlite3_column_text(stmt, 0))
        return ContactEntry(
            id: username,
            username: username,
            displayName: String(cString: sqlite3_column_text(stmt, 1)),
            attentionLevel: AttentionLevel(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .stranger,
            role: ContactRole(rawValue: roleStr) ?? .acquaintance,
            roleNote: String(cString: sqlite3_column_text(stmt, 4)),
            replyWindowMinutes: Int(sqlite3_column_int64(stmt, 5)),
            levelChangedAt: levelChangedAt,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7))),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 8)))
        )
    }

    // MARK: - VIP Traces

    func insertVIPTrace(
        vipUsername: String,
        vipName: String,
        chatUsername: String,
        chatName: String,
        msgUID: String,
        rawText: String,
        msgTime: Int
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT OR IGNORE INTO vip_traces(
                vip_username, vip_name, chat_username, chat_name,
                msg_uid, raw_text, msg_time, created_at
            )
            VALUES(?,?,?,?,?,?,?,?)
        """, params: [
            vipUsername,
            vipName,
            chatUsername,
            chatName,
            msgUID,
            rawText,
            "\(msgTime)",
            "\(now)"
        ])
    }

    private func decodeVIPTrace(_ stmt: OpaquePointer?) -> VIPTrace? {
        guard let stmt else { return nil }
        let batchID: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil : Self.textColumn(stmt, 8)
        return VIPTrace(
            id: sqlite3_column_int64(stmt, 0),
            vipUsername: Self.textColumn(stmt, 1),
            vipName: Self.textColumn(stmt, 2),
            chatUsername: Self.textColumn(stmt, 3),
            chatName: Self.textColumn(stmt, 4),
            msgUID: Self.textColumn(stmt, 5),
            rawText: Self.textColumn(stmt, 6),
            msgTime: Int(sqlite3_column_int64(stmt, 7)),
            batchID: (batchID?.isEmpty == true) ? nil : batchID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 9)))
        )
    }

    func loadVIPTraces(vipUsername: String, since: Int = 0, limit: Int = 100) -> [VIPTrace] {
        queryAll("""
            SELECT id, vip_username, vip_name, chat_username, chat_name,
                   msg_uid, raw_text, msg_time, batch_id, created_at
            FROM vip_traces
            WHERE vip_username=? AND msg_time >= ?
            ORDER BY msg_time DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, vipUsername, -1, Self.sqliteTransient)
            sqlite3_bind_int64(stmt, 2, Int64(since))
            sqlite3_bind_int64(stmt, 3, Int64(limit))
        }, decode: decodeVIPTrace)
    }

    func loadUnbatchedVIPTraces(vipUsername: String, limit: Int = 50) -> [VIPTrace] {
        queryAll("""
            SELECT id, vip_username, vip_name, chat_username, chat_name,
                   msg_uid, raw_text, msg_time, batch_id, created_at
            FROM vip_traces
            WHERE vip_username=? AND batch_id IS NULL
            ORDER BY msg_time ASC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, vipUsername, -1, Self.sqliteTransient)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }, decode: decodeVIPTrace)
    }

    func markVIPTracesBatched(ids: [Int64], batchID: String) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var params = [batchID]
        params.append(contentsOf: ids.map { "\($0)" })
        try exec("""
            UPDATE vip_traces SET batch_id=? WHERE id IN (\(placeholders))
        """, params: params)
    }

    // MARK: - Recalled Messages

    /// A recalled message's derived artifacts must die with it — otherwise a
    /// withdrawn "我明天把合同发你" stays a live commitment forever, and a
    /// recalled ask keeps anchoring discussion items. Tombstone by the
    /// ORIGINAL message's uid (not the recall row's).
    /// The withdrawn message's derived artifacts die with it, all three at
    /// once: the scan watermark moves past the revokemsg row whether or not
    /// this succeeded, so a cascade that half-applied would never be retried
    /// and the withdrawn commitment would keep nagging forever.
    func tombstoneForRecall(originalMsgUID: String) throws {
        // An empty uid would match every malformed row ever written —
        // the cascade must no-op on it, not wipe the boards.
        guard !originalMsgUID.isEmpty else { return }
        try withTransaction {
            try exec(
                "UPDATE commitments SET status='cancelled' WHERE msg_uid=? AND status IN ('pending','overdue')",
                params: [originalMsgUID])
            try exec(
                "UPDATE discussion_items SET status='dismissed' WHERE anchor_msg_uid=? AND status='pending'",
                params: [originalMsgUID])
            try exec("DELETE FROM pending_asks WHERE msg_uid=?", params: [originalMsgUID])
        }
    }

    func insertRecalledMessage(
        msgUID: String,
        senderUsername: String,
        senderName: String,
        senderLevel: AttentionLevel,
        senderRole: ContactRole,
        chatUsername: String,
        chatName: String,
        chatType: ChatType,
        originalText: String,
        sentAt: Int,
        recalledAt: Int
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        let delay = recalledAt - sentAt
        try exec("""
            INSERT OR IGNORE INTO recalled_messages(
                msg_uid, sender_username, sender_name, sender_level, sender_role,
                chat_username, chat_name, chat_type, original_text,
                sent_at, recalled_at, recall_delay_seconds, created_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, params: [
            msgUID,
            senderUsername,
            senderName,
            senderLevel.rawValue,
            senderRole.rawValue,
            chatUsername,
            chatName,
            chatType.rawValue,
            originalText,
            "\(sentAt)",
            "\(recalledAt)",
            "\(delay)",
            "\(now)"
        ])
    }

    func loadRecalledMessages(since: Int = 0, limit: Int = 100) -> [RecalledMessage] {
        queryAll("""
            SELECT id, msg_uid, sender_username, sender_name, sender_level, sender_role,
                   chat_username, chat_name, chat_type, original_text,
                   sent_at, recalled_at, recall_delay_seconds,
                   ai_reason, ai_intelligence_value, ai_detail,
                   ai_should_notify, ai_notify_level, ai_analyzed_at,
                   ai_attempts, created_at
            FROM recalled_messages
            WHERE recalled_at >= ?
            ORDER BY recalled_at DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(since))
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }, decode: { stmt in
            let aiReason: String? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Self.textColumn(stmt, 13)
            let aiValue: String? = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : Self.textColumn(stmt, 14)
            let aiDetail: String? = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : Self.textColumn(stmt, 15)
            let aiShouldNotify: Bool? = sqlite3_column_type(stmt, 16) == SQLITE_NULL
                ? nil : sqlite3_column_int(stmt, 16) != 0
            let aiNotifyStr: String? = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : Self.textColumn(stmt, 17)
            let aiAnalyzedRaw = sqlite3_column_int64(stmt, 18)
            let aiAnalyzedAt: Date? = sqlite3_column_type(stmt, 18) == SQLITE_NULL || aiAnalyzedRaw == 0
                ? nil : Date(timeIntervalSince1970: TimeInterval(aiAnalyzedRaw))
            return RecalledMessage(
                id: sqlite3_column_int64(stmt, 0),
                msgUID: Self.textColumn(stmt, 1),
                senderUsername: Self.textColumn(stmt, 2),
                senderName: Self.textColumn(stmt, 3),
                senderLevel: AttentionLevel(rawValue: Self.textColumn(stmt, 4)) ?? .stranger,
                senderRole: ContactRole(rawValue: Self.textColumn(stmt, 5)) ?? .acquaintance,
                chatUsername: Self.textColumn(stmt, 6),
                chatName: Self.textColumn(stmt, 7),
                chatType: ChatType(rawValue: Self.textColumn(stmt, 8)) ?? .privateChat,
                originalText: Self.textColumn(stmt, 9),
                sentAt: Int(sqlite3_column_int64(stmt, 10)),
                recalledAt: Int(sqlite3_column_int64(stmt, 11)),
                recallDelaySeconds: Int(sqlite3_column_int64(stmt, 12)),
                aiReason: (aiReason?.isEmpty == true) ? nil : aiReason,
                aiIntelligenceValue: (aiValue?.isEmpty == true) ? nil : aiValue,
                aiDetail: (aiDetail?.isEmpty == true) ? nil : aiDetail,
                aiShouldNotify: aiShouldNotify,
                aiNotifyLevel: aiNotifyStr.flatMap { NotifyLevel(rawValue: $0) },
                aiAnalyzedAt: aiAnalyzedAt,
                aiAttempts: Int(sqlite3_column_int64(stmt, 19)),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 20)))
            )
        })
    }

    /// Bump the attempts counter on every analysis pass — success or
    /// failure. A permanently-failing analyzer must not get an unbounded
    /// retry loop on every scan.
    func markRecallAnalysisAttempted(msgUID: String) throws {
        try exec(
            "UPDATE recalled_messages SET ai_attempts = ai_attempts + 1 WHERE msg_uid=?",
            params: [msgUID]
        )
    }

    func updateRecallAnalysis(
        msgUID: String,
        reason: String,
        value: String,
        detail: String,
        shouldNotify: Bool,
        notifyLevel: NotifyLevel
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE recalled_messages SET
                ai_reason=?, ai_intelligence_value=?, ai_detail=?,
                ai_should_notify=?, ai_notify_level=?, ai_analyzed_at=?
            WHERE msg_uid=?
        """, params: [
            reason,
            value,
            detail,
            shouldNotify ? "1" : "0",
            notifyLevel.rawValue,
            "\(now)",
            msgUID
        ])
    }

    // MARK: - Commitments

    func upsertCommitment(
        msgUID: String,
        chatUsername: String,
        chatName: String,
        content: String,
        commitTo: String,
        deadlineAt: Date? = nil,
        confidence: Double,
        promptVersion: String,
        sourceText: String = "",
        contextText: String = "",
        captureReason: String = "",
        nextStep: String = "",
        deadlineLabel: String = "",
        commitmentKind: String = "",
        createdAt: Date = Date()
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        let created = Int(createdAt.timeIntervalSince1970)
        // Same TEXT-in-INTEGER trap as pending_asks: nil binds NULL, and
        // COALESCE preserves a stored deadline when a re-extraction omits it.
        let deadlineStr: String? = deadlineAt.map { String(Int($0.timeIntervalSince1970)) }
        try exec("""
            INSERT INTO commitments(
                msg_uid, chat_username, chat_name, content, commit_to,
                deadline_at, confidence, status, prompt_version,
                source_text, context_text, capture_reason, next_step,
                deadline_label, commitment_kind,
                created_at, updated_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(msg_uid) DO UPDATE SET
                content        = excluded.content,
                commit_to      = excluded.commit_to,
                deadline_at    = COALESCE(excluded.deadline_at, commitments.deadline_at),
                confidence     = excluded.confidence,
                prompt_version = excluded.prompt_version,
                source_text    = excluded.source_text,
                context_text   = excluded.context_text,
                capture_reason = excluded.capture_reason,
                next_step      = excluded.next_step,
                deadline_label = excluded.deadline_label,
                commitment_kind = excluded.commitment_kind,
                updated_at     = excluded.updated_at
        """, params: [
            msgUID,
            chatUsername,
            chatName,
            content,
            commitTo,
            deadlineStr,
            String(confidence),
            CommitmentStatus.pending.rawValue,
            promptVersion,
            sourceText,
            contextText,
            captureReason,
            nextStep,
            deadlineLabel,
            commitmentKind,
            "\(created)",
            "\(now)"
        ])
    }

    func loadCommitments(status: CommitmentStatus? = nil, relevantSince: Int? = nil) -> [Commitment] {
        var results: [Commitment] = []
        var sql = """
            SELECT id, msg_uid, chat_username, chat_name, content, commit_to,
                   deadline_at, confidence, status, prompt_version,
                   created_at, updated_at, source_text, context_text,
                   capture_reason, next_step, deadline_label, commitment_kind
            FROM commitments
        """
        var clauses: [String] = []
        var params: [String] = []
        if let status = status {
            clauses.append("status=?")
            params.append(status.rawValue)
        }
        if let relevantSince {
            // Pending/overdue alone no longer admits a row — the live window
            // is purely age-based so phantom commitments age out.
            clauses.append(Self.commitmentRelevantSinceClause)
            params.append("\(relevantSince)")
            params.append("\(relevantSince)")
            params.append("\(relevantSince)")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY COALESCE(deadline_at, 9999999999) ASC"
        // Routed through the shared statement cache: this query runs on every
        // live-workspace refresh and the string is built from a fixed clause
        // set, so the cache sees at most four variants and reuses each one.
        try? withCachedStatement(sql, params: params) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let deadlineRaw = sqlite3_column_int64(stmt, 6)
                let deadline: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL || deadlineRaw == 0
                    ? nil
                    : Date(timeIntervalSince1970: TimeInterval(deadlineRaw))
                results.append(Commitment(
                    id: sqlite3_column_int64(stmt, 0),
                    msgUID: String(cString: sqlite3_column_text(stmt, 1)),
                    chatUsername: String(cString: sqlite3_column_text(stmt, 2)),
                    chatName: String(cString: sqlite3_column_text(stmt, 3)),
                    content: String(cString: sqlite3_column_text(stmt, 4)),
                    commitTo: String(cString: sqlite3_column_text(stmt, 5)),
                    deadlineAt: deadline,
                    confidence: sqlite3_column_double(stmt, 7),
                    status: CommitmentStatus(rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .pending,
                    promptVersion: String(cString: sqlite3_column_text(stmt, 9)),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 10))),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 11))),
                    sourceText: Self.textColumn(stmt, 12),
                    contextText: Self.textColumn(stmt, 13),
                    captureReason: Self.textColumn(stmt, 14),
                    nextStep: Self.textColumn(stmt, 15),
                    deadlineLabel: Self.textColumn(stmt, 16),
                    commitmentKind: Self.textColumn(stmt, 17)
                ))
            }
        }
        if let relevantSince {
            return results.filter { DiscussionLiveWindow.contains($0, cutoff: relevantSince) }
        }
        return results
    }

    func updateCommitmentStatus(msgUID: String, status: CommitmentStatus) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE commitments SET status=?, updated_at=? WHERE msg_uid=?
        """, params: [status.rawValue, "\(now)", msgUID])
    }

    /// Conditionally flip a commitment's status. Auto-overdue only touches
    /// `.pending`; auto-fulfilled may also recover `.overdue` commitments
    /// when the user completes them late. Manual `.cancelled/.fulfilled`
    /// rows are never clobbered.
    func autoAdvanceCommitmentStatus(msgUID: String, to newStatus: CommitmentStatus) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE commitments SET status=?, updated_at=?
            WHERE msg_uid=? AND (
                status=?
                OR (?=? AND status=?)
            )
        """, params: [
            newStatus.rawValue, "\(now)",
            msgUID,
            CommitmentStatus.pending.rawValue,
            newStatus.rawValue, CommitmentStatus.fulfilled.rawValue, CommitmentStatus.overdue.rawValue
        ])
    }

    // MARK: - Discussion Items

    /// Insert a discussion item, ignoring duplicates by the
    /// `(chat_username, anchor_msg_uid, content)` uniqueness
    /// constraint. Returns true if a new row was actually inserted.
    @discardableResult
    func insertDiscussionItem(
        chatUsername: String,
        chatName: String,
        kind: DiscussionItemKind,
        owner: DiscussionItemOwner,
        content: String,
        detail: String?,
        anchorMsgUID: String,
        sourceTimestamp: Int,
        dueAt: Date?,
        confidence: Double,
        promptVersion: String
    ) throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        // Store a real NULL when there is no deadline. This used to write an
        // empty string, which SQLite cannot convert under the column's INTEGER
        // affinity and therefore keeps as TEXT — and every TEXT value sorts
        // *after* every number, so `due_at > 0` matched every row while
        // `due_at IS NULL` matched none. Any "is this dated?" check silently
        // read as yes. Passing nil binds NULL.
        let dueValue: String? = dueAt.map { String(Int($0.timeIntervalSince1970)) }
        return try execReturningChanges("""
            INSERT OR IGNORE INTO discussion_items(
                chat_username, chat_name, kind, owner, content, detail,
                anchor_msg_uid, source_timestamp, due_at, status,
                confidence, prompt_version, created_at, updated_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, params: [
            chatUsername, chatName, kind.rawValue, owner.rawValue,
            content, detail ?? "",
            anchorMsgUID, "\(sourceTimestamp)", dueValue,
            DiscussionItemStatus.pending.rawValue,
            String(confidence), promptVersion,
            "\(now)", "\(now)"
        ]) > 0
    }

    /// Load discussion items with optional filters.
    /// - Parameters:
    ///   - chatUsername: if set, only items from that chat
    ///   - status: if set, only items in that status (default shows all)
    ///   - excludingStatus: if set, drop that status (used for history)
    ///   - id: if set, only that row
    ///   - sinceTimestamp: if set, only items with `source_timestamp >= this`
    ///   - relevantSince: if set, keep rows whose source or due date is on/after this;
    ///     completed/archived rows also stay if they were updated on/after this
    ///   - limit: cap results (nil = no cap)
    func loadDiscussionItems(
        chatUsername: String? = nil,
        status: DiscussionItemStatus? = nil,
        excludingStatus: DiscussionItemStatus? = nil,
        id: Int64? = nil,
        sinceTimestamp: Int? = nil,
        relevantSince: Int? = nil,
        limit: Int? = nil
    ) -> [DiscussionItem] {
        var results: [DiscussionItem] = []

        var sql = """
            SELECT id, chat_username, chat_name, kind, owner, content, detail,
                   anchor_msg_uid, source_timestamp, due_at, status,
                   confidence, prompt_version, created_at, updated_at
            FROM discussion_items
        """
        var clauses: [String] = []
        var params: [String] = []
        if let chatUsername = chatUsername {
            clauses.append("chat_username=?")
            params.append(chatUsername)
        }
        if let status = status {
            clauses.append("status=?")
            params.append(status.rawValue)
        }
        if let excludingStatus {
            clauses.append("status!=?")
            params.append(excludingStatus.rawValue)
        }
        if let id {
            clauses.append("id=?")
            params.append("\(id)")
        }
        if let since = sinceTimestamp {
            clauses.append("source_timestamp >= ?")
            params.append("\(since)")
        }
        if let relevantSince {
            // Bind in the exact order the clause lists its placeholders:
            // source_timestamp, due_at, (status, created_at), (status, updated_at).
            // `created_at` must be here: an item extracted just now from an old
            // source message is still fresh to the user, and the Swift recheck
            // in DiscussionLiveWindow.contains keeps it for that reason. When SQL
            // drops the row first the recheck never sees it — which is what
            // making empty `due_at` compare correctly exposed.
            clauses.append(Self.discussionRelevantSinceClause)
            params.append("\(relevantSince)")
            params.append("\(relevantSince)")
            params.append(DiscussionItemStatus.pending.rawValue)
            params.append("\(relevantSince)")
            params.append(DiscussionItemStatus.pending.rawValue)
            params.append("\(relevantSince)")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY source_timestamp DESC"
        if let limit = limit { sql += " LIMIT \(limit)" }

        // Same clause set on every refresh, so the cache sees a handful of
        // distinct SQL strings and compiles each one only once.
        try? withCachedStatement(sql, params: params) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let detailRaw = String(cString: sqlite3_column_text(stmt, 6))
                let dueRaw = sqlite3_column_int64(stmt, 9)
                let due: Date? = sqlite3_column_type(stmt, 9) == SQLITE_NULL || dueRaw == 0
                    ? nil
                    : Date(timeIntervalSince1970: TimeInterval(dueRaw))
                results.append(DiscussionItem(
                    id: sqlite3_column_int64(stmt, 0),
                    chatUsername: String(cString: sqlite3_column_text(stmt, 1)),
                    chatName: String(cString: sqlite3_column_text(stmt, 2)),
                    kind: DiscussionItemKind(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .todo,
                    owner: DiscussionItemOwner(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .shared,
                    content: String(cString: sqlite3_column_text(stmt, 5)),
                    detail: detailRaw.isEmpty ? nil : detailRaw,
                    anchorMsgUID: String(cString: sqlite3_column_text(stmt, 7)),
                    sourceTimestamp: Int(sqlite3_column_int64(stmt, 8)),
                    dueAt: due,
                    status: DiscussionItemStatus(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .pending,
                    confidence: sqlite3_column_double(stmt, 11),
                    promptVersion: String(cString: sqlite3_column_text(stmt, 12)),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 13))),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 14)))
                ))
            }
        }
        if let relevantSince {
            return results.filter { DiscussionLiveWindow.contains($0, cutoff: relevantSince) }
        }
        return results
    }

    func loadDiscussionItem(id: Int64) -> DiscussionItem? {
        loadDiscussionItems(id: id, limit: 1).first
    }

    /// Fold stale pending rows into `archived` so they leave the live HUD/workspace
    /// list but remain reachable from history for 14 days via `updated_at`.
    /// A pending row is stale when both its source message and its due date (if any)
    /// are older than `cutoff` — AND the row itself is old. An item extracted
    /// today from a weeks-old message (e.g. a queue drained after a long
    /// absence) must stay visible; archiving by source alone would sweep it
    /// before the user ever sees it.
    @discardableResult
    func archiveStalePendingDiscussionItems(cutoff: Int, now: Date = Date()) throws -> Int {
        let ts = String(Int(now.timeIntervalSince1970))
        return try execReturningChanges("""
            UPDATE discussion_items
            SET status=?, updated_at=?
            WHERE status=?
              AND CAST(source_timestamp AS INTEGER) < ?
              AND CAST(created_at AS INTEGER) < ?
              AND (
                    due_at IS NULL
                    OR CAST(IFNULL(due_at, 0) AS INTEGER) <= 0
                    OR CAST(due_at AS INTEGER) < ?
                  )
        """, params: [
            DiscussionItemStatus.archived.rawValue,
            ts,
            DiscussionItemStatus.pending.rawValue,
            "\(cutoff)",
            "\(cutoff)",
            "\(cutoff)"
        ])
    }

    /// Pending/overdue commitments never age out — a stale or phantom row
    /// re-fires overdue alerts on a 24h cooldown forever. Bound them like the
    /// discussion sweeps (the overdue ones get a longer 30-day window).
    @discardableResult
    func archiveStalePendingCommitments(cutoff: Int, now: Date = Date()) throws -> Int {
        let ts = String(Int(now.timeIntervalSince1970))
        return try execReturningChanges("""
            UPDATE commitments
            SET status='cancelled', updated_at=?
            WHERE status IN ('pending','overdue')
              AND CAST(created_at AS INTEGER) < ?
              AND CAST(updated_at AS INTEGER) < ?
              AND (deadline_at IS NULL OR CAST(deadline_at AS INTEGER) < ?)
        """, params: [ts, "\(cutoff)", "\(cutoff)", "\(cutoff)"])
    }

    /// Stale classifier asks use the same 14-day source/due window as discussion.
    @discardableResult
    func archiveStalePendingAsks(cutoff: Int, now: Date = Date()) throws -> Int {
        let ts = String(Int(now.timeIntervalSince1970))
        return try execReturningChanges("""
            UPDATE pending_asks
            SET status=?, updated_at=?
            WHERE status=?
              AND CAST(created_at AS INTEGER) < ?
              AND (
                    deadline_at IS NULL
                    OR TRIM(CAST(deadline_at AS TEXT)) = ''
                    OR CAST(IFNULL(deadline_at, 0) AS INTEGER) <= 0
                    OR CAST(deadline_at AS INTEGER) < ?
                  )
        """, params: [
            AskStatus.dismissed.rawValue,
            ts,
            AskStatus.pending.rawValue,
            "\(cutoff)",
            "\(cutoff)"
        ])
    }

    func updateDiscussionItemStatus(id: Int64, status: DiscussionItemStatus) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE discussion_items SET status=?, updated_at=? WHERE id=?
        """, params: [status.rawValue, "\(now)", "\(id)"])
    }

    /// Completing/cancelling a commitment closes the extracted todo with the same source message.
    @discardableResult
    func updatePendingDiscussionItems(matchingAnchorMsgUID uid: String, status: DiscussionItemStatus) throws -> Int {
        let now = Int(Date().timeIntervalSince1970)
        return try execReturningChanges(
            "UPDATE discussion_items SET status=?, updated_at=? WHERE anchor_msg_uid=? AND status=?",
            params: [status.rawValue, "\(now)", uid, DiscussionItemStatus.pending.rawValue]
        )
    }

    /// Corrects AI-assigned responsibility without changing the item's status.
    /// Returns false when the row no longer exists.
    @discardableResult
    func updateDiscussionItemOwner(id: Int64, owner: DiscussionItemOwner) throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        return try execReturningChanges("""
            UPDATE discussion_items SET owner=?, updated_at=? WHERE id=?
        """, params: [owner.rawValue, "\(now)", "\(id)"]) > 0
    }

    /// Repairs inverted inquiry rows: kind, owner, and cleaned content together.
    @discardableResult
    func repairDiscussionItemDirection(
        id: Int64,
        kind: DiscussionItemKind,
        owner: DiscussionItemOwner,
        content: String
    ) throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        return try execReturningChanges("""
            UPDATE discussion_items SET kind=?, owner=?, content=?, updated_at=? WHERE id=?
        """, params: [kind.rawValue, owner.rawValue, content, "\(now)", "\(id)"]) > 0
    }

    /// Corrects content, owner, and deadline without touching WeChat source text.
    @discardableResult
    func updateDiscussionItemCorrection(
        id: Int64,
        content: String,
        owner: DiscussionItemOwner,
        dueAt: Date?
    ) throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        // Cleared deadlines must become NULL for the same reason the insert
        // path does: an empty string stores as TEXT, which outranks every
        // number and makes "has a deadline" read as true forever.
        let dueValue: String? = dueAt.map { String(Int($0.timeIntervalSince1970)) }
        return try execReturningChanges("""
            UPDATE discussion_items SET content=?, owner=?, due_at=?, updated_at=? WHERE id=?
        """, params: [content, owner.rawValue, dueValue, "\(now)", "\(id)"]) > 0
    }

    /// The most recent `source_timestamp` extracted for a chat — used
    /// by the tracker to skip messages it already analysed.
    func latestDiscussionSourceTimestamp(chatUsername: String) -> Int {
        queryOne(
            "SELECT MAX(source_timestamp) FROM discussion_items WHERE chat_username=?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, chatUsername, -1, Self.sqliteTransient)
            },
            decode: { stmt in Int(sqlite3_column_int64(stmt, 0)) }
        ) ?? 0
    }

    // MARK: - Reply Drafts

    func saveDraft(chatUsername: String, chatName: String, text: String, sendAt: Date?) throws {
        let now = Int(Date().timeIntervalSince1970)
        let sendAtTs = sendAt.map { Int($0.timeIntervalSince1970) } ?? 0
        try exec("""
            INSERT INTO reply_drafts(chat_username, chat_name, text, send_at, created_at)
            VALUES(?,?,?,?,?)
        """, params: [chatUsername, chatName, text, String(sendAtTs), String(now)])
    }

    func draftCount() -> Int {
        scalarCount("SELECT COUNT(*) FROM reply_drafts")
    }

    /// Saved drafts plus in-progress composer text that is not already a saved row.
    func workspaceDraftCount() -> Int {
        // This used to be loadWorkspaceDrafts().count, which materialised
        // every saved row into a struct, then resolved a display name for
        // every composer draft (a whitelist lookup plus a contacts lookup
        // each) — and threw all of it away for a cardinality check.
        //
        // Parity with loadWorkspaceDrafts is exact:
        //   count = (every saved row, duplicates included)
        //         + (composer drafts whose (chat, text) pair matches no saved
        //            row of the same chat)
        // The saved side is now a pure COUNT(*) — the same table, no WHERE,
        // so it counts exactly the rows loadDrafts() would have returned.
        // The name resolution on the composer side was never observable
        // here because the result is a count, so it is skipped.
        let savedCount = scalarCount("SELECT COUNT(*) FROM reply_drafts")
        var savedTextsByChat: [String: Set<String>] = [:]
        for row in loadDraftTextIdentities() {
            savedTextsByChat[row.chatUsername, default: []].insert(row.text)
        }
        var composerOnly = 0
        for composer in loadComposerDrafts()
        where savedTextsByChat[composer.chatUsername]?.contains(composer.text) != true {
            composerOnly += 1
        }
        return savedCount + composerOnly
    }

    /// Minimal projection used by the draft badge: the (chat, text) pairs
    /// needed to dedupe composer drafts, without decoding names/timestamps
    /// into WorkspaceDraft values.
    private func loadDraftTextIdentities() -> [(chatUsername: String, text: String)] {
        var rows: [(chatUsername: String, text: String)] = []
        try? withCachedStatement("SELECT chat_username, text FROM reply_drafts") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((
                    chatUsername: String(cString: sqlite3_column_text(stmt, 0)),
                    text: String(cString: sqlite3_column_text(stmt, 1))
                ))
            }
        }
        return rows
    }

    /// Single-value COUNT helper that matches the existing scalar-read
    /// convention (0 when the statement cannot be prepared or stepped).
    private func scalarCount(_ sql: String) -> Int {
        var value = 0
        try? withCachedStatement(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return value
    }

    struct WorkspaceDraft: Equatable {
        let id: Int64
        let chatUsername: String
        let chatName: String
        let text: String
        let createdAt: Date
        let isComposerOnly: Bool
    }

    func loadWorkspaceDrafts() -> [WorkspaceDraft] {
        let saved = loadDrafts()
        var result = saved.map {
            WorkspaceDraft(
                id: $0.id,
                chatUsername: $0.chatUsername,
                chatName: $0.chatName,
                text: $0.text,
                createdAt: $0.createdAt,
                isComposerOnly: false
            )
        }
        // Multiple saved rows can share a chat. Never use uniqueKeysWithValues
        // here: duplicate keys trap, and the drafts page would fail to open.
        var savedTextsByChat: [String: Set<String>] = [:]
        for row in saved {
            savedTextsByChat[row.chatUsername, default: []].insert(row.text)
        }
        for composer in loadComposerDrafts() {
            if savedTextsByChat[composer.chatUsername]?.contains(composer.text) == true { continue }
            let name = getWhitelistEntry(username: composer.chatUsername)?.displayName
                ?? getContact(username: composer.chatUsername)?.displayName
                ?? composer.chatUsername
            result.insert(
                WorkspaceDraft(
                    id: Self.composerDraftID(composer.chatUsername),
                    chatUsername: composer.chatUsername,
                    chatName: name,
                    text: composer.text,
                    createdAt: Date(),
                    isComposerOnly: true
                ),
                at: 0
            )
        }
        return result
    }

    func loadComposerDrafts() -> [(chatUsername: String, text: String)] {
        queryAll(
            "SELECT key, value FROM settings WHERE key LIKE 'composer_draft:%'",
            bind: { _ in },
            decode: { stmt in
                let key = Self.textColumn(stmt, 0)
                let value = Self.textColumn(stmt, 1)
                let username = String(key.dropFirst("composer_draft:".count))
                guard !username.isEmpty,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (username, value)
            }
        )
    }

    func clearComposerDraft(chatUsername: String) throws {
        try setSetting("composer_draft:\(chatUsername)", value: "")
    }

    static func composerDraftID(_ chatUsername: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in chatUsername.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int64(bitPattern: hash | (1 << 63))
    }

    func loadDrafts() -> [(id: Int64, chatUsername: String, chatName: String, text: String, sendAt: Date?, createdAt: Date)] {
        queryAll("""
            SELECT id, chat_username, chat_name, text, send_at, created_at
            FROM reply_drafts ORDER BY created_at DESC
        """, bind: { _ in }, decode: { stmt in
            let sendAtTs = sqlite3_column_int64(stmt, 4)
            return (
                id: sqlite3_column_int64(stmt, 0),
                chatUsername: Self.textColumn(stmt, 1),
                chatName: Self.textColumn(stmt, 2),
                text: Self.textColumn(stmt, 3),
                sendAt: sendAtTs > 0 ? Date(timeIntervalSince1970: Double(sendAtTs)) : nil,
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)))
            )
        })
    }

    func updateDraft(id: Int64, text: String) throws {
        try exec("UPDATE reply_drafts SET text=? WHERE id=?", params: [text, String(id)])
    }

    /// Update a continuation only when its saved row still belongs to the
    /// same chat. This prevents a stale continuation from mutating another
    /// conversation after a row was deleted/recreated.
    func updateDraft(id: Int64, chatUsername: String, text: String) throws {
        try withTransaction {
            // Keep the UPDATE and sqlite3_changes check on the same locked
            // connection so a deleted/stale row cannot be mistaken for a
            // successful save (and SQL failures remain sqlError).
            try exec(
                "UPDATE reply_drafts SET text=? WHERE id=? AND chat_username=?",
                params: [text, String(id), chatUsername]
            )
            guard sqlite3_changes(db) == 1 else {
                throw HUDStoreError.draftNotFound(id: id, chatUsername: chatUsername)
            }
        }
    }

    func deleteDraft(id: Int64) throws {
        try exec("DELETE FROM reply_drafts WHERE id=?", params: [String(id)])
    }

    // MARK: - Conversation Memory

    func upsertConversationMemory(_ memory: ConversationMemory) throws {
        let now = Int(Date().timeIntervalSince1970)
        let topicsJSON = (try? JSONSerialization.data(withJSONObject: memory.keyTopics))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let pendingJSON = (try? JSONSerialization.data(withJSONObject: memory.pendingItems))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sharedJSON = (try? JSONSerialization.data(withJSONObject: memory.sharedContext))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let commJSON = (try? JSONSerialization.data(withJSONObject: memory.communicationNotes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try exec("""
            INSERT INTO conversation_memory(chat_username, summary, key_topics, pending_items, shared_context, communication_notes, mood_trend, conversation_phase, stance, message_count_7d, last_updated)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(chat_username) DO UPDATE SET
                summary = excluded.summary,
                key_topics = excluded.key_topics,
                pending_items = excluded.pending_items,
                shared_context = excluded.shared_context,
                communication_notes = excluded.communication_notes,
                mood_trend = excluded.mood_trend,
                conversation_phase = excluded.conversation_phase,
                stance = excluded.stance,
                message_count_7d = excluded.message_count_7d,
                last_updated = excluded.last_updated
        """, params: [
            memory.chatUsername,
            memory.summary,
            topicsJSON,
            pendingJSON,
            sharedJSON,
            commJSON,
            memory.moodTrend,
            memory.conversationPhase,
            memory.stance,
            String(memory.messageCount7d),
            String(now)
        ])
    }

    func loadConversationMemory(chatUsername: String) -> ConversationMemory? {
        queryOne("""
            SELECT chat_username, summary, key_topics, pending_items, shared_context, communication_notes, mood_trend, conversation_phase, stance, message_count_7d, last_updated
            FROM conversation_memory WHERE chat_username=?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, Self.sqliteTransient)
        }, decode: { stmt in
            let topicsStr = Self.textColumn(stmt, 2)
            let pendingStr = Self.textColumn(stmt, 3)
            let sharedStr = Self.textColumn(stmt, 4)
            let commStr = Self.textColumn(stmt, 5)
            let topics = (try? JSONSerialization.jsonObject(with: Data(topicsStr.utf8)) as? [String]) ?? []
            let pending = (try? JSONSerialization.jsonObject(with: Data(pendingStr.utf8)) as? [String]) ?? []
            let shared = (try? JSONSerialization.jsonObject(with: Data(sharedStr.utf8)) as? [String]) ?? []
            let comm = (try? JSONSerialization.jsonObject(with: Data(commStr.utf8)) as? [String]) ?? []
            let phase = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Self.textColumn(stmt, 7) : ""
            let stanceVal = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Self.textColumn(stmt, 8) : ""
            return ConversationMemory(
                chatUsername: Self.textColumn(stmt, 0),
                summary: Self.textColumn(stmt, 1),
                keyTopics: topics,
                pendingItems: pending,
                sharedContext: shared,
                communicationNotes: comm,
                moodTrend: Self.textColumn(stmt, 6),
                conversationPhase: phase,
                stance: stanceVal,
                messageCount7d: Int(sqlite3_column_int(stmt, 9)),
                lastUpdated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10)))
            )
        })
    }

    // MARK: - Reply Timing Profiles

    func upsertReplyTimingProfile(_ profile: ReplyTimingProfile) throws {
        let now = Int(Date().timeIntervalSince1970)
        let encode: (ReplyTimingProfile.DelayDistribution) -> String = { dist in
            (try? JSONEncoder().encode(dist)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        try exec("""
            INSERT INTO reply_timing_profiles(chat_username, work_hours, evening, weekend, late_night, silent_at_night, sample_count, last_updated)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(chat_username) DO UPDATE SET
                work_hours = excluded.work_hours,
                evening = excluded.evening,
                weekend = excluded.weekend,
                late_night = excluded.late_night,
                silent_at_night = excluded.silent_at_night,
                sample_count = excluded.sample_count,
                last_updated = excluded.last_updated
        """, params: [
            profile.chatUsername,
            encode(profile.workHours),
            encode(profile.evening),
            encode(profile.weekend),
            encode(profile.lateNight),
            profile.silentAtNight ? "1" : "0",
            String(profile.sampleCount),
            String(now)
        ])
    }

    func loadReplyTimingProfile(chatUsername: String) -> ReplyTimingProfile? {
        queryOne("""
            SELECT chat_username, work_hours, evening, weekend, late_night, silent_at_night, sample_count, last_updated
            FROM reply_timing_profiles WHERE chat_username=?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, Self.sqliteTransient)
        }, decode: { stmt in
            let decodeDist: (Int32) -> ReplyTimingProfile.DelayDistribution = { col in
                let str = Self.textColumn(stmt, col)
                return (try? JSONDecoder().decode(ReplyTimingProfile.DelayDistribution.self, from: Data(str.utf8)))
                    ?? .zero
            }
            let isSilent = sqlite3_column_int(stmt, 5) != 0
            return ReplyTimingProfile(
                chatUsername: Self.textColumn(stmt, 0),
                workHours: decodeDist(1),
                evening: decodeDist(2),
                weekend: decodeDist(3),
                lateNight: decodeDist(4),
                silentAtNight: isSilent,
                lateNightReplyRate: isSilent ? 0.0 : 1.0,
                sampleCount: Int(sqlite3_column_int(stmt, 6)),
                lastUpdated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)))
            )
        })
    }

    // MARK: - Autopilot

    func startAutopilotSession() throws -> Int64 {
        let now = Int(Date().timeIntervalSince1970)
        return try execReturningRowID(
            "INSERT INTO autopilot_sessions(started_at) VALUES(?)", params: [String(now)]
        )
    }

    func endAutopilotSession(id: Int64) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("UPDATE autopilot_sessions SET ended_at=? WHERE id=?", params: [String(now), String(id)])
    }

    func updateAutopilotSessionCounts(id: Int64, handled: Int, pending: Int, sent: Int) throws {
        try exec(
            "UPDATE autopilot_sessions SET total_handled=?, total_pending=?, total_sent=? WHERE id=?",
            params: [String(handled), String(pending), String(sent), String(id)]
        )
    }

    func currentAutopilotSession() -> AutopilotSession? {
        queryOne("""
            SELECT id, started_at, ended_at, total_handled, total_pending, total_sent
            FROM autopilot_sessions WHERE ended_at IS NULL
            ORDER BY id DESC LIMIT 1
        """, bind: { _ in }, decode: decodeAutopilotSession)
    }

    private func decodeAutopilotSession(_ stmt: OpaquePointer?) -> AutopilotSession? {
        guard let stmt else { return nil }
        let endedAt = sqlite3_column_type(stmt, 2) != SQLITE_NULL
            ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))
            : nil
        return AutopilotSession(
            id: sqlite3_column_int64(stmt, 0),
            startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
            endedAt: endedAt,
            totalHandled: Int(sqlite3_column_int(stmt, 3)),
            totalPending: Int(sqlite3_column_int(stmt, 4)),
            totalSent: Int(sqlite3_column_int(stmt, 5))
        )
    }

    func insertAutopilotLog(_ entry: AutopilotLogEntry) throws {
        try withCachedStatement("""
            INSERT INTO autopilot_log(session_id, chat_username, chat_name, sender_username, sender_name,
                trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level, action, ai_reasoning, sent_at, created_at, queue_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, entry.sessionId)
            sqlite3_bind_text(stmt, 2, entry.chatUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 3, entry.chatName, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 4, entry.senderUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 5, entry.senderName, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 6, entry.triggerMsgUID, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 7, entry.triggerText, -1, Self.sqliteTransient)
            if let reply = entry.generatedReply {
                sqlite3_bind_text(stmt, 8, reply, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_double(stmt, 9, entry.confidence)
            sqlite3_bind_text(stmt, 10, entry.riskLevel.rawValue, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 11, entry.action.rawValue, -1, Self.sqliteTransient)
            if let reasoning = entry.aiReasoning {
                sqlite3_bind_text(stmt, 12, reasoning, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            if let sentAt = entry.sentAt {
                sqlite3_bind_int64(stmt, 13, Int64(sentAt.timeIntervalSince1970))
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            sqlite3_bind_int64(stmt, 14, Int64(entry.createdAt.timeIntervalSince1970))
            if let queueId = entry.queueId {
                sqlite3_bind_text(stmt, 15, queueId, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 15)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw HUDStoreError.sqlError("step autopilot_log insert: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    func loadAutopilotLog(sessionId: Int64, limit: Int = 50) -> [AutopilotLogEntry] {
        queryAll("""
            SELECT id, session_id, chat_username, chat_name, sender_username, sender_name,
                   trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level,
                   action, ai_reasoning, sent_at, created_at
            FROM autopilot_log WHERE session_id=? ORDER BY created_at DESC LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, sessionId)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }, decode: { decodeAutopilotLogEntry($0, defaultAction: .skipped) })
    }

    private func decodeAutopilotLogEntry(
        _ stmt: OpaquePointer?,
        defaultAction: AutopilotAction = .skipped
    ) -> AutopilotLogEntry? {
        guard let stmt else { return nil }
        let genReply = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Self.textColumn(stmt, 8) : nil
        let reasoning = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Self.textColumn(stmt, 12) : nil
        let sentAt = sqlite3_column_type(stmt, 13) != SQLITE_NULL
            ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 13)))
            : nil
        return AutopilotLogEntry(
            id: sqlite3_column_int64(stmt, 0),
            sessionId: sqlite3_column_int64(stmt, 1),
            chatUsername: Self.textColumn(stmt, 2),
            chatName: Self.textColumn(stmt, 3),
            senderUsername: Self.textColumn(stmt, 4),
            senderName: Self.textColumn(stmt, 5),
            triggerMsgUID: Self.textColumn(stmt, 6),
            triggerText: Self.textColumn(stmt, 7),
            generatedReply: genReply,
            confidence: sqlite3_column_double(stmt, 9),
            riskLevel: AutopilotRisk(rawValue: Self.textColumn(stmt, 10)) ?? .low,
            action: AutopilotAction(rawValue: Self.textColumn(stmt, 11)) ?? defaultAction,
            aiReasoning: reasoning,
            sentAt: sentAt,
            createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 14)))
        )
    }

    func loadPendingAutopilotItems(sessionId: Int64) -> [AutopilotLogEntry] {
        queryAll("""
            SELECT id, session_id, chat_username, chat_name, sender_username, sender_name,
                   trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level,
                   action, ai_reasoning, sent_at, created_at
            FROM autopilot_log WHERE session_id=? AND action='pending' ORDER BY created_at DESC
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, sessionId)
        }, decode: { decodeAutopilotLogEntry($0, defaultAction: .pending) })
    }

    func updateAutopilotLogAction(id: Int64, action: AutopilotAction) throws {
        try exec("UPDATE autopilot_log SET action=? WHERE id=?", params: [action.rawValue, String(id)])
    }

    func markAutopilotLogSent(id: Int64) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("UPDATE autopilot_log SET action='sent', sent_at=? WHERE id=?", params: [String(now), String(id)])
    }

    /// Pending drafts from every session, including ones whose session already ended.
    func loadOpenAutopilotPendingItems(relevantSince: Int? = nil) -> [AutopilotLogEntry] {
        loadOpenAutopilotPendingItems(relevantSince: relevantSince, limit: nil)
    }

    /// Upper bound for the pending half of the autopilot display list. The
    /// display used to load every pending row in the table on each refresh;
    /// once the log grew that became an unbounded read on a UI timer. 50
    /// matches the current-session half (loadAutopilotLog's default limit) so
    /// both halves of the list are bounded the same way.
    static let autopilotDisplayPendingLimit = 50

    /// Limit-aware variant. A nil limit preserves the public method's
    /// "return everything" semantics, which other callers still rely on;
    /// the display path passes a bound instead. Internal rather than private
    /// so a cross-file test can assert the bounded behavior directly.
    func loadOpenAutopilotPendingItems(relevantSince: Int?, limit pendingLimit: Int?) -> [AutopilotLogEntry] {
        // Fixed SQL variants keep the statement cache hot; dynamic string
        // concat would miss every time. Newest first so a limit drops old
        // leftovers (created_at ties break by id DESC).
        let select = """
            SELECT id, session_id, chat_username, chat_name, sender_username, sender_name,
                   trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level,
                   action, ai_reasoning, sent_at, created_at
            FROM autopilot_log WHERE action='pending'
            """
        let order = " ORDER BY created_at DESC, id DESC"
        switch (relevantSince, pendingLimit) {
        case (nil, nil):
            return queryAll(select + order, bind: { _ in }, decode: {
                decodeAutopilotLogEntry($0, defaultAction: .pending)
            })
        case let (since?, nil):
            return queryAll(
                select + " AND created_at >= ?" + order,
                bind: { sqlite3_bind_int64($0, 1, Int64(since)) },
                decode: { decodeAutopilotLogEntry($0, defaultAction: .pending) }
            )
        case let (nil, limit?):
            return queryAll(
                select + order + " LIMIT ?",
                bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
                decode: { decodeAutopilotLogEntry($0, defaultAction: .pending) }
            )
        case let (since?, limit?):
            return queryAll(
                select + " AND created_at >= ?" + order + " LIMIT ?",
                bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(since))
                    sqlite3_bind_int(stmt, 2, Int32(limit))
                },
                decode: { decodeAutopilotLogEntry($0, defaultAction: .pending) }
            )
        }
    }

    /// Current-session log plus leftover pending rows from ended sessions.
    func loadAutopilotDisplayLog(sessionId: Int64?, limit: Int = 50, relevantSince: Int? = nil) -> [AutopilotLogEntry] {
        var result: [AutopilotLogEntry] = []
        var seen = Set<Int64>()
        // Pending first (existing ordering contract), deduped by id, then the
        // current session's log appended. Only this display path bounds the
        // pending half; loadOpenAutopilotPendingItems itself is unchanged.
        for item in loadOpenAutopilotPendingItems(
            relevantSince: relevantSince,
            limit: Self.autopilotDisplayPendingLimit
        ) {
            if seen.insert(item.id).inserted { result.append(item) }
        }
        if let sessionId {
            for item in loadAutopilotLog(sessionId: sessionId, limit: limit) {
                if seen.insert(item.id).inserted { result.append(item) }
            }
        }
        return result
    }

    /// A draft save must only touch a still-pending row — a save landing
    /// after resolve would rewrite the audit trail of a sent/skipped send.
    func updateAutopilotLogReply(id: Int64, reply: String) throws {
        try exec(
            "UPDATE autopilot_log SET generated_reply=? WHERE id=? AND action='pending'",
            params: [reply, String(id)]
        )
    }

    func upsertPendingSend(_ item: PendingSend, sessionId: Int64) throws {
        try withCachedStatement("""
            INSERT INTO autopilot_pending_sends(
                id, session_id, chat_username, chat_name, sender_name, reply_text,
                confidence, risk_level, reasoning, style_score, scheduled_send_at,
                created_at, peer_last_message, topic, auto_send_attempts, manual_only_reason
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                session_id = excluded.session_id,
                chat_username = excluded.chat_username,
                chat_name = excluded.chat_name,
                sender_name = excluded.sender_name,
                reply_text = excluded.reply_text,
                confidence = excluded.confidence,
                risk_level = excluded.risk_level,
                reasoning = excluded.reasoning,
                style_score = excluded.style_score,
                scheduled_send_at = excluded.scheduled_send_at,
                peer_last_message = excluded.peer_last_message,
                topic = excluded.topic,
                auto_send_attempts = excluded.auto_send_attempts,
                manual_only_reason = excluded.manual_only_reason
        """) { stmt in
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, Self.sqliteTransient)
            sqlite3_bind_int64(stmt, 2, sessionId)
            sqlite3_bind_text(stmt, 3, item.chatUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 4, item.chatName, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 5, item.senderName, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 6, item.replyText, -1, Self.sqliteTransient)
            sqlite3_bind_double(stmt, 7, item.confidence)
            sqlite3_bind_text(stmt, 8, item.risk.rawValue, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 9, item.reasoning, -1, Self.sqliteTransient)
            sqlite3_bind_int(stmt, 10, Int32(item.styleScore))
            sqlite3_bind_int64(stmt, 11, Int64(item.scheduledSendTime.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 12, Int64(item.createdAt.timeIntervalSince1970))
            if let peerLastMessage = item.peerLastMessage {
                sqlite3_bind_text(stmt, 13, peerLastMessage, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            if let topic = item.topic {
                sqlite3_bind_text(stmt, 14, topic, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            sqlite3_bind_int(stmt, 15, Int32(item.autoSendAttempts))
            if let manualOnlyReason = item.manualOnlyReason {
                sqlite3_bind_text(stmt, 16, manualOnlyReason, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, 16)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw HUDStoreError.sqlError("step autopilot_pending_sends upsert: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    func loadPendingSends(sessionId: Int64) -> [PendingSend] {
        queryAll("""
            SELECT id, chat_username, chat_name, sender_name, reply_text,
                   confidence, risk_level, reasoning, style_score, scheduled_send_at,
                   created_at, peer_last_message, topic, auto_send_attempts, manual_only_reason
            FROM autopilot_pending_sends
            WHERE session_id=?
            ORDER BY scheduled_send_at ASC, created_at ASC
        """, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, sessionId)
        }, decode: { stmt in
            guard let id = UUID(uuidString: Self.textColumn(stmt, 0)) else { return nil }
            let risk = AutopilotRisk(rawValue: Self.textColumn(stmt, 6)) ?? .low
            let peerLastMessage = sqlite3_column_type(stmt, 11) != SQLITE_NULL ? Self.textColumn(stmt, 11) : nil
            let topic = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Self.textColumn(stmt, 12) : nil
            let manualOnlyReason = sqlite3_column_type(stmt, 14) != SQLITE_NULL ? Self.textColumn(stmt, 14) : nil
            return PendingSend(
                id: id,
                chatUsername: Self.textColumn(stmt, 1),
                chatName: Self.textColumn(stmt, 2),
                senderName: Self.textColumn(stmt, 3),
                replyText: Self.textColumn(stmt, 4),
                confidence: sqlite3_column_double(stmt, 5),
                risk: risk,
                reasoning: Self.textColumn(stmt, 7),
                styleScore: Int(sqlite3_column_int(stmt, 8)),
                scheduledSendTime: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9))),
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10))),
                peerLastMessage: peerLastMessage,
                topic: topic,
                autoSendAttempts: Int(sqlite3_column_int(stmt, 13)),
                manualOnlyReason: manualOnlyReason
            )
        })
    }

    func deletePendingSend(id: UUID) throws {
        try exec("DELETE FROM autopilot_pending_sends WHERE id=?", params: [id.uuidString])
    }

    /// Whether a queued reply is still on the board. A send in flight re-reads
    /// this as its last permission check: 取消本条 / 停止 delete the row, and no
    /// keystroke may land after that.
    func hasPendingSend(id: UUID) -> Bool {
        queryOne(
            "SELECT 1 FROM autopilot_pending_sends WHERE id=? LIMIT 1",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.sqliteTransient)
            },
            decode: { _ in true }
        ) ?? false
    }

    /// A held reply exists as BOTH a pending_sends row and an autopilot_log
    /// row. New log rows carry the queue item's UUID in `queue_id` — resolve
    /// by that key. Rows written before the column existed match by
    /// (chat, replyText) but only ONE row at a time — resolving every
    /// identical-text match would send/skip a sibling's draft.
    /// `?N` bind indices differ per call site, so the predicate takes them.
    private func legacyTwinPredicate(chatParam: Int, replyParam: Int) -> String {
        "queue_id IS NULL AND rowid = (SELECT rowid FROM autopilot_log "
            + "WHERE queue_id IS NULL AND chat_username=?\(chatParam) AND generated_reply=?\(replyParam) "
            + "AND action='pending' ORDER BY created_at, rowid LIMIT 1)"
    }

    /// True when no log row claims this queue id — only then may the legacy
    /// text fallback run. Gating on flip-count alone would misfire for a
    /// new-format row whose twin is 'sent'/'stall' (legitimately 0 pending
    /// flips) and rewrite an unrelated same-text legacy row.
    private func twinClaimed(queueId: String) -> Bool {
        queryOne("SELECT 1 FROM autopilot_log WHERE queue_id=? LIMIT 1",
                 bind: { sqlite3_bind_text($0, 1, queueId, -1, Self.sqliteTransient) },
                 decode: { _ in 1 }) != nil
    }

    /// A queue item's log twin read three ways, because the one caller has to
    /// tell "the user took this back" apart from "we could not read whether
    /// they did". Collapsing the third case into either of the first two either
    /// retires a draft over a disk error or re-arms a rejected one.
    nonisolated enum AutopilotTwinState: Equatable {
        /// Still awaiting a human or an unverified send.
        case open
        /// Cancelled, rejected, or actually delivered.
        case resolved
        /// The query itself failed; neither of the above is known.
        case unreadable
    }

    /// The twin's state, or `.unreadable` when the row cannot be read.
    func autopilotLogTwinState(queueId: UUID) -> AutopilotTwinState {
        let qid = queueId.uuidString
        let action: Bool?
        do {
            action = try queryOneThrowing(
                "SELECT action, sent_at FROM autopilot_log WHERE queue_id=? LIMIT 1",
                bind: { sqlite3_bind_text($0, 1, qid, -1, Self.sqliteTransient) },
                decode: { stmt -> Bool in
                    guard let c = sqlite3_column_text(stmt, 0) else { return false }
                    let action = String(cString: c)
                    return action == "pending" || action == "stall"
                        || (action == "sent" && sqlite3_column_type(stmt, 1) == SQLITE_NULL)
                }
            )
        } catch {
            return .unreadable
        }
        guard let action else { return .resolved }
        return action ? .open : .resolved
    }

    /// A queued-but-unverified send claim: 'sent' written at enqueue time
    /// (sent_at NULL) or a 'stall' row — both assert a send that has not
    /// completed.
    private static let unverifiedClaim = "(action='sent' AND sent_at IS NULL OR action='stall')"

    /// A verified send retires the queue row and resolves its log twin in one
    /// transaction. Split across two `try?` calls, a failed twin flip left the
    /// twin 'pending' with no queue row — the approval list kept offering
    /// 确认发送 for a reply the peer had already received, and one click sent
    /// it a second time. Rolled back instead, the queue row is still there for
    /// the staleness and new-content gates to reach.
    func resolveVerifiedSend(
        queueId: UUID, chatUsername: String, replyText: String
    ) throws -> Int {
        try withTransaction {
            try deletePendingSend(id: queueId)
            return try markAutopilotLogSent(
                queueId: queueId, chatUsername: chatUsername, replyText: replyText)
        }
    }

    /// Resolve the log twin of a queue item. Returns the flipped row count —
    /// callers decrement pending counters only when a pending row resolved.
    @discardableResult
    func markAutopilotLogSent(queueId: UUID, chatUsername: String, replyText: String) throws -> Int {
        // Two to four statements against different row states ('unverified
        // claim', 'skipped', 'pending'): half-applied, the same reply is both
        // 'sent' and still awaiting a human.
        try withTransaction {
            try markAutopilotLogSentUnchecked(
                queueId: queueId, chatUsername: chatUsername, replyText: replyText)
        }
    }

    private func markAutopilotLogSentUnchecked(
        queueId: UUID, chatUsername: String, replyText: String
    ) throws -> Int {
        let now = String(Int(Date().timeIntervalSince1970))
        let qid = queueId.uuidString
        // .sent rows are written at ENQUEUE time with sent_at NULL — stamp
        // the verified-send time on the .sent twin too. A 'skipped' twin means
        // a reject raced an in-flight send that then verifiably completed —
        // the send is the truth; flip it back.
        try exec(
            "UPDATE autopilot_log SET action='sent', sent_at=? WHERE queue_id=? AND \(Self.unverifiedClaim)",
            params: [now, qid]
        )
        try exec(
            "UPDATE autopilot_log SET action='sent', sent_at=? WHERE queue_id=? AND action='skipped'",
            params: [now, qid]
        )
        var changes = try execReturningChanges(
            "UPDATE autopilot_log SET action='sent', sent_at=? WHERE queue_id=? AND action='pending'",
            params: [now, qid]
        )
        if changes == 0 && !twinClaimed(queueId: qid) {
            // Legacy row without queue_id — bound to a single match.
            changes = try execReturningChanges(
                """
                UPDATE autopilot_log SET action='sent', sent_at=?1
                WHERE \(legacyTwinPredicate(chatParam: 2, replyParam: 3))
                """,
                params: [now, chatUsername, replyText]
            )
            // Also stamp a legacy .sent twin — bounded to one row so two
            // same-text legacy items don't share the first send's stamp.
            try exec(
                """
                UPDATE autopilot_log SET action='sent', sent_at=?1
                WHERE queue_id IS NULL AND rowid = (
                    SELECT rowid FROM autopilot_log WHERE queue_id IS NULL
                        AND chat_username=?2 AND generated_reply=?3
                        AND \(Self.unverifiedClaim)
                    ORDER BY created_at, rowid LIMIT 1)
                """,
                params: [now, chatUsername, replyText]
            )
        }
        return changes
    }

    /// The cancel counterpart — a canceled queue row must also resolve the
    /// pending log twin, or the approval UI keeps offering 确认发送 for a
    /// reply the user just canceled. Returns the flipped row count.
    @discardableResult
    func markAutopilotLogSkipped(queueId: UUID, chatUsername: String, replyText: String) throws -> Int {
        try withTransaction {
            try markAutopilotLogSkippedUnchecked(
                queueId: queueId, chatUsername: chatUsername, replyText: replyText)
        }
    }

    private func markAutopilotLogSkippedUnchecked(
        queueId: UUID, chatUsername: String, replyText: String
    ) throws -> Int {
        let qid = queueId.uuidString
        // An unverified send claim (enqueue-time '.sent', or a 'stall' row)
        // claimed a send that never happened — a stop/cancel must un-claim
        // it too. Only the pending-flip counts toward counter decrements.
        try exec(
            "UPDATE autopilot_log SET action='skipped' WHERE queue_id=? AND \(Self.unverifiedClaim)",
            params: [qid]
        )
        var changes = try execReturningChanges(
            "UPDATE autopilot_log SET action='skipped' WHERE queue_id=? AND action='pending'",
            params: [qid]
        )
        if changes == 0 && !twinClaimed(queueId: qid) {
            changes = try execReturningChanges(
                "UPDATE autopilot_log SET action='skipped' WHERE \(legacyTwinPredicate(chatParam: 1, replyParam: 2))",
                params: [chatUsername, replyText]
            )
        }
        return changes
    }

    /// An auto-queued item converted to manual-only (cap/stale/send-failure)
    /// must flip its log twin back to 'pending' — it now needs a human, and
    /// leaving it '.sent' would claim a send that never happened AND keep it
    /// out of the approval list forever. Returns the flipped row count.
    @discardableResult
    func markAutopilotLogPending(queueId: UUID, chatUsername: String, replyText: String) throws -> Int {
        try withTransaction {
            try markAutopilotLogPendingUnchecked(
                queueId: queueId, chatUsername: chatUsername, replyText: replyText)
        }
    }

    private func markAutopilotLogPendingUnchecked(
        queueId: UUID, chatUsername: String, replyText: String
    ) throws -> Int {
        let qid = queueId.uuidString
        var changes = try execReturningChanges(
            "UPDATE autopilot_log SET action='pending' WHERE queue_id=? AND \(Self.unverifiedClaim)",
            params: [qid]
        )
        if changes == 0 && !twinClaimed(queueId: qid) {
            changes = try execReturningChanges(
                """
                UPDATE autopilot_log SET action='pending'
                WHERE queue_id IS NULL AND rowid = (
                    SELECT rowid FROM autopilot_log WHERE queue_id IS NULL
                        AND chat_username=?1 AND generated_reply=?2
                        AND \(Self.unverifiedClaim)
                    ORDER BY created_at, rowid LIMIT 1)
                """,
                params: [chatUsername, replyText]
            )
        }
        return changes
    }

    /// Delete the queue twin of a LOG row — the reverse direction. Keyed by
    /// the log's queue_id; the legacy text match only runs when the log row
    /// itself carries no queue_id (a claimed twin was already deleted above;
    /// deleting again by text could kill an unclaimed sibling).
    func deletePendingSendForLog(logId: Int64, chatUsername: String, replyText: String) throws {
        if let qid = autopilotLogQueueId(id: logId), !qid.isEmpty {
            try exec("DELETE FROM autopilot_pending_sends WHERE id=?", params: [qid])
            return
        }
        // Legacy twins have no queue_id anywhere — bounded single match.
        try exec(
            """
            DELETE FROM autopilot_pending_sends WHERE rowid = (
                SELECT rowid FROM autopilot_pending_sends
                WHERE chat_username=?1 AND reply_text=?2
                    AND NOT EXISTS(SELECT 1 FROM autopilot_log WHERE queue_id=autopilot_pending_sends.id)
                ORDER BY created_at, rowid LIMIT 1)
            """,
            params: [chatUsername, replyText]
        )
    }

    /// The queue item UUID a log row twins with.
    func autopilotLogQueueId(id: Int64) -> String? {
        queryOne(
            "SELECT queue_id FROM autopilot_log WHERE id=?",
            bind: { stmt in sqlite3_bind_int64(stmt, 1, id) },
            decode: { stmt in
                sqlite3_column_type(stmt, 0) != SQLITE_NULL ? Self.textColumn(stmt, 0) : nil
            }
        )
    }

    /// Atomically record a verified send on a log row. Returns whether a
    /// 'pending' row was consumed — the check and the write share one
    /// transaction so a racing reject can't double-count sessionPending.
    /// The send DID happen, so the row is written 'sent' regardless of its
    /// prior action; only the pending-flip is counted.
    @discardableResult
    func resolveAutopilotLogSent(id: Int64) -> Bool {
        var consumed = false
        try? withTransaction {
            let action = queryOne(
                "SELECT action FROM autopilot_log WHERE id=?",
                bind: { stmt in sqlite3_bind_int64(stmt, 1, id) },
                decode: { stmt in Self.textColumn(stmt, 0) }
            )
            consumed = (action == AutopilotAction.pending.rawValue)
            try exec(
                "UPDATE autopilot_log SET action='sent', sent_at=? WHERE id=?",
                params: [String(Int(Date().timeIntervalSince1970)), String(id)]
            )
        }
        return consumed
    }

    /// Atomically skip a log row ONLY if still pending — a reject racing an
    /// in-flight approve must not stomp a completed send. Returns whether a
    /// pending row was consumed (for sessionPending accounting).
    @discardableResult
    func resolveAutopilotLogSkipped(id: Int64) -> Bool {
        (try? execReturningChanges(
            "UPDATE autopilot_log SET action='skipped' WHERE id=? AND action='pending'",
            params: [String(id)]
        )) == 1
    }

    /// Sync the log twin's text when a queue item's reply is edited —
    /// after a blocked editAndSend the log must show/send the edited text,
    /// not the superseded original.
    func updateAutopilotLogReplyForQueue(queueId: UUID, reply: String) throws {
        try exec(
            "UPDATE autopilot_log SET generated_reply=? WHERE queue_id=? AND action='pending'",
            params: [reply, queueId.uuidString]
        )
    }

    /// Re-key the queue twin when a draft is edited in place — the log's
    /// generated_reply changes, so the queue row's reply_text must follow
    /// or the twin link breaks and the pre-edit text stays sendable.
    func updatePendingSendReply(id: UUID, newReply: String) throws {
        try exec(
            "UPDATE autopilot_pending_sends SET reply_text=? WHERE id=?",
            params: [newReply, id.uuidString]
        )
    }

    /// The reply text ONLY when the row is still pending — approvePending
    /// re-validates against this so a stale UI snapshot cannot re-send a
    /// row that was already rejected/sent/canceled.
    func autopilotLogPendingReply(id: Int64) -> String? {
        queryOne(
            "SELECT generated_reply FROM autopilot_log WHERE id=? AND action='pending'",
            bind: { stmt in sqlite3_bind_int64(stmt, 1, id) },
            decode: { stmt in Self.textColumn(stmt, 0) }
        )
    }

    func clearPendingSends(sessionId: Int64) throws {
        try exec("DELETE FROM autopilot_pending_sends WHERE session_id=?", params: [String(sessionId)])
    }

    /// Commitment analysis runs once per msg_uid ever — a chat whose
    /// watermark is held mid-backfill re-surfaces the same self messages
    /// every scan, and without this mark each pass would re-pay the AI call.
    /// Returns true when the uid was newly marked (first sight).
    /// Claim one analysis attempt for a msg_uid — bounded at `maxAttempts`.
    /// Mark-first-then-analyze used to permanently lose commitments on a
    /// transient failure (the mark survived, the analysis died with it);
    /// an attempts counter lets a failed pass retry on the next scan
    /// without ever becoming an unbounded per-scan AI call.
    func markCommitmentAnalyzedIfNew(msgUID: String, maxAttempts: Int = 3) -> Bool {
        do {
            var changes = 0
            // changes() must be read inside the same mutex acquisition as the
            // write — a separate query hop lets another writer's statement
            // interleave and corrupt the count.
            try withCachedStatement("""
                INSERT INTO commitment_scans(msg_uid, created_at, attempts)
                VALUES(?, ?, 1)
                ON CONFLICT(msg_uid) DO UPDATE SET attempts = attempts + 1
                WHERE attempts < ?
            """) { stmt in
                sqlite3_bind_text(stmt, 1, msgUID, -1, Self.sqliteTransient)
                sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
                sqlite3_bind_int64(stmt, 3, Int64(maxAttempts))
                // A failed step must THROW — returning false here would
                // fail closed (the caller skips analysis forever), while
                // the catch below is deliberately fail-open. changes==0 is
                // the legitimate "attempts exhausted" signal, not an error.
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw HUDStoreError.sqlError(
                        String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt)))
                    )
                }
                changes = Int(sqlite3_changes(sqlite3_db_handle(stmt)))
            }
            return changes == 1
        } catch {
            // A failed mark must not suppress analysis — the message may
            // never have been seen. Failing open is a wasted AI call,
            // not a lost commitment.
            return true
        }
    }

    /// Same rule as `MessageInfo.contentKey`: the timestamp distinguishes a
    /// genuinely repeated text from a moved/shard-replayed row.
    private static func autopilotContentKey(_ msg: AutopilotService.InboundMessage) -> String {
        "\(msg.chatUsername)|\(msg.timestamp)|\(msg.messageType)|\(msg.appType)|\(msg.senderUsername)|\(msg.text)"
    }

    func enqueueAutopilotInbound(_ msg: AutopilotService.InboundMessage) throws {
        try withCachedStatement("""
            INSERT INTO autopilot_inbound_queue(
                msg_uid, chat_username, chat_name, sender_username, sender_name, text,
                is_group, is_at_mention, attention_level, contact_role, msg_timestamp,
                message_type, app_type, created_at, content_key
            ) SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
            WHERE NOT EXISTS(
                SELECT 1 FROM autopilot_inbound_queue WHERE msg_uid=? OR content_key=?
            )
        """) { stmt in
            sqlite3_bind_text(stmt, 1, msg.msgUID, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 2, msg.chatUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 3, msg.chatName, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 4, msg.senderUsername, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 5, msg.senderName, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 6, msg.text, -1, Self.sqliteTransient)
            sqlite3_bind_int(stmt, 7, msg.isGroup ? 1 : 0)
            sqlite3_bind_int(stmt, 8, msg.isAtMention ? 1 : 0)
            sqlite3_bind_text(stmt, 9, msg.attentionLevel.rawValue, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 10, msg.contactRole.rawValue, -1, Self.sqliteTransient)
            sqlite3_bind_int64(stmt, 11, Int64(msg.timestamp))
            sqlite3_bind_int(stmt, 12, Int32(msg.messageType))
            sqlite3_bind_int(stmt, 13, Int32(msg.appType))
            sqlite3_bind_int64(stmt, 14, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt, 15, Self.autopilotContentKey(msg), -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 16, msg.msgUID, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 17, Self.autopilotContentKey(msg), -1, Self.sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw HUDStoreError.sqlError("step autopilot_inbound_queue insert: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    func loadPendingAutopilotInbound(limit: Int = 200) -> [AutopilotService.InboundMessage] {
        queryAll("""
            SELECT msg_uid, chat_username, chat_name, sender_username, sender_name, text,
                   is_group, is_at_mention, attention_level, contact_role, msg_timestamp,
                   message_type, app_type
            FROM autopilot_inbound_queue
            ORDER BY msg_timestamp ASC, created_at ASC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }, decode: { stmt in
            let attention = AttentionLevel(rawValue: Self.textColumn(stmt, 8)) ?? .stranger
            let role = ContactRole(rawValue: Self.textColumn(stmt, 9)) ?? .acquaintance
            return AutopilotService.InboundMessage(
                msgUID: Self.textColumn(stmt, 0),
                chatUsername: Self.textColumn(stmt, 1),
                chatName: Self.textColumn(stmt, 2),
                senderUsername: Self.textColumn(stmt, 3),
                senderName: Self.textColumn(stmt, 4),
                text: Self.textColumn(stmt, 5),
                isGroup: sqlite3_column_int(stmt, 6) != 0,
                isAtMention: sqlite3_column_int(stmt, 7) != 0,
                attentionLevel: attention,
                contactRole: role,
                timestamp: Int(sqlite3_column_int64(stmt, 10)),
                messageType: Int(sqlite3_column_int(stmt, 11)),
                appType: Int(sqlite3_column_int(stmt, 12))
            )
        })
    }

    func deleteAutopilotInbound(msgUIDs: [String]) throws {
        guard !msgUIDs.isEmpty else { return }
        try withTransaction {
            for uid in msgUIDs {
                try exec("DELETE FROM autopilot_inbound_queue WHERE msg_uid=?", params: [uid])
            }
        }
    }

    func clearAutopilotInboundQueue() throws {
        try exec("DELETE FROM autopilot_inbound_queue")
    }

    func loadAutopilotSessions(limit: Int = 20) -> [AutopilotSession] {
        queryAll("""
            SELECT id, started_at, ended_at, total_handled, total_pending, total_sent
            FROM autopilot_sessions ORDER BY id DESC LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }, decode: decodeAutopilotSession)
    }

    func clearAutopilotHistory() throws {
        try withTransaction {
            guard currentAutopilotSession() == nil else {
                throw NSError(domain: "WeChatHUD", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "请先结束自动托管，再清除历史记录。"])
            }
            // Only reachable with no live session — pending_sends rows are
            // keyed by session_id, so deleting the log+sessions would orphan
            // them (loadPendingSends could never reach them again).
            try exec("DELETE FROM autopilot_log")
            try exec("DELETE FROM autopilot_sessions WHERE ended_at IS NOT NULL")
            try exec("DELETE FROM autopilot_pending_sends")
        }
    }

    // MARK: - Relationship Profiles

    func upsertRelationshipProfile(_ profile: RelationshipProfile) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO relationship_profiles(
                username, display_name, relationship, hierarchy,
                tone_preference, context, confidence, user_note,
                user_edited, inferred_at, updated_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(username) DO UPDATE SET
                display_name = excluded.display_name,
                relationship = excluded.relationship,
                hierarchy = excluded.hierarchy,
                tone_preference = excluded.tone_preference,
                context = excluded.context,
                confidence = excluded.confidence,
                user_note = CASE WHEN relationship_profiles.user_edited = 1
                            THEN relationship_profiles.user_note
                            ELSE excluded.user_note END,
                user_edited = CASE WHEN relationship_profiles.user_edited = 1
                              THEN 1 ELSE excluded.user_edited END,
                updated_at = excluded.updated_at
        """, params: [
            profile.username, profile.displayName, profile.relationship,
            profile.hierarchy.rawValue, profile.tonePreference.rawValue,
            profile.context ?? "", "\(profile.confidence)",
            profile.userNote ?? "", profile.userEdited ? "1" : "0",
            "\(Int(profile.inferredAt.timeIntervalSince1970))", "\(now)"
        ])
    }

    func getRelationshipProfile(username: String) -> RelationshipProfile? {
        queryOne(
            "SELECT username, display_name, relationship, hierarchy, tone_preference, context, confidence, user_note, user_edited, inferred_at, updated_at FROM relationship_profiles WHERE username = ?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, username, -1, Self.sqliteTransient)
            },
            decode: { stmt in parseRelationshipRow(stmt) }
        )
    }

    func loadAllRelationshipProfiles() -> [RelationshipProfile] {
        queryAll(
            "SELECT username, display_name, relationship, hierarchy, tone_preference, context, confidence, user_note, user_edited, inferred_at, updated_at FROM relationship_profiles ORDER BY updated_at DESC",
            bind: { _ in },
            decode: { stmt in parseRelationshipRow(stmt) }
        )
    }

    func updateRelationshipProfileUserFields(
        username: String,
        relationship: String,
        hierarchy: RelationshipProfile.Hierarchy,
        tonePreference: RelationshipProfile.TonePreference,
        userNote: String?
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE relationship_profiles SET
                relationship = ?, hierarchy = ?, tone_preference = ?,
                user_note = ?, user_edited = 1, updated_at = ?
            WHERE username = ?
        """, params: [relationship, hierarchy.rawValue, tonePreference.rawValue,
                      userNote ?? "", "\(now)", username])
    }

    func deleteRelationshipProfile(username: String) throws {
        try exec("DELETE FROM relationship_profiles WHERE username = ?", params: [username])
    }

    private func parseRelationshipRow(_ stmt: OpaquePointer?) -> RelationshipProfile {
        // textColumn is NULL-safe; `String(cString: column_text)` traps on a
        // NULL pointer, and `context`/`user_note` are nullable columns.
        RelationshipProfile(
            username: Self.textColumn(stmt, 0),
            displayName: Self.textColumn(stmt, 1),
            relationship: Self.textColumn(stmt, 2),
            hierarchy: RelationshipProfile.Hierarchy(rawValue: Self.textColumn(stmt, 3)) ?? .peer,
            tonePreference: RelationshipProfile.TonePreference(rawValue: Self.textColumn(stmt, 4)) ?? .formal,
            context: {
                let s = Self.textColumn(stmt, 5)
                return s.isEmpty ? nil : s
            }(),
            confidence: sqlite3_column_double(stmt, 6),
            userNote: {
                let s = Self.textColumn(stmt, 7)
                return s.isEmpty ? nil : s
            }(),
            userEdited: sqlite3_column_int(stmt, 8) != 0,
            inferredAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9))),
            updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10)))
        )
    }

    // MARK: - Migration

    /// One-time migration: copy whitelist entries into the new contacts table.
    /// Maps old watch → whitelist, old vip → vip. Role defaults to .colleague
    /// for work, .friend for life, .acquaintance for other.
    func migrateWhitelistToContacts() {
        let entries = getWhitelist()
        for entry in entries {
            let newLevel: AttentionLevel = entry.attentionLevel == .vip ? .vip : .whitelist
            if getContact(username: entry.id) == nil {
                try? upsertContact(
                    username: entry.id,
                    displayName: entry.displayName,
                    attentionLevel: newLevel,
                    role: defaultContactRole(for: entry.category)
                )
            }
        }
    }

    /// Contacts settings is the product VIP list; the scan still reads whitelist.
    /// A contact marked 重点关注 must be scanned as VIP even if an older writer
    /// left whitelist on watch or omitted the row.
    func repairVIPTrackingAlignment() {
        for contact in loadContacts() where contact.attentionLevel == .vip {
            let existing = getWhitelistEntry(username: contact.username)
            guard existing?.attentionLevel != .vip else { continue }
            try? upsertWhitelistTracking(
                username: contact.username,
                displayName: existing?.displayName ?? contact.displayName,
                isGroup: existing?.isGroup ?? MessageHelpers.isGroupChat(contact.username),
                category: existing?.category ?? .other,
                attentionLevel: .vip
            )
        }
    }

    private func defaultContactRole(for category: WhitelistCategory) -> ContactRole {
        switch category {
        case .work: return .colleague
        case .life: return .friend
        case .other: return .acquaintance
        }
    }

    // MARK: - Helpers

    /// Persist source snapshots before the reader cursor moves. Inserts are idempotent.
    func enqueueClassificationMessages(_ messages: [MessageInfo]) throws {
        let encoder = JSONEncoder()
        for message in messages {
            let payload = String(decoding: try encoder.encode(message), as: UTF8.self)
            // Keep a normal INSERT in the statement so triggers and other
            // persistence failures remain visible to the caller. The NOT
            // EXISTS predicate provides idempotency without INSERT OR IGNORE
            // swallowing an actual write error.
            try exec("""
                INSERT INTO classification_queue(msg_uid,payload,source_timestamp,content_key)
                SELECT ?,?,?,? WHERE NOT EXISTS(
                    SELECT 1 FROM classification_queue WHERE msg_uid=? OR content_key=?
                )
            """, params: [message.id, payload, String(message.createTime), message.contentKey,
                          message.id, message.contentKey])
        }
    }

    /// An undecodable payload used to survive forever — decoded to nil on
    /// every poll, never completed/deferred, and its message never
    /// classified. Quarantine it (delete + log) so the queue moves on.
    func pendingClassificationMessages(limit: Int = 40) -> [MessageInfo] {
        let now = Int64(Date().timeIntervalSince1970)
        let capped = Int32(max(1, min(limit, 200)))
        var poisoned: [String] = []
        let rows = queryAll(
            "SELECT msg_uid, payload FROM classification_queue WHERE retry_after <= ? ORDER BY source_timestamp, msg_uid LIMIT ?",
            bind: { stmt in
                sqlite3_bind_int64(stmt, 1, now)
                sqlite3_bind_int(stmt, 2, capped)
            },
            decode: { stmt -> MessageInfo? in
                let uid = Self.textColumn(stmt, 0)
                let payload = Self.textColumn(stmt, 1)
                guard let data = payload.data(using: .utf8),
                      let msg = try? JSONDecoder().decode(MessageInfo.self, from: data),
                      // A payload that decodes but names a different uid is
                      // still poison — the queue key is the STORED uid, and
                      // completing by the decoded id would never delete this
                      // row, leaving it to ride every batch forever.
                      msg.id == uid else {
                    poisoned.append(uid)
                    return nil
                }
                return msg
            }
        )
        if !poisoned.isEmpty {
            print("[WCHUD] classification queue: dropped \(poisoned.count) undecodable rows")
            for uid in poisoned {
                if uid.isEmpty {
                    // textColumn maps NULL → "" and `WHERE msg_uid=''` never
                    // matches NULL — an externally-corrupted NULL-uid row
                    // would otherwise re-poison every poll.
                    // Stored '' uids are equally unmatchable — same poison.
                    try? exec("DELETE FROM classification_queue WHERE msg_uid IS NULL OR msg_uid=''")
                } else {
                    try? completeClassificationMessage(id: uid)
                }
            }
        }
        return rows
    }

    func classificationQueueCount() -> Int {
        scalarCount("SELECT COUNT(*) FROM classification_queue")
    }

    func completeClassificationMessage(id: String) throws {
        try exec("DELETE FROM classification_queue WHERE msg_uid=?", params: [id])
    }

    /// Preserve failed work; back off up to 30 minutes instead of losing it or hot-looping.
    func deferClassificationMessage(id: String) throws {
        try exec("UPDATE classification_queue SET attempts=attempts+1, retry_after=? + MIN(1800, 30 * (attempts+1)) WHERE msg_uid=?",
                 params: [String(Int(Date().timeIntervalSince1970)), id])
    }

    func retryClassificationMessages() throws {
        try exec("UPDATE classification_queue SET retry_after=0")
    }

    /// Serial write helper. Internal so same-module extensions (radar, etc.)
    /// share the cached-statement + `perform` queue path.
    func exec(_ sql: String, params: [String?] = []) throws {
        try withCachedStatement(sql, params: params) { stmt in
            // Loop to consume any result rows (e.g. PRAGMA journal_mode returns SQLITE_ROW).
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return }
                if rc == SQLITE_ROW { continue }
                throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// `exec` plus the statement's `sqlite3_changes`, read inside the same
    /// mutex acquisition. Callers that exec-then-read-changes across two
    /// scope hops race: another writer's statement between them rewrites
    /// the connection's change counter.
    func execReturningChanges(_ sql: String, params: [String?] = []) throws -> Int {
        var changes = 0
        try withCachedStatement(sql, params: params) { stmt in
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE {
                    changes = Int(sqlite3_changes(sqlite3_db_handle(stmt)))
                    return
                }
                if rc == SQLITE_ROW { continue }
                throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
            }
        }
        return changes
    }

    /// `exec` plus `sqlite3_last_insert_rowid`, read inside the same mutex
    /// acquisition — same interleaving race as `execReturningChanges`.
    func execReturningRowID(_ sql: String, params: [String?] = []) throws -> Int64 {
        var rowID: Int64 = 0
        try withCachedStatement(sql, params: params) { stmt in
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE {
                    rowID = sqlite3_last_insert_rowid(sqlite3_db_handle(stmt))
                    return
                }
                if rc == SQLITE_ROW { continue }
                throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
            }
        }
        return rowID
    }

    // MARK: - Cached statement plumbing
    //
    // Failure semantics are deliberately identical to the uncached code:
    // prepare failures surface as HUDStoreError.sqlError (throwing callers)
    // or nil/0/[] (non-throwing callers), always with the same
    // sqlite3_errmsg text, and a statement that failed to step is discarded
    // instead of being reused.

    /// Clears any statements belonging to a previous connection. Called
    /// right after (re)opening so a stale handle can never be stepped on the
    /// new one.
    private func prepareStatementCacheForNewConnection() {
        try? withDatabaseMutex {
            for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
            statementCache.removeAll()
            statementCacheLRU.removeAll()
        }
    }

    /// Finalizes every cached statement. MUST run before sqlite3_close:
    /// close returns SQLITE_BUSY (and leaks the handle) while statements are
    /// still alive.
    private func finalizeCachedStatements() {
        try? withDatabaseMutex {
            for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
            statementCache.removeAll()
            statementCacheLRU.removeAll()
        }
    }

    /// Hand a single SQL string back to the cache, evicting the
    /// least-recently-used half once capacity is exceeded.
    private func storeCachedStatement(_ sql: String, _ stmt: OpaquePointer) {
        if statementCache[sql] == nil {
            if statementCacheLRU.count >= Self.statementCacheCapacity {
                for victim in statementCacheLRU.prefix(Self.statementCacheEvictCount) {
                    if let stale = statementCache.removeValue(forKey: victim) {
                        sqlite3_finalize(stale)
                    }
                }
                statementCacheLRU.removeFirst(min(Self.statementCacheEvictCount, statementCacheLRU.count))
            }
            statementCacheLRU.append(sql)
        }
        statementCache[sql] = stmt
    }

    /// Move an LRU entry to the most-recently-used end. The cache is tiny
    /// (capacity 24), so the O(n) rebuild on a hit is far cheaper than the
    /// prepare it avoids.
    private func touchStatementCacheLRU(_ sql: String) {
        guard let index = statementCacheLRU.firstIndex(of: sql) else {
            statementCacheLRU.append(sql)
            return
        }
        guard index != statementCacheLRU.count - 1 else { return }
        statementCacheLRU.remove(at: index)
        statementCacheLRU.append(sql)
    }

    /// Runs the body on a prepared statement, reusing the cached one when
    /// the exact SQL string was compiled before.
    ///
    /// Two invariants matter on the reuse path:
    /// 1. sqlite3_reset + sqlite3_clear_bindings before every reuse. Without
    ///    them a reused statement would keep the previous call's bindings
    ///    (wrong rows) and its stepped state (SQLITE_MISUSE).
    /// 2. The reset/bind/step sequence holds the recursive connection mutex,
    ///    so two threads can never interleave binds on one statement.
    ///
    /// A statement returns to the cache only after a clean step. On a prepare
    /// or step failure it is finalized and dropped, so the next caller
    /// recompiles rather than stepping a poisoned statement.
    private func withCachedStatement(
        _ sql: String,
        params: [String?] = [],
        cacheOnSuccess: Bool = true,
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        try withDatabaseMutex {
            let statement: OpaquePointer?
            if let cached = statementCache[sql] {
                // sqlite3_reset's return value describes the previous step,
                // not a new failure, so it is intentionally ignored; this
                // call's step below reports the error that matters.
                sqlite3_reset(cached)
                sqlite3_clear_bindings(cached)
                touchStatementCacheLRU(sql)
                statement = cached
            } else {
                var prepared: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK else {
                    sqlite3_finalize(prepared)
                    throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
                }
                statementPrepareCount += 1
                statement = prepared
            }
            guard let stmt = statement else {
                throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }

            for (i, p) in params.enumerated() {
                // nil binds a real NULL. Writing an empty string instead is
                // what made `due_at` unreadable to `IS NULL` and to numeric
                // comparisons — see the note in insertDiscussionItem.
                if let p {
                    sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.sqliteTransient)
                } else {
                    sqlite3_bind_null(stmt, Int32(i + 1))
                }
            }
            // sqlite3_stmt_readonly distinguishes writes from SELECT/PRAGMA
            // without sniffing the SQL text, so the write counter stays
            // correct even for PRAGMA statements that return rows.
            let isWrite = sqlite3_stmt_readonly(stmt) == 0

            do {
                try body(stmt)
            } catch {
                // Poisoned statement: never reused, never kept. It must be
                // finalized unconditionally — a first-time failure happens
                // BEFORE storeCachedStatement, so gating finalize on a cache
                // hit leaked the prepared handle (and a leaked statement
                // makes sqlite3_close return SQLITE_BUSY — the connection
                // and its WAL never checkpoint).
                statementCache.removeValue(forKey: sql)
                statementCacheLRU.removeAll { $0 == sql }
                sqlite3_finalize(stmt)
                throw error
            }

            if isWrite {
                // Counted per execution: the statement cache must not hide
                // "did we actually issue a write?" from callers or tests.
                writeStatementCount += 1
            }
            // Callers that report their own bind failures opt out of caching
            // so a partially-bound statement can never be reused.
            if cacheOnSuccess {
                storeCachedStatement(sql, stmt)
                // Always reset after use. queryOne often returns while still
                // on SQLITE_ROW; leaving that cursor open pins a read
                // transaction and later UPDATEs on this connection cannot see
                // committed writes from other connections
                // (DiscussionDueAtStorageTests migration path).
                sqlite3_reset(stmt)
            } else {
                // Opted out of the cache — the handle is orphaned if not
                // finalized here.
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Run a synchronous unit of work while holding SQLite's connection
    /// mutex for the complete transaction. FULLMUTEX only serializes each
    /// sqlite call; without this boundary another thread could interleave
    /// writes between BEGIN and COMMIT. Nested callers use savepoints.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try withDatabaseMutex {
            let nested = transactionDepth > 0
            let savepoint = "hud_store_sp_\(transactionDepth)"
            if nested {
                try exec("SAVEPOINT \(savepoint)")
            } else {
                try exec("BEGIN IMMEDIATE")
            }
            transactionDepth += 1
            do {
                let value = try body()
                if nested {
                    try exec("RELEASE SAVEPOINT \(savepoint)")
                } else {
                    try exec("COMMIT")
                }
                transactionDepth -= 1
                return value
            } catch {
                transactionDepth -= 1
                if nested {
                    try? exec("ROLLBACK TO SAVEPOINT \(savepoint)")
                    try? exec("RELEASE SAVEPOINT \(savepoint)")
                } else {
                    try? exec("ROLLBACK")
                }
                throw error
            }
        }
    }

    /// Hold the SQLite connection mutex across a synchronous sequence of
    /// calls. Used by the intentionally best-effort ledger batch, whose
    /// partial-success semantics are preserved.
    /// Hop onto the store's serial queue when the caller is not already on it.
    func perform<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.serialQueueKey) != nil {
            return try body()
        }
        return try serialQueue.sync {
            try body()
        }
    }

    func withDatabaseMutex<T>(_ body: () throws -> T) throws -> T {
        try perform {
            guard let db, let mutex = sqlite3_db_mutex(db) else {
                throw HUDStoreError.sqlError("Database is not open")
            }
            sqlite3_mutex_enter(mutex)
            defer { sqlite3_mutex_leave(mutex) }
            return try body()
        }
    }

    // MARK: - Retrospective extension helpers
    //
    // Exposed to the +Retrospective extension (different file). HUDStore
    // is a non-actor `final class` with FULLMUTEX, so all SQL is internally
    // serialized; these helpers are `nonisolated` so actors can call them
    // synchronously without await.

    /// Lets the extension prepare its own statements. Stays internal —
    /// not part of the public surface.
    nonisolated var rawDB: OpaquePointer? { db }

    /// Test/extension hook onto the same throwing exec path the store uses
    /// internally. Exists so tests can assert the exact failure surface
    /// (HUDStoreError.sqlError) without duplicating the call.
    nonisolated func execProbeThrowing(_ sql: String) throws {
        try exec(sql)
    }

    /// Best-effort SQL exec used by retrospective migration (mirrors the
    /// existing private exec but swallows errors, matching the codebase's
    /// best-effort `try? exec("ALTER TABLE …")` pattern).
    nonisolated func execIgnoringError(_ sql: String) {
        // Same connection and same cache as every other caller. Both the
        // cache dictionary and the shared statement handle are reached
        // through the recursive connection mutex, so a best-effort call from
        // another thread cannot corrupt a bound statement mid-step. Errors
        // stay swallowed exactly as before.
        try? withCachedStatement(sql) { stmt in
            sqlite3_step(stmt)
        }
    }

    typealias SQLiteBinder = (OpaquePointer?) -> Void

    @discardableResult
    nonisolated func executeInsert(_ sql: String, bind: SQLiteBinder) -> Int? {
        var rowID: Int? = nil
        // A prepare failure leaves the cache untouched and still returns nil,
        // matching the original uncached behavior.
        try? withCachedStatement(sql) { stmt in
            bind(stmt)
            rowID = (sqlite3_step(stmt) == SQLITE_DONE) ? Int(sqlite3_last_insert_rowid(db)) : nil
        }
        return rowID
    }

    @discardableResult
    nonisolated func executeUpdate(_ sql: String, bind: SQLiteBinder) -> Int {
        var changes = 0
        try? withCachedStatement(sql) { stmt in
            bind(stmt)
            changes = (sqlite3_step(stmt) == SQLITE_DONE) ? Int(sqlite3_changes(db)) : 0
        }
        return changes
    }

    /// Throwing sibling of queryAll for callers that must surface corrupt rows
    /// (discussion queue) instead of silently dropping them.
    func queryAllThrowing<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer) throws -> T) throws -> [T] {
        var results: [T] = []
        try withCachedStatement(sql) { stmt in
            bind(stmt)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
                }
                results.append(try decode(stmt))
            }
        }
        return results
    }

    func queryOneThrowing<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer) throws -> T) throws -> T? {
        var result: T? = nil
        try withCachedStatement(sql) { stmt in
            bind(stmt)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                result = try decode(stmt)
            } else if rc != SQLITE_DONE {
                throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
            }
        }
        return result
    }

    nonisolated func queryOne<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> T? {
        var result: T? = nil
        try? withCachedStatement(sql) { stmt in
            bind(stmt)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = decode(stmt)
            }
        }
        return result
    }

    nonisolated func queryAll<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> [T] {
        var results: [T] = []
        try? withCachedStatement(sql) { stmt in
            bind(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let decoded = decode(stmt) { results.append(decoded) }
            }
        }
        return results
    }
}

extension HUDStore {
    /// SQLite TRANSIENT marker — instructs SQLite to copy bound text rather
    /// than retain the caller's pointer. Required for any text/blob bind that
    /// outlives the prepare/finalize cycle. Scoped to HUDStore namespace so
    /// it doesn't pollute module globals.
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Live-window SQL fragments
    //
    // These are the exact predicates the corresponding loaders interpolate,
    // exposed as constants for two reasons:
    //  1. The statement cache is keyed by SQL text, so a constant string is
    //     what makes repeat calls a cache hit instead of a recompile.
    //  2. Tests can rebuild the identical query and run EXPLAIN QUERY PLAN
    //     against it, so the indexed plan is asserted on the real SQL.
    //
    // Both deliberately avoid CAST(column AS INTEGER) around the timestamp
    // columns. CAST strips the column's NUMERIC affinity, which forces
    // SQLite into a TEXT-vs-INTEGER comparison and (worse) makes the
    // expression non-sargable, so idx_commitments_status /
    // idx_disc_status_time could not be used. Because created_at /
    // deadline_at / updated_at / source_timestamp / due_at are declared
    // INTEGER, SQLite applies numeric affinity to the bound parameter on
    // its own, so a text-bound "1700000000" and an integer-stored
    // 1700000000 both compare correctly — including rows written with a
    // string timestamp via raw SQL, where the column affinity stores them
    // as integers anyway. Verified by
    // HUDStoreQueryPlanPerfTests.testTextAndIntegerTimestampRowsBothMatch.
    static var commitmentRelevantSinceClause: String {
        """
        (created_at >= ?
         OR (IFNULL(deadline_at, 0) > 0 AND deadline_at >= ?)
         OR updated_at >= ?)
        """
    }

    static var discussionRelevantSinceClause: String {
        """
        (
            source_timestamp >= ?
            OR (IFNULL(due_at, 0) > 0 AND due_at >= ?)
            OR (status = ? AND created_at >= ?)
            OR (status != ? AND updated_at >= ?)
        )
        """
    }

    static func textColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }
}

enum HUDStoreError: Error {
    case openFailed(String)
    case sqlError(String)
    case draftNotFound(id: Int64, chatUsername: String)
}
