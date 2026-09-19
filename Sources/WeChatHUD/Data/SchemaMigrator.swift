import Foundation
import SQLite3

/// Versioned, up-only schema migrations. `CREATE TABLE IF NOT EXISTS` still
/// bootstraps a new file; this records `PRAGMA user_version` so later
/// columns/tables are applied exactly once and can be replayed safely.
enum SchemaMigrator {
    static let currentVersion = 3

    /// Runs immediately after `createTables()`. Relationship-radar tables are
    /// created here; retrospective tables do not exist yet.
    static func apply(to store: HUDStore) throws {
        if store.schemaUserVersion() < 1 {
            store.setSchemaUserVersion(1)
        }
        if store.schemaUserVersion() < 2 {
            try store.migrateToV2RelationshipRadar()
            store.setSchemaUserVersion(2)
        }
    }

    /// Runs after `migrateRetrospective()` so review/red-banner indexes have
    /// tables to attach to. Idempotent for stores already at `currentVersion`.
    static func applyAfterRetrospective(to store: HUDStore) throws {
        if store.schemaUserVersion() < 3 {
            try store.migrateToV3RetrospectiveIndexes()
            store.setSchemaUserVersion(3)
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

    /// Retrospective query indexes called out by the evolution plan (P2):
    /// red-banner lookups by todo + time, and pending todos by status/created.
    ///
    /// Best-effort on purpose. Both tables are created by
    /// `migrateRetrospective()` with `execIgnoringError`, so "the table is not
    /// there" is a state this function can legitimately meet — and a hard
    /// `try` here made it fatal: the throw propagated out of `store.open()`,
    /// which AppDelegate answers with a modal and `NSApp.terminate`, on every
    /// launch. `user_version` is only written after success, so a failed pass
    /// retried forever looked like a bricked app, not a missing index.
    func migrateToV3RetrospectiveIndexes() throws {
        for sql in [
            "CREATE INDEX IF NOT EXISTS idx_red_banner_dismissals_todo_created ON red_banner_dismissals(todo_id, created_at)",
            "CREATE INDEX IF NOT EXISTS idx_review_todos_status_created ON review_todos(status, created_at)",
        ] where (try? execProbeThrowing(sql)) == nil {
            print("[WCHUD] hud.sqlite3: index unavailable — retrospective queries stay unindexed: \(sql)")
        }
    }
}
