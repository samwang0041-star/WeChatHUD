import Foundation
import SQLite3

extension HUDStore {

    func migrateDailyReportState() {
        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS daily_report_state (
                date_key      TEXT NOT NULL,
                item_id       TEXT NOT NULL,
                state         TEXT NOT NULL CHECK(state IN ('completed','dismissed','snoozed')),
                completed_at  INTEGER,
                dismissed_at  INTEGER,
                snoozed_until INTEGER,
                updated_at    INTEGER NOT NULL,
                PRIMARY KEY(date_key, item_id)
            )
        """)
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_daily_report_state_date ON daily_report_state(date_key)")

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS daily_report_snapshots (
                date_key        TEXT PRIMARY KEY,
                snapshot_json   TEXT NOT NULL,
                created_at      INTEGER NOT NULL
            )
        """)
    }

    func upsertDailyReportCommandState(_ state: DailyReportCommandState) throws {
        let sql = """
            INSERT INTO daily_report_state
                (date_key, item_id, state, completed_at, dismissed_at, snoozed_until, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key, item_id) DO UPDATE SET
                state = excluded.state,
                completed_at = excluded.completed_at,
                dismissed_at = excluded.dismissed_at,
                snoozed_until = excluded.snoozed_until,
                updated_at = excluded.updated_at
        """
        let params: [String] = [
            state.dateKey,
            state.itemID,
            state.state.rawValue,
            state.completedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            state.dismissedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            state.snoozedUntil.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            String(Int(state.updatedAt.timeIntervalSince1970))
        ]
        _ = executeUpdate(sql) { stmt in
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.sqliteTransient)
            }
        }
    }

    func loadDailyReportCommandStates(dateKey: String) -> [DailyReportCommandState] {
        queryAll("""
            SELECT date_key, item_id, state, completed_at, dismissed_at, snoozed_until, updated_at
            FROM daily_report_state
            WHERE date_key = ?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, dateKey, -1, Self.sqliteTransient)
        }, decode: { stmt in
            guard let dateKey = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let itemID = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let stateRaw = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let state = DailyReportCommandStateValue(rawValue: stateRaw)
            else { return nil }

            let completedAt = sqlite3_column_int64(stmt, 3)
            let dismissedAt = sqlite3_column_int64(stmt, 4)
            let snoozedUntil = sqlite3_column_int64(stmt, 5)
            let updatedAt = sqlite3_column_int64(stmt, 6)

            return DailyReportCommandState(
                dateKey: dateKey,
                itemID: itemID,
                state: state,
                completedAt: completedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(completedAt)) : nil,
                dismissedAt: dismissedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(dismissedAt)) : nil,
                snoozedUntil: snoozedUntil > 0 ? Date(timeIntervalSince1970: TimeInterval(snoozedUntil)) : nil,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
            )
        })
    }

    func clearDailyReportCommandState(dateKey: String, itemID: String) throws {
        _ = executeUpdate("DELETE FROM daily_report_state WHERE date_key = ? AND item_id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, dateKey, -1, Self.sqliteTransient)
            sqlite3_bind_text(stmt, 2, itemID, -1, Self.sqliteTransient)
        }
    }

    func saveDailyReportSnapshot(_ snapshot: DailyReportSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        let sql = """
            INSERT INTO daily_report_snapshots (date_key, snapshot_json, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                snapshot_json = excluded.snapshot_json,
                created_at = excluded.created_at
        """
        let params: [String] = [
            snapshot.dateKey,
            json,
            String(Int(Date().timeIntervalSince1970))
        ]
        _ = executeUpdate(sql) { stmt in
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.sqliteTransient)
            }
        }
    }

    func loadDailyReportSnapshot(dateKey: String) -> DailyReportSnapshot? {
        queryOne("""
            SELECT snapshot_json FROM daily_report_snapshots WHERE date_key = ?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, dateKey, -1, Self.sqliteTransient)
        }, decode: { stmt in
            guard let text = sqlite3_column_text(stmt, 0) else { return nil }
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: text), count: Int(strlen(text)), deallocator: .none)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(DailyReportSnapshot.self, from: data)
        })
    }

    func recentDailyReportSnapshots(limit: Int = 7) -> [DailyReportSnapshot] {
        queryAll("""
            SELECT snapshot_json FROM daily_report_snapshots
            ORDER BY date_key DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }, decode: { stmt in
            guard let text = sqlite3_column_text(stmt, 0) else { return nil }
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: text), count: Int(strlen(text)), deallocator: .none)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(DailyReportSnapshot.self, from: data)
        })
    }
}
