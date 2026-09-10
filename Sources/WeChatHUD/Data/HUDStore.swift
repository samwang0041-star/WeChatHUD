import Foundation
import SQLite3

final class HUDStore: ObservableObject {
    private let dbPath: String
    private let cleanupPath: String?
    private var db: OpaquePointer?
    /// Protected by sqlite3_db_mutex. This lets helpers called from an
    /// existing transaction use savepoints without releasing the connection
    /// mutex or attempting a nested BEGIN.
    private var transactionDepth = 0
    var deviceSettings: DeviceSettingsStore?

    init(dbPath: String? = nil, createParentDirectory: Bool = true, cleanupPath: String? = nil) {
        let home = NSHomeDirectory()
        let dir = dbPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? "\(home)/.wechat-hud"
        self.dbPath = dbPath ?? "\(dir)/hud.sqlite3"
        self.cleanupPath = cleanupPath
        if createParentDirectory {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }

    func open() throws {
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HUDStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA busy_timeout=5000")
        // Cap the WAL file so long-running sessions don't accumulate
        // unbounded -wal pages. 256 pages (~1MB) is a good balance between
        // write throughput and disk usage.
        try exec("PRAGMA wal_autocheckpoint=256")
        try createTables()
        try exec("""
            CREATE TABLE IF NOT EXISTS classification_queue (
                msg_uid TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                source_timestamp INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                retry_after INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Seed AI configs to the settings table on first launch. After
        // this runs, every code path reads its AI config from the DB —
        // source files no longer carry endpoint URLs or model names.
        self.seedAISettingsIfMissing()

        // One-time migration: copy legacy whitelist entries into contacts.
        migrateWhitelistToContacts()

        // Best-effort housekeeping. Failures are non-fatal — the app
        // still starts, we just leave old audit rows around.
        try? pruneAIAudit(olderThanDays: 14)

        // Retrospective tab migration + crash recovery (Plan M1.2 / M1.6).
        // Idempotent CREATE TABLE IF NOT EXISTS for 7 tables + indexes.
        // Then mark stale 'running' runs as failed and clean expired undo.
        migrateRetrospective()
        let reapedRuns = reapStaleRuns()
        let reapedUndo = reapStaleUndo(olderThanSeconds: 30 * 60)
        if reapedRuns > 0 || reapedUndo > 0 {
            print("[HUDStore] reaped \(reapedRuns) stale review_runs + \(reapedUndo) old undo entries")
        }

        migrateDailyReportState()

        // User-chosen conversation names. Must exist before any reader
        // resolution runs so `repairStaleChatNames` can consult it.
        migrateChatAliases()
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
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HUDStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
        if let cleanupPath { try? FileManager.default.removeItem(atPath: cleanupPath) }
    }

    deinit { close() }

    // MARK: - Schema

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
                created_at            INTEGER NOT NULL
            )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_recalled_sender ON recalled_messages(sender_username, recalled_at)")
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

        // Migrate: add shared_context and communication_notes if missing
        let colCheck = "PRAGMA table_info(conversation_memory)"
        var colStmt: OpaquePointer?
        var hasSharedContext = false
        if sqlite3_prepare_v2(db, colCheck, -1, &colStmt, nil) == SQLITE_OK {
            while sqlite3_step(colStmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(colStmt, 1))
                if name == "shared_context" { hasSharedContext = true }
            }
        }
        sqlite3_finalize(colStmt)
        if !hasSharedContext {
            try? exec("ALTER TABLE conversation_memory ADD COLUMN shared_context TEXT NOT NULL DEFAULT '[]'")
            try? exec("ALTER TABLE conversation_memory ADD COLUMN communication_notes TEXT NOT NULL DEFAULT '[]'")
        }

        // Migrate: add conversation_phase and stance if missing
        var hasPhase = false
        var phaseStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, colCheck, -1, &phaseStmt, nil) == SQLITE_OK {
            while sqlite3_step(phaseStmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(phaseStmt, 1))
                if name == "conversation_phase" { hasPhase = true }
            }
        }
        sqlite3_finalize(phaseStmt)
        if !hasPhase {
            try? exec("ALTER TABLE conversation_memory ADD COLUMN conversation_phase TEXT NOT NULL DEFAULT ''")
            try? exec("ALTER TABLE conversation_memory ADD COLUMN stance TEXT NOT NULL DEFAULT ''")
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func setSetting(_ key: String, value: String) throws {
        if DeviceSettingsStore.sharedKeys.contains(key), let deviceSettings {
            try deviceSettings.set(key, value: value)
            return
        }
        try exec("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", params: [key, value])
    }

    func getSettingJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let raw = getSetting(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setSettingJSON<T: Encodable>(_ key: String, value: T) throws {
        let data = try JSONEncoder().encode(value)
        try setSetting(key, value: String(data: data, encoding: .utf8)!)
    }

    // MARK: - Whitelist

    func hasWhitelistEntries() -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM whitelist LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func whitelistCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM whitelist", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func getWhitelist() -> [WhitelistEntry] {
        var results: [WhitelistEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT username, display_name, is_group, category, attention_level, added_at, auto_suggested
            FROM whitelist
            ORDER BY CASE attention_level WHEN 'vip' THEN 0 ELSE 1 END, category, display_name
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = WhitelistEntry(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                displayName: String(cString: sqlite3_column_text(stmt, 1)),
                isGroup: sqlite3_column_int(stmt, 2) != 0,
                category: WhitelistCategory(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .other,
                attentionLevel: WhitelistAttentionLevel(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .vip,
                addedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5))),
                autoSuggested: sqlite3_column_int(stmt, 6) != 0
            )
            results.append(entry)
        }
        return results
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

    func removeFromWhitelist(username: String) throws {
        try exec("DELETE FROM whitelist WHERE username=?", params: [username])
        try? deleteContact(username: username)
        // Also clear this chat's baseline — otherwise re-adding the
        // same contact to the whitelist later would reuse the stale
        // watermark and silently swallow every message that arrived
        // while it was off the list.
        try? exec("DELETE FROM sync_state WHERE source_key=?", params: ["wl/\(username)"])
        // Drop any snooze/silence state too: "removed from whitelist"
        // is the strongest reset signal we have, and leaving those
        // behind would make a re-added chat come back already muted.
        try? exec("DELETE FROM chat_actions WHERE chat_username=?", params: [username])
    }

    func isWhitelisted(_ username: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM whitelist WHERE username=?", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func getWhitelistEntry(username: String) -> WhitelistEntry? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT username, display_name, is_group, category, attention_level, added_at, auto_suggested
            FROM whitelist
            WHERE username=?
            LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return WhitelistEntry(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            displayName: String(cString: sqlite3_column_text(stmt, 1)),
            isGroup: sqlite3_column_int(stmt, 2) != 0,
            category: WhitelistCategory(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .other,
            attentionLevel: WhitelistAttentionLevel(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .vip,
            addedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5))),
            autoSuggested: sqlite3_column_int(stmt, 6) != 0
        )
    }

    // MARK: - Sync State

    func getSyncState(_ sourceKey: String) -> (lastLocalId: Int, lastCheckAt: Int)? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT last_local_id, last_check_at FROM sync_state WHERE source_key=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, sourceKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
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

    func getWhitelistCursor(username: String) -> (lastCreateTime: Int, lastLocalId: Int)? {
        getMessageCursor(sourceKey: "wl/\(username)")
    }

    func getAutopilotCursor(username: String) -> (lastCreateTime: Int, lastLocalId: Int)? {
        getMessageCursor(sourceKey: "ap/\(username)")
    }

    private func getMessageCursor(sourceKey key: String) -> (lastCreateTime: Int, lastLocalId: Int)? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT last_create_time, last_local_id FROM sync_state WHERE source_key=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let time = Int(sqlite3_column_int64(stmt, 0))
        let localId = Int(sqlite3_column_int64(stmt, 1))
        // DEFAULT 0 from the migration means "never baselined" — treat it
        // exactly the same as a missing row so migration from old state
        // forces a fresh baseline instead of replaying history.
        // Rows created before the cursor carried local_id have 0 here.
        // Treat that as "all messages in this second were already seen"
        // to avoid a one-time replay of historical same-second rows after
        // upgrading.
        let safeLocalId = localId > 0 ? localId : Int.max
        return time > 0 ? (time, safeLocalId) : nil
    }

    func setWhitelistBaseline(username: String, lastCreateTime: Int) throws {
        try setWhitelistCursor(username: username, lastCreateTime: lastCreateTime, lastLocalId: 0)
    }

    func setWhitelistCursor(username: String, lastCreateTime: Int, lastLocalId: Int) throws {
        try setMessageCursor(sourceKey: "wl/\(username)", lastCreateTime: lastCreateTime, lastLocalId: lastLocalId)
    }

    func setAutopilotCursor(username: String, lastCreateTime: Int, lastLocalId: Int) throws {
        try setMessageCursor(sourceKey: "ap/\(username)", lastCreateTime: lastCreateTime, lastLocalId: lastLocalId)
    }

    private func setMessageCursor(sourceKey key: String, lastCreateTime: Int, lastLocalId: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO sync_state(source_key, last_local_id, last_check_at, last_create_time)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                last_local_id    = excluded.last_local_id,
                last_create_time = excluded.last_create_time,
                last_check_at    = excluded.last_check_at
        """, params: [key, "\(lastLocalId)", "\(now)", "\(lastCreateTime)"])
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
        var result: [String: ChatActionState] = [:]
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT chat_username, silenced_at, snoozed_until FROM chat_actions", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let username = String(cString: sqlite3_column_text(stmt, 0))
            let silenced = Int(sqlite3_column_int64(stmt, 1))
            let snoozed = Int(sqlite3_column_int64(stmt, 2))
            result[username] = ChatActionState(silencedAt: silenced, snoozedUntil: snoozed)
        }
        return result
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
        var result: [IgnoredSenderRule] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT chat_username, chat_name, sender_identifier, sender_username, sender_name, created_at
            FROM ignored_senders
            ORDER BY created_at DESC, chat_name ASC, sender_name ASC
        """, -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rule = IgnoredSenderRule(
                chatUsername: String(cString: sqlite3_column_text(stmt, 0)),
                chatName: String(cString: sqlite3_column_text(stmt, 1)),
                senderIdentifier: String(cString: sqlite3_column_text(stmt, 2)),
                senderUsername: String(cString: sqlite3_column_text(stmt, 3)),
                senderName: String(cString: sqlite3_column_text(stmt, 4)),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
            )
            result.append(rule)
        }
        return result
    }

    func loadIgnoredSenderMap() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for rule in loadIgnoredSenders() {
            map[rule.chatUsername, default: []].insert(rule.senderIdentifier)
        }
        return map
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT 1
            FROM ignored_senders
            WHERE chat_username=? AND sender_identifier=?
            LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, chatUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let identifier = HUDStore.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
        sqlite3_bind_text(stmt, 2, identifier, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
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
        var results: [ScanDismissedEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT username, display_name, dismissed_at
            FROM scan_dismissed ORDER BY dismissed_at DESC
        """, -1, &stmt, nil) == SQLITE_OK else { return results }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(ScanDismissedEntry(
                username: String(cString: sqlite3_column_text(stmt, 0)),
                displayName: String(cString: sqlite3_column_text(stmt, 1)),
                dismissedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
            ))
        }
        return results
    }

    func dismissedScanUsernames() -> Set<String> {
        var result = Set<String>()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT username FROM scan_dismissed", -1, &stmt, nil) == SQLITE_OK else { return result }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return result
    }

    // MARK: - AI: pending_asks

    /// Insert or update an ask. Dedup is by `msg_uid`. The provided
    /// `ask.id` is ignored — SQLite assigns one on insert; on conflict
    /// the existing row is updated in place (preserving its id and
    /// `created_at`, refreshing everything else and `updated_at`).
    func upsertPendingAsk(_ ask: PendingAsk) throws {
        let now = Int(Date().timeIntervalSince1970)
        let createdAt = Int(ask.createdAt.timeIntervalSince1970)
        let deadline: String = ask.deadlineAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
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
                deadline_at    = excluded.deadline_at,
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
    func loadPendingAsks(bucket: AskBucket? = nil, status: AskStatus? = nil) -> [PendingAsk] {
        var sql = """
            SELECT id, msg_uid, chat_username, chat_name, sender_name, raw_text,
                   summary, ask_type, deadline_at, confidence, bucket, status,
                   prompt_version, created_at, updated_at,
                   sender_level, sender_role, urgency
            FROM pending_asks
        """
        var clauses: [String] = []
        var params: [String] = []
        if let bucket = bucket {
            clauses.append("bucket=?")
            params.append(bucket.rawValue)
        }
        if let status = status {
            clauses.append("status=?")
            params.append(status.rawValue)
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY (deadline_at IS NULL OR deadline_at = 0), deadline_at ASC, created_at DESC"

        var results: [PendingAsk] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let deadlineRaw = sqlite3_column_int64(stmt, 8)
            let deadline: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL || deadlineRaw == 0
                ? nil
                : Date(timeIntervalSince1970: TimeInterval(deadlineRaw))
            // Read nullable new columns (15, 16, 17)
            let senderLevelStr: String? = sqlite3_column_type(stmt, 15) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 15))
            let senderRoleStr: String? = sqlite3_column_type(stmt, 16) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 16))
            let urgencyStr: String? = sqlite3_column_type(stmt, 17) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 17))
            let ask = PendingAsk(
                id: sqlite3_column_int64(stmt, 0),
                msgUID: String(cString: sqlite3_column_text(stmt, 1)),
                chatUsername: String(cString: sqlite3_column_text(stmt, 2)),
                chatName: String(cString: sqlite3_column_text(stmt, 3)),
                senderName: String(cString: sqlite3_column_text(stmt, 4)),
                rawText: String(cString: sqlite3_column_text(stmt, 5)),
                summary: String(cString: sqlite3_column_text(stmt, 6)),
                askType: AskType(rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .none,
                deadlineAt: deadline,
                confidence: sqlite3_column_double(stmt, 9),
                bucket: AskBucket(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .review,
                status: AskStatus(rawValue: String(cString: sqlite3_column_text(stmt, 11))) ?? .pending,
                promptVersion: String(cString: sqlite3_column_text(stmt, 12)),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 13))),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 14))),
                senderLevel: senderLevelStr.flatMap { s in s.isEmpty ? nil : AttentionLevel(rawValue: s) },
                senderRole: senderRoleStr.flatMap { s in s.isEmpty ? nil : ContactRole(rawValue: s) },
                urgency: urgencyStr.flatMap { s in s.isEmpty ? nil : AskUrgency(rawValue: s) }
            )
            results.append(ask)
        }
        return results
    }

    /// Has the classifier already produced a row for this message? Used
    /// by `ChatMonitor` to avoid re-classifying messages on every scan.
    func hasPendingAsk(msgUID: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM pending_asks WHERE msg_uid=? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, msgUID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
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
            entry.inputText,
            entry.outputText,
            "\(entry.latencyMs)",
            entry.status.rawValue,
            entry.errorMessage ?? ""
        ])
    }

    /// Most recent audit entries, newest first. For debug viewing only —
    /// the table can grow large so always pass a sane limit.
    func loadRecentAIAudit(
        limit: Int = 100,
        role: AIRole? = nil,
        promptVersionPrefix: String? = nil
    ) -> [AIAuditEntry] {
        var results: [AIAuditEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var sql = """
            SELECT id, ts, role, model, prompt_version, input_text, output_text,
                   latency_ms, status, error_message
            FROM ai_audit
        """
        var clauses: [String] = []
        var params: [String] = []
        if let role {
            clauses.append("role=?")
            params.append(role.rawValue)
        }
        if let promptVersionPrefix, !promptVersionPrefix.isEmpty {
            clauses.append("prompt_version LIKE ?")
            params.append("\(promptVersionPrefix)%")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += """
            ORDER BY ts DESC
            LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int64(stmt, Int32(params.count + 1), Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let errMsg: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 9))
            let entry = AIAuditEntry(
                id: sqlite3_column_int64(stmt, 0),
                ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                role: AIRole(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .classifier,
                model: String(cString: sqlite3_column_text(stmt, 3)),
                promptVersion: String(cString: sqlite3_column_text(stmt, 4)),
                inputText: String(cString: sqlite3_column_text(stmt, 5)),
                outputText: String(cString: sqlite3_column_text(stmt, 6)),
                latencyMs: Int(sqlite3_column_int64(stmt, 7)),
                status: AIAuditStatus(rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .ok,
                errorMessage: (errMsg?.isEmpty == true) ? nil : errMsg
            )
            results.append(entry)
        }
        return results
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT result, expires_at
            FROM analysis_cache
            WHERE chat_username=? AND analysis_type=? AND input_hash=?
            LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, chatUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, analysisType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, inputHash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let expiresAt = sqlite3_column_int64(stmt, 1)
        if expiresAt <= Int64(now.timeIntervalSince1970) {
            try? exec("""
                DELETE FROM analysis_cache
                WHERE chat_username=? AND analysis_type=? AND input_hash=?
            """, params: [chatUsername, analysisType, inputHash])
            return nil
        }
        guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: ptr)
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
            entry.originalOutput,
            entry.userAction ?? "",
            entry.note ?? ""
        ])
    }

    func loadAIFeedback(limit: Int = 200, msgUIDPrefix: String? = nil) -> [AIFeedbackEntry] {
        var results: [AIFeedbackEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var sql = """
            SELECT id, ts, msg_uid, feedback_type, original_output, user_action, note
            FROM ai_feedback
        """
        var params: [String] = []
        if let msgUIDPrefix, !msgUIDPrefix.isEmpty {
            sql += " WHERE msg_uid LIKE ?"
            params.append("\(msgUIDPrefix)%")
        }
        sql += """
            ORDER BY ts DESC
            LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int64(stmt, Int32(params.count + 1), Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let userAction: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 5))
            let note: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 6))
            let entry = AIFeedbackEntry(
                id: sqlite3_column_int64(stmt, 0),
                ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                msgUID: String(cString: sqlite3_column_text(stmt, 2)),
                feedbackType: AIFeedbackType(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .truePositive,
                originalOutput: String(cString: sqlite3_column_text(stmt, 4)),
                userAction: (userAction?.isEmpty == true) ? nil : userAction,
                note: (note?.isEmpty == true) ? nil : note
            )
            results.append(entry)
        }
        return results
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
    /// usable config (post-seed) or the empty struct defaults.
    func loadAIConfig() -> AIConfig {
        getSettingJSON("ai", as: AIConfig.self) ?? AIConfig()
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT username, display_name, attention_level, role, role_note,
                   reply_window_minutes, level_changed_at, created_at, updated_at
            FROM contacts
            WHERE username=?
            LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readContactRow(stmt)
    }

    func loadContacts(level: AttentionLevel? = nil) -> [ContactEntry] {
        var results: [ContactEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var sql = """
            SELECT username, display_name, attention_level, role, role_note,
                   reply_window_minutes, level_changed_at, created_at, updated_at
            FROM contacts
        """
        if level != nil {
            sql += " WHERE attention_level=?"
        }
        sql += " ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        if let level = level {
            sqlite3_bind_text(stmt, 1, level.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readContactRow(stmt))
        }
        return results
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
    func deleteContactAndTracking(username: String) throws {
        try withTransaction {
            try untrackContact(username: username)
            try deleteContact(username: username)
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
        try exec("DELETE FROM sync_state WHERE source_key=?", params: ["wl/\(username)"])
        try exec("DELETE FROM chat_actions WHERE chat_username=?", params: [username])
    }

    func loadVIPUsernames() -> Set<String> {
        var result: Set<String> = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT username FROM contacts WHERE attention_level='vip'", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return result
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

    func loadVIPTraces(vipUsername: String, since: Int = 0, limit: Int = 100) -> [VIPTrace] {
        var results: [VIPTrace] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, vip_username, vip_name, chat_username, chat_name,
                   msg_uid, raw_text, msg_time, batch_id, created_at
            FROM vip_traces
            WHERE vip_username=? AND msg_time >= ?
            ORDER BY msg_time DESC
            LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, vipUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(since))
        sqlite3_bind_int64(stmt, 3, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let batchID: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 8))
            results.append(VIPTrace(
                id: sqlite3_column_int64(stmt, 0),
                vipUsername: String(cString: sqlite3_column_text(stmt, 1)),
                vipName: String(cString: sqlite3_column_text(stmt, 2)),
                chatUsername: String(cString: sqlite3_column_text(stmt, 3)),
                chatName: String(cString: sqlite3_column_text(stmt, 4)),
                msgUID: String(cString: sqlite3_column_text(stmt, 5)),
                rawText: String(cString: sqlite3_column_text(stmt, 6)),
                msgTime: Int(sqlite3_column_int64(stmt, 7)),
                batchID: (batchID?.isEmpty == true) ? nil : batchID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 9)))
            ))
        }
        return results
    }

    func loadUnbatchedVIPTraces(vipUsername: String, limit: Int = 50) -> [VIPTrace] {
        var results: [VIPTrace] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, vip_username, vip_name, chat_username, chat_name,
                   msg_uid, raw_text, msg_time, batch_id, created_at
            FROM vip_traces
            WHERE vip_username=? AND batch_id IS NULL
            ORDER BY msg_time ASC
            LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, vipUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let batchID: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 8))
            results.append(VIPTrace(
                id: sqlite3_column_int64(stmt, 0),
                vipUsername: String(cString: sqlite3_column_text(stmt, 1)),
                vipName: String(cString: sqlite3_column_text(stmt, 2)),
                chatUsername: String(cString: sqlite3_column_text(stmt, 3)),
                chatName: String(cString: sqlite3_column_text(stmt, 4)),
                msgUID: String(cString: sqlite3_column_text(stmt, 5)),
                rawText: String(cString: sqlite3_column_text(stmt, 6)),
                msgTime: Int(sqlite3_column_int64(stmt, 7)),
                batchID: (batchID?.isEmpty == true) ? nil : batchID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 9)))
            ))
        }
        return results
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
        var results: [RecalledMessage] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, msg_uid, sender_username, sender_name, sender_level, sender_role,
                   chat_username, chat_name, chat_type, original_text,
                   sent_at, recalled_at, recall_delay_seconds,
                   ai_reason, ai_intelligence_value, ai_detail,
                   ai_should_notify, ai_notify_level, ai_analyzed_at,
                   created_at
            FROM recalled_messages
            WHERE recalled_at >= ?
            ORDER BY recalled_at DESC
            LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, Int64(since))
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let aiReason: String? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 13))
            let aiValue: String? = sqlite3_column_type(stmt, 14) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 14))
            let aiDetail: String? = sqlite3_column_type(stmt, 15) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 15))
            let aiShouldNotify: Bool? = sqlite3_column_type(stmt, 16) == SQLITE_NULL
                ? nil : sqlite3_column_int(stmt, 16) != 0
            let aiNotifyStr: String? = sqlite3_column_type(stmt, 17) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 17))
            let aiAnalyzedRaw = sqlite3_column_int64(stmt, 18)
            let aiAnalyzedAt: Date? = sqlite3_column_type(stmt, 18) == SQLITE_NULL || aiAnalyzedRaw == 0
                ? nil : Date(timeIntervalSince1970: TimeInterval(aiAnalyzedRaw))

            results.append(RecalledMessage(
                id: sqlite3_column_int64(stmt, 0),
                msgUID: String(cString: sqlite3_column_text(stmt, 1)),
                senderUsername: String(cString: sqlite3_column_text(stmt, 2)),
                senderName: String(cString: sqlite3_column_text(stmt, 3)),
                senderLevel: AttentionLevel(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .stranger,
                senderRole: ContactRole(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .acquaintance,
                chatUsername: String(cString: sqlite3_column_text(stmt, 6)),
                chatName: String(cString: sqlite3_column_text(stmt, 7)),
                chatType: ChatType(rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .privateChat,
                originalText: String(cString: sqlite3_column_text(stmt, 9)),
                sentAt: Int(sqlite3_column_int64(stmt, 10)),
                recalledAt: Int(sqlite3_column_int64(stmt, 11)),
                recallDelaySeconds: Int(sqlite3_column_int64(stmt, 12)),
                aiReason: (aiReason?.isEmpty == true) ? nil : aiReason,
                aiIntelligenceValue: (aiValue?.isEmpty == true) ? nil : aiValue,
                aiDetail: (aiDetail?.isEmpty == true) ? nil : aiDetail,
                aiShouldNotify: aiShouldNotify,
                aiNotifyLevel: aiNotifyStr.flatMap { NotifyLevel(rawValue: $0) },
                aiAnalyzedAt: aiAnalyzedAt,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 19)))
            ))
        }
        return results
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
        let deadlineStr = deadlineAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
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
                deadline_at    = excluded.deadline_at,
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
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
            clauses.append("""
                (status IN (?, ?)
                 OR CAST(created_at AS INTEGER) >= ?
                 OR (
                    CAST(IFNULL(deadline_at, 0) AS INTEGER) > 0
                    AND CAST(deadline_at AS INTEGER) >= ?
                 ))
                """)
            params.append(CommitmentStatus.pending.rawValue)
            params.append(CommitmentStatus.overdue.rawValue)
            params.append("\(relevantSince)")
            params.append("\(relevantSince)")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY COALESCE(deadline_at, 9999999999) ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
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
        let dueStr = dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        try exec("""
            INSERT OR IGNORE INTO discussion_items(
                chat_username, chat_name, kind, owner, content, detail,
                anchor_msg_uid, source_timestamp, due_at, status,
                confidence, prompt_version, created_at, updated_at
            )
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, params: [
            chatUsername, chatName, kind.rawValue, owner.rawValue,
            content, detail ?? "",
            anchorMsgUID, "\(sourceTimestamp)", dueStr,
            DiscussionItemStatus.pending.rawValue,
            String(confidence), promptVersion,
            "\(now)", "\(now)"
        ])
        return sqlite3_changes(db) > 0
    }

    /// Load discussion items with optional filters.
    /// - Parameters:
    ///   - chatUsername: if set, only items from that chat
    ///   - status: if set, only items in that status (default shows all)
    ///   - excludingStatus: if set, drop that status (used for history)
    ///   - id: if set, only that row
    ///   - sinceTimestamp: if set, only items with `source_timestamp >= this`
    ///   - relevantSince: if set, keep pending rows plus history whose source or due date is on/after this
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

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
            clauses.append("""
                (status=?
                 OR CAST(source_timestamp AS INTEGER) >= ?
                 OR (
                    CAST(IFNULL(due_at, 0) AS INTEGER) > 0
                    AND CAST(due_at AS INTEGER) >= ?
                 ))
                """)
            params.append(DiscussionItemStatus.pending.rawValue)
            params.append("\(relevantSince)")
            params.append("\(relevantSince)")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY source_timestamp DESC"
        if let limit = limit { sql += " LIMIT \(limit)" }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
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
        if let relevantSince {
            return results.filter { DiscussionLiveWindow.contains($0, cutoff: relevantSince) }
        }
        return results
    }

    func loadDiscussionItem(id: Int64) -> DiscussionItem? {
        loadDiscussionItems(id: id, limit: 1).first
    }

    func updateDiscussionItemStatus(id: Int64, status: DiscussionItemStatus) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE discussion_items SET status=?, updated_at=? WHERE id=?
        """, params: [status.rawValue, "\(now)", "\(id)"])
    }

    /// Corrects AI-assigned responsibility without changing the item's status.
    /// Returns false when the row no longer exists.
    @discardableResult
    func updateDiscussionItemOwner(id: Int64, owner: DiscussionItemOwner) throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            UPDATE discussion_items SET owner=?, updated_at=? WHERE id=?
        """, params: [owner.rawValue, "\(now)", "\(id)"])
        return sqlite3_changes(db) > 0
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
        let dueStr = dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        try exec("""
            UPDATE discussion_items SET content=?, owner=?, due_at=?, updated_at=? WHERE id=?
        """, params: [content, owner.rawValue, dueStr, "\(now)", "\(id)"])
        return sqlite3_changes(db) > 0
    }

    /// The most recent `source_timestamp` extracted for a chat — used
    /// by the tracker to skip messages it already analysed.
    func latestDiscussionSourceTimestamp(chatUsername: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT MAX(source_timestamp) FROM discussion_items WHERE chat_username=?",
            -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, chatUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM reply_drafts", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func loadDrafts() -> [(id: Int64, chatUsername: String, chatName: String, text: String, sendAt: Date?, createdAt: Date)] {
        var results: [(id: Int64, chatUsername: String, chatName: String, text: String, sendAt: Date?, createdAt: Date)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT id, chat_username, chat_name, text, send_at, created_at
            FROM reply_drafts ORDER BY created_at DESC
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sendAtTs = sqlite3_column_int64(stmt, 4)
            results.append((
                id: sqlite3_column_int64(stmt, 0),
                chatUsername: String(cString: sqlite3_column_text(stmt, 1)),
                chatName: String(cString: sqlite3_column_text(stmt, 2)),
                text: String(cString: sqlite3_column_text(stmt, 3)),
                sendAt: sendAtTs > 0 ? Date(timeIntervalSince1970: Double(sendAtTs)) : nil,
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)))
            ))
        }
        return results
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT chat_username, summary, key_topics, pending_items, shared_context, communication_notes, mood_trend, conversation_phase, stance, message_count_7d, last_updated
            FROM conversation_memory WHERE chat_username=?
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, chatUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let topicsStr = String(cString: sqlite3_column_text(stmt, 2))
        let pendingStr = String(cString: sqlite3_column_text(stmt, 3))
        let sharedStr = String(cString: sqlite3_column_text(stmt, 4))
        let commStr = String(cString: sqlite3_column_text(stmt, 5))
        let topics = (try? JSONSerialization.jsonObject(with: Data(topicsStr.utf8)) as? [String]) ?? []
        let pending = (try? JSONSerialization.jsonObject(with: Data(pendingStr.utf8)) as? [String]) ?? []
        let shared = (try? JSONSerialization.jsonObject(with: Data(sharedStr.utf8)) as? [String]) ?? []
        let comm = (try? JSONSerialization.jsonObject(with: Data(commStr.utf8)) as? [String]) ?? []

        // Phase and stance columns (7, 8) — may be NULL for old rows
        let phase: String
        if let p = sqlite3_column_text(stmt, 7) { phase = String(cString: p) } else { phase = "" }
        let stanceVal: String
        if let s = sqlite3_column_text(stmt, 8) { stanceVal = String(cString: s) } else { stanceVal = "" }

        return ConversationMemory(
            chatUsername: String(cString: sqlite3_column_text(stmt, 0)),
            summary: String(cString: sqlite3_column_text(stmt, 1)),
            keyTopics: topics,
            pendingItems: pending,
            sharedContext: shared,
            communicationNotes: comm,
            moodTrend: String(cString: sqlite3_column_text(stmt, 6)),
            conversationPhase: phase,
            stance: stanceVal,
            messageCount7d: Int(sqlite3_column_int(stmt, 9)),
            lastUpdated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10)))
        )
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT chat_username, work_hours, evening, weekend, late_night, silent_at_night, sample_count, last_updated
            FROM reply_timing_profiles WHERE chat_username=?
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, chatUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let decode: (Int32) -> ReplyTimingProfile.DelayDistribution = { col in
            let str = String(cString: sqlite3_column_text(stmt, col))
            return (try? JSONDecoder().decode(ReplyTimingProfile.DelayDistribution.self, from: Data(str.utf8)))
                ?? .zero
        }

        let isSilent = sqlite3_column_int(stmt, 5) != 0
        return ReplyTimingProfile(
            chatUsername: String(cString: sqlite3_column_text(stmt, 0)),
            workHours: decode(1),
            evening: decode(2),
            weekend: decode(3),
            lateNight: decode(4),
            silentAtNight: isSilent,
            lateNightReplyRate: isSilent ? 0.0 : 1.0,  // approximate from boolean
            sampleCount: Int(sqlite3_column_int(stmt, 6)),
            lastUpdated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)))
        )
    }

    // MARK: - Autopilot

    func startAutopilotSession() throws -> Int64 {
        let now = Int(Date().timeIntervalSince1970)
        try exec("INSERT INTO autopilot_sessions(started_at) VALUES(?)", params: [String(now)])
        return sqlite3_last_insert_rowid(db)
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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT id, started_at, ended_at, total_handled, total_pending, total_sent
            FROM autopilot_sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return AutopilotSession(
            id: sqlite3_column_int64(stmt, 0),
            startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
            endedAt: nil,
            totalHandled: Int(sqlite3_column_int(stmt, 3)),
            totalPending: Int(sqlite3_column_int(stmt, 4)),
            totalSent: Int(sqlite3_column_int(stmt, 5))
        )
    }

    func insertAutopilotLog(_ entry: AutopilotLogEntry) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO autopilot_log(session_id, chat_username, chat_name, sender_username, sender_name,
                trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level, action, ai_reasoning, sent_at, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HUDStoreError.sqlError("prepare autopilot_log insert: \(String(cString: sqlite3_errmsg(db)))")
        }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, entry.sessionId)
        sqlite3_bind_text(stmt, 2, entry.chatUsername, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 3, entry.chatName, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 4, entry.senderUsername, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 5, entry.senderName, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 6, entry.triggerMsgUID, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 7, entry.triggerText, -1, TRANSIENT)
        if let reply = entry.generatedReply {
            sqlite3_bind_text(stmt, 8, reply, -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_double(stmt, 9, entry.confidence)
        sqlite3_bind_text(stmt, 10, entry.riskLevel.rawValue, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 11, entry.action.rawValue, -1, TRANSIENT)
        if let reasoning = entry.aiReasoning {
            sqlite3_bind_text(stmt, 12, reasoning, -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        if let sentAt = entry.sentAt {
            sqlite3_bind_int64(stmt, 13, Int64(sentAt.timeIntervalSince1970))
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        sqlite3_bind_int64(stmt, 14, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HUDStoreError.sqlError("step autopilot_log insert: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func loadAutopilotLog(sessionId: Int64, limit: Int = 50) -> [AutopilotLogEntry] {
        var results: [AutopilotLogEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT id, session_id, chat_username, chat_name, sender_username, sender_name,
                   trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level,
                   action, ai_reasoning, sent_at, created_at
            FROM autopilot_log WHERE session_id=? ORDER BY created_at DESC LIMIT ?
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, sessionId)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let genReply = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let reasoning = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 12)) : nil
            let sentAt = sqlite3_column_type(stmt, 13) != SQLITE_NULL
                ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 13)))
                : nil
            results.append(AutopilotLogEntry(
                id: sqlite3_column_int64(stmt, 0),
                sessionId: sqlite3_column_int64(stmt, 1),
                chatUsername: String(cString: sqlite3_column_text(stmt, 2)),
                chatName: String(cString: sqlite3_column_text(stmt, 3)),
                senderUsername: String(cString: sqlite3_column_text(stmt, 4)),
                senderName: String(cString: sqlite3_column_text(stmt, 5)),
                triggerMsgUID: String(cString: sqlite3_column_text(stmt, 6)),
                triggerText: String(cString: sqlite3_column_text(stmt, 7)),
                generatedReply: genReply,
                confidence: sqlite3_column_double(stmt, 9),
                riskLevel: AutopilotRisk(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .low,
                action: AutopilotAction(rawValue: String(cString: sqlite3_column_text(stmt, 11))) ?? .skipped,
                aiReasoning: reasoning,
                sentAt: sentAt,
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 14)))
            ))
        }
        return results
    }

    func loadPendingAutopilotItems(sessionId: Int64) -> [AutopilotLogEntry] {
        var results: [AutopilotLogEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT id, session_id, chat_username, chat_name, sender_username, sender_name,
                   trigger_msg_uid, trigger_text, generated_reply, confidence, risk_level,
                   action, ai_reasoning, sent_at, created_at
            FROM autopilot_log WHERE session_id=? AND action='pending' ORDER BY created_at DESC
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, sessionId)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let genReply = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let reasoning = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 12)) : nil
            let sentAt = sqlite3_column_type(stmt, 13) != SQLITE_NULL
                ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 13)))
                : nil
            results.append(AutopilotLogEntry(
                id: sqlite3_column_int64(stmt, 0),
                sessionId: sqlite3_column_int64(stmt, 1),
                chatUsername: String(cString: sqlite3_column_text(stmt, 2)),
                chatName: String(cString: sqlite3_column_text(stmt, 3)),
                senderUsername: String(cString: sqlite3_column_text(stmt, 4)),
                senderName: String(cString: sqlite3_column_text(stmt, 5)),
                triggerMsgUID: String(cString: sqlite3_column_text(stmt, 6)),
                triggerText: String(cString: sqlite3_column_text(stmt, 7)),
                generatedReply: genReply,
                confidence: sqlite3_column_double(stmt, 9),
                riskLevel: AutopilotRisk(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .low,
                action: AutopilotAction(rawValue: String(cString: sqlite3_column_text(stmt, 11))) ?? .pending,
                aiReasoning: reasoning,
                sentAt: sentAt,
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 14)))
            ))
        }
        return results
    }

    func updateAutopilotLogAction(id: Int64, action: AutopilotAction) throws {
        try exec("UPDATE autopilot_log SET action=? WHERE id=?", params: [action.rawValue, String(id)])
    }

    func markAutopilotLogSent(id: Int64) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("UPDATE autopilot_log SET action='sent', sent_at=? WHERE id=?", params: [String(now), String(id)])
    }

    func upsertPendingSend(_ item: PendingSend, sessionId: Int64) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
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
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HUDStoreError.sqlError("prepare autopilot_pending_sends upsert: \(String(cString: sqlite3_errmsg(db)))")
        }
        let TRANSIENT = HUDStore.sqliteTransient
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, TRANSIENT)
        sqlite3_bind_int64(stmt, 2, sessionId)
        sqlite3_bind_text(stmt, 3, item.chatUsername, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 4, item.chatName, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 5, item.senderName, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 6, item.replyText, -1, TRANSIENT)
        sqlite3_bind_double(stmt, 7, item.confidence)
        sqlite3_bind_text(stmt, 8, item.risk.rawValue, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 9, item.reasoning, -1, TRANSIENT)
        sqlite3_bind_int(stmt, 10, Int32(item.styleScore))
        sqlite3_bind_int64(stmt, 11, Int64(item.scheduledSendTime.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 12, Int64(item.createdAt.timeIntervalSince1970))
        if let peerLastMessage = item.peerLastMessage {
            sqlite3_bind_text(stmt, 13, peerLastMessage, -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        if let topic = item.topic {
            sqlite3_bind_text(stmt, 14, topic, -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        sqlite3_bind_int(stmt, 15, Int32(item.autoSendAttempts))
        if let manualOnlyReason = item.manualOnlyReason {
            sqlite3_bind_text(stmt, 16, manualOnlyReason, -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 16)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HUDStoreError.sqlError("step autopilot_pending_sends upsert: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func loadPendingSends(sessionId: Int64) -> [PendingSend] {
        var results: [PendingSend] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT id, chat_username, chat_name, sender_name, reply_text,
                   confidence, risk_level, reasoning, style_score, scheduled_send_at,
                   created_at, peer_last_message, topic, auto_send_attempts, manual_only_reason
            FROM autopilot_pending_sends
            WHERE session_id=?
            ORDER BY scheduled_send_at ASC, created_at ASC
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, sessionId)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idString = HUDStore.textColumn(stmt, 0)
            guard let id = UUID(uuidString: idString) else { continue }
            let risk = AutopilotRisk(rawValue: HUDStore.textColumn(stmt, 6)) ?? .low
            let peerLastMessage = sqlite3_column_type(stmt, 11) != SQLITE_NULL ? HUDStore.textColumn(stmt, 11) : nil
            let topic = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? HUDStore.textColumn(stmt, 12) : nil
            let manualOnlyReason = sqlite3_column_type(stmt, 14) != SQLITE_NULL ? HUDStore.textColumn(stmt, 14) : nil
            results.append(PendingSend(
                id: id,
                chatUsername: HUDStore.textColumn(stmt, 1),
                chatName: HUDStore.textColumn(stmt, 2),
                senderName: HUDStore.textColumn(stmt, 3),
                replyText: HUDStore.textColumn(stmt, 4),
                confidence: sqlite3_column_double(stmt, 5),
                risk: risk,
                reasoning: HUDStore.textColumn(stmt, 7),
                styleScore: Int(sqlite3_column_int(stmt, 8)),
                scheduledSendTime: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9))),
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10))),
                peerLastMessage: peerLastMessage,
                topic: topic,
                autoSendAttempts: Int(sqlite3_column_int(stmt, 13)),
                manualOnlyReason: manualOnlyReason
            ))
        }
        return results
    }

    func deletePendingSend(id: UUID) throws {
        try exec("DELETE FROM autopilot_pending_sends WHERE id=?", params: [id.uuidString])
    }

    func clearPendingSends(sessionId: Int64) throws {
        try exec("DELETE FROM autopilot_pending_sends WHERE session_id=?", params: [String(sessionId)])
    }

    func enqueueAutopilotInbound(_ msg: AutopilotService.InboundMessage) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT OR IGNORE INTO autopilot_inbound_queue(
                msg_uid, chat_username, chat_name, sender_username, sender_name, text,
                is_group, is_at_mention, attention_level, contact_role, msg_timestamp,
                message_type, app_type, created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HUDStoreError.sqlError("prepare autopilot_inbound_queue insert: \(String(cString: sqlite3_errmsg(db)))")
        }
        let TRANSIENT = HUDStore.sqliteTransient
        sqlite3_bind_text(stmt, 1, msg.msgUID, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, msg.chatUsername, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 3, msg.chatName, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 4, msg.senderUsername, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 5, msg.senderName, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 6, msg.text, -1, TRANSIENT)
        sqlite3_bind_int(stmt, 7, msg.isGroup ? 1 : 0)
        sqlite3_bind_int(stmt, 8, msg.isAtMention ? 1 : 0)
        sqlite3_bind_text(stmt, 9, msg.attentionLevel.rawValue, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 10, msg.contactRole.rawValue, -1, TRANSIENT)
        sqlite3_bind_int64(stmt, 11, Int64(msg.timestamp))
        sqlite3_bind_int(stmt, 12, Int32(msg.messageType))
        sqlite3_bind_int(stmt, 13, Int32(msg.appType))
        sqlite3_bind_int64(stmt, 14, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HUDStoreError.sqlError("step autopilot_inbound_queue insert: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func loadPendingAutopilotInbound(limit: Int = 200) -> [AutopilotService.InboundMessage] {
        var results: [AutopilotService.InboundMessage] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT msg_uid, chat_username, chat_name, sender_username, sender_name, text,
                   is_group, is_at_mention, attention_level, contact_role, msg_timestamp,
                   message_type, app_type
            FROM autopilot_inbound_queue
            ORDER BY msg_timestamp ASC, created_at ASC
            LIMIT ?
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let attention = AttentionLevel(rawValue: HUDStore.textColumn(stmt, 8)) ?? .stranger
            let role = ContactRole(rawValue: HUDStore.textColumn(stmt, 9)) ?? .acquaintance
            results.append(AutopilotService.InboundMessage(
                msgUID: HUDStore.textColumn(stmt, 0),
                chatUsername: HUDStore.textColumn(stmt, 1),
                chatName: HUDStore.textColumn(stmt, 2),
                senderUsername: HUDStore.textColumn(stmt, 3),
                senderName: HUDStore.textColumn(stmt, 4),
                text: HUDStore.textColumn(stmt, 5),
                isGroup: sqlite3_column_int(stmt, 6) != 0,
                isAtMention: sqlite3_column_int(stmt, 7) != 0,
                attentionLevel: attention,
                contactRole: role,
                timestamp: Int(sqlite3_column_int64(stmt, 10)),
                messageType: Int(sqlite3_column_int(stmt, 11)),
                appType: Int(sqlite3_column_int(stmt, 12))
            ))
        }
        return results
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
        var results: [AutopilotSession] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT id, started_at, ended_at, total_handled, total_pending, total_sent
            FROM autopilot_sessions ORDER BY id DESC LIMIT ?
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let endedAt = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))
                : nil
            results.append(AutopilotSession(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                endedAt: endedAt,
                totalHandled: Int(sqlite3_column_int(stmt, 3)),
                totalPending: Int(sqlite3_column_int(stmt, 4)),
                totalSent: Int(sqlite3_column_int(stmt, 5))
            ))
        }
        return results
    }

    func clearAutopilotHistory() throws {
        try withTransaction {
            guard currentAutopilotSession() == nil else {
                throw NSError(domain: "WeChatHUD", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "请先结束自动托管，再清除历史记录。"])
            }
            // History maintenance must never discard queued work or pending sends.
            try exec("DELETE FROM autopilot_log")
            try exec("DELETE FROM autopilot_sessions WHERE ended_at IS NOT NULL")
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
        let sql = "SELECT username, display_name, relationship, hierarchy, tone_preference, context, confidence, user_note, user_edited, inferred_at, updated_at FROM relationship_profiles WHERE username = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRelationshipRow(stmt)
    }

    func loadAllRelationshipProfiles() -> [RelationshipProfile] {
        let sql = "SELECT username, display_name, relationship, hierarchy, tone_preference, context, confidence, user_note, user_edited, inferred_at, updated_at FROM relationship_profiles ORDER BY updated_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [RelationshipProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(parseRelationshipRow(stmt))
        }
        return results
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
        RelationshipProfile(
            username: String(cString: sqlite3_column_text(stmt, 0)),
            displayName: String(cString: sqlite3_column_text(stmt, 1)),
            relationship: String(cString: sqlite3_column_text(stmt, 2)),
            hierarchy: RelationshipProfile.Hierarchy(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .peer,
            tonePreference: RelationshipProfile.TonePreference(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .formal,
            context: {
                let s = String(cString: sqlite3_column_text(stmt, 5))
                return s.isEmpty ? nil : s
            }(),
            confidence: sqlite3_column_double(stmt, 6),
            userNote: {
                let s = String(cString: sqlite3_column_text(stmt, 7))
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
                INSERT INTO classification_queue(msg_uid,payload,source_timestamp)
                SELECT ?,?,? WHERE NOT EXISTS(
                    SELECT 1 FROM classification_queue WHERE msg_uid=?
                )
            """, params: [message.id, payload, String(message.createTime), message.id])
        }
    }

    func pendingClassificationMessages(limit: Int = 40) -> [MessageInfo] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT payload FROM classification_queue WHERE retry_after <= ? ORDER BY source_timestamp, msg_uid LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 200))))
        var messages: [MessageInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0) else { continue }
            let data = Data(String(cString: text).utf8)
            if let message = try? JSONDecoder().decode(MessageInfo.self, from: data) { messages.append(message) }
        }
        return messages
    }

    func classificationQueueCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM classification_queue", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
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

    private func exec(_ sql: String, params: [String] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        // Loop to consume any result rows (e.g. PRAGMA journal_mode returns SQLITE_ROW).
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            if rc == SQLITE_ROW { continue }
            throw HUDStoreError.sqlError(String(cString: sqlite3_errmsg(db)))
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
    func withDatabaseMutex<T>(_ body: () throws -> T) throws -> T {
        guard let db, let mutex = sqlite3_db_mutex(db) else {
            throw HUDStoreError.sqlError("Database is not open")
        }
        sqlite3_mutex_enter(mutex)
        defer { sqlite3_mutex_leave(mutex) }
        return try body()
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

    /// Best-effort SQL exec used by retrospective migration (mirrors the
    /// existing private exec but swallows errors, matching the codebase's
    /// best-effort `try? exec("ALTER TABLE …")` pattern).
    nonisolated func execIgnoringError(_ sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    typealias SQLiteBinder = (OpaquePointer?) -> Void

    @discardableResult
    nonisolated func executeInsert(_ sql: String, bind: SQLiteBinder) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return nil
        }
        bind(stmt)
        let rowID: Int? = (sqlite3_step(stmt) == SQLITE_DONE) ? Int(sqlite3_last_insert_rowid(db)) : nil
        sqlite3_finalize(stmt)
        return rowID
    }

    @discardableResult
    nonisolated func executeUpdate(_ sql: String, bind: SQLiteBinder) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return 0
        }
        bind(stmt)
        let changes = (sqlite3_step(stmt) == SQLITE_DONE) ? Int(sqlite3_changes(db)) : 0
        sqlite3_finalize(stmt)
        return changes
    }

    nonisolated func queryOne<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> T? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return nil
        }
        bind(stmt)
        var result: T? = nil
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = decode(stmt)
        }
        sqlite3_finalize(stmt)
        return result
    }

    nonisolated func queryAll<T>(_ sql: String, bind: SQLiteBinder, decode: (OpaquePointer?) -> T?) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return []
        }
        bind(stmt)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let decoded = decode(stmt) { results.append(decoded) }
        }
        sqlite3_finalize(stmt)
        return results
    }
}

extension HUDStore {
    /// SQLite TRANSIENT marker — instructs SQLite to copy bound text rather
    /// than retain the caller's pointer. Required for any text/blob bind that
    /// outlives the prepare/finalize cycle. Scoped to HUDStore namespace so
    /// it doesn't pollute module globals.
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
