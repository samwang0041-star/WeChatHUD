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

        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS daily_report_action_insights (
                date_key       TEXT NOT NULL,
                action_id      TEXT NOT NULL,
                reason         TEXT NOT NULL,
                next_step      TEXT NOT NULL,
                model_version  TEXT NOT NULL,
                generated_at   INTEGER NOT NULL,
                PRIMARY KEY(date_key, action_id)
            )
        """)
        execIgnoringError("CREATE INDEX IF NOT EXISTS idx_action_insights_date ON daily_report_action_insights(date_key)")
        // One-time and ongoing cleanup of orphan command-state rows (see
        // gcDailyReportState). Runs inside the same startup migration.
        gcDailyReportState()
    }

    /// Drops `daily_report_state` rows that can never match again.
    ///
    /// Two sources: (1) pre-SHA-256 ids derived from `String.hashValue`, which
    /// is reseeded every process launch — every "忽略风险" left one orphan row
    /// per restart behind. Legacy highlight/risk ids end in a decimal integer
    /// (`<chat>-123456789` / `<type>--123456789`); stable ids end in exactly
    /// 16 hex chars. An all-digit 16-char suffix is ambiguous, so those rows
    /// are left to the age rule. (2) Rows older than 45 days: states are only
    /// ever read for the viewed report date, so nothing consults them again.
    /// Called from the migration path at startup; best-effort.
    func gcDailyReportState(retentionDays: Int = 45) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date.distantPast
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let cutoffKey = formatter.string(from: cutoff)
        _ = executeUpdate("DELETE FROM daily_report_state WHERE date_key < ?") { stmt in
            sqlite3_bind_text(stmt, 1, cutoffKey, -1, Self.sqliteTransient)
        }
        let ids: [String] = queryAll("SELECT DISTINCT item_id FROM daily_report_state", bind: { _ in }, decode: { stmt in
            sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        })
        for id in ids where Self.isLegacyDailyReportItemID(id) {
            _ = executeUpdate("DELETE FROM daily_report_state WHERE item_id = ?") { stmt in
                sqlite3_bind_text(stmt, 1, id, -1, Self.sqliteTransient)
            }
        }
    }

    /// True for pre-SHA-256 `hashValue` ids: a trailing decimal integer that
    /// cannot be a 16-hex stable digest. Negative hashes (`--123…`) are
    /// unambiguous; positive ones are legacy unless exactly 16 digits (which
    /// could theoretically be an all-numeric hex digest — left in place).
    static func isLegacyDailyReportItemID(_ id: String) -> Bool {
        // Action states (`todo-<relatedID>` etc.) are current-format by
        // construction — their suffixes are related ids, not hashes.
        for prefix in ["todo-", "commitment-", "replyDebt-", "ask-"] {
            if id.hasPrefix(prefix) { return false }
        }
        // Negative hashValues serialize with a double dash (`<chat>--123…`).
        // Stable ids never contain one (usernames do not end in `-`).
        if let dash = id.lastIndex(of: "-"), dash > id.startIndex,
           id[id.index(before: dash)] == "-" {
            let tail = String(id[id.index(after: dash)...])
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) { return true }
            return false
        }
        guard let dash = id.lastIndex(of: "-") else { return false }
        let suffix = String(id[id.index(after: dash)...])
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return false }
        return suffix.count != 16
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

    func upsertActionInsight(_ insight: DailyReportActionInsight) throws {
        let sql = """
            INSERT INTO daily_report_action_insights
                (date_key, action_id, reason, next_step, model_version, generated_at)
            VALUES
                (?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key, action_id) DO UPDATE SET
                reason = excluded.reason,
                next_step = excluded.next_step,
                model_version = excluded.model_version,
                generated_at = excluded.generated_at
        """
        let params: [String] = [
            insight.dateKey,
            insight.actionID,
            insight.reason,
            insight.nextStep,
            insight.modelVersion,
            String(Int(insight.generatedAt.timeIntervalSince1970))
        ]
        _ = executeUpdate(sql) { stmt in
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.sqliteTransient)
            }
        }
    }

    func loadActionInsights(dateKey: String) -> [DailyReportActionInsight] {
        queryAll("""
            SELECT date_key, action_id, reason, next_step, model_version, generated_at
            FROM daily_report_action_insights
            WHERE date_key = ?
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, dateKey, -1, Self.sqliteTransient)
        }, decode: { stmt in
            guard let dk = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let aid = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let reason = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let nextStep = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let mv = sqlite3_column_text(stmt, 4).map({ String(cString: $0) })
            else { return nil }
            let ts = sqlite3_column_int64(stmt, 5)
            return DailyReportActionInsight(
                dateKey: dk,
                actionID: aid,
                reason: reason,
                nextStep: nextStep,
                modelVersion: mv,
                generatedAt: Date(timeIntervalSince1970: TimeInterval(ts))
            )
        })
    }
}
