import Foundation
import SQLite3

/// Versioned, up-only schema migrations. `CREATE TABLE IF NOT EXISTS` still
/// bootstraps a new file; this records `PRAGMA user_version` so later
/// columns/tables are applied exactly once and can be replayed safely.
enum SchemaMigrator {
    static let currentVersion = 2

    static func apply(to store: HUDStore) throws {
        if store.schemaUserVersion() < 1 {
            store.setSchemaUserVersion(1)
        }
        if store.schemaUserVersion() < 2 {
            try store.migrateToV2RelationshipRadar()
            store.setSchemaUserVersion(2)
        }
        if store.schemaUserVersion() < currentVersion {
            store.setSchemaUserVersion(currentVersion)
        }
    }
}

extension HUDStore {
    func schemaUserVersion() -> Int {
        queryOne("PRAGMA user_version", bind: { _ in }, decode: { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }) ?? 0
    }

    func setSchemaUserVersion(_ version: Int) {
        try? execProbeThrowing("PRAGMA user_version = \(max(0, version))")
    }

    /// Relationship Radar storage: daily fact points + computed snapshots.
    func migrateToV2RelationshipRadar() throws {
        try execProbeThrowing("""
            CREATE TABLE IF NOT EXISTS chat_insight_daily (
                chat_username   TEXT NOT NULL,
                day             TEXT NOT NULL,
                headline        TEXT NOT NULL DEFAULT '',
                topics_json     TEXT NOT NULL DEFAULT '[]',
                decisions_json  TEXT NOT NULL DEFAULT '[]',
                waiting_count   INTEGER NOT NULL DEFAULT 0,
                overall_mood    TEXT NOT NULL DEFAULT '',
                message_count   INTEGER NOT NULL DEFAULT 0,
                my_message_count INTEGER NOT NULL DEFAULT 0,
                insight         TEXT NOT NULL DEFAULT '',
                created_at      INTEGER NOT NULL,
                PRIMARY KEY (chat_username, day)
            )
        """)
        try execProbeThrowing("""
            CREATE TABLE IF NOT EXISTS relationship_radar (
                chat_username   TEXT PRIMARY KEY,
                generated_at    INTEGER NOT NULL,
                window_days     INTEGER NOT NULL,
                payload         TEXT NOT NULL
            )
        """)
        try execProbeThrowing(
            "CREATE INDEX IF NOT EXISTS idx_chat_insight_daily_day ON chat_insight_daily(day DESC)"
        )
    }
}
