import Foundation
import SQLite3

final class HUDStore: ObservableObject {
    private let dbPath: String
    private var db: OpaquePointer?

    init(dbPath: String? = nil) {
        let home = NSHomeDirectory()
        let dir = dbPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? "\(home)/.wechat-hud"
        self.dbPath = dbPath ?? "\(dir)/hud.sqlite3"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func open() throws {
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HUDStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA busy_timeout=5000")
        try createTables()
    }

    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
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
    }

    // MARK: - Settings

    func getSetting(_ key: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func setSetting(_ key: String, value: String) throws {
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

    func getWhitelist() -> [WhitelistEntry] {
        var results: [WhitelistEntry] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT username, display_name, is_group, category, added_at, auto_suggested FROM whitelist ORDER BY category, display_name", -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = WhitelistEntry(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                displayName: String(cString: sqlite3_column_text(stmt, 1)),
                isGroup: sqlite3_column_int(stmt, 2) != 0,
                category: WhitelistCategory(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .other,
                addedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4))),
                autoSuggested: sqlite3_column_int(stmt, 5) != 0
            )
            results.append(entry)
        }
        return results
    }

    func addToWhitelist(username: String, displayName: String, isGroup: Bool, category: WhitelistCategory) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT OR REPLACE INTO whitelist(username, display_name, is_group, category, added_at, auto_suggested)
            VALUES(?,?,?,?,?,0)
        """, params: [username, displayName, isGroup ? "1" : "0", category.rawValue, "\(now)"])
    }

    func removeFromWhitelist(username: String) throws {
        try exec("DELETE FROM whitelist WHERE username=?", params: [username])
    }

    func isWhitelisted(_ username: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM whitelist WHERE username=?", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
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

    // MARK: - Helpers

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
}

enum HUDStoreError: Error {
    case openFailed(String)
    case sqlError(String)
}
