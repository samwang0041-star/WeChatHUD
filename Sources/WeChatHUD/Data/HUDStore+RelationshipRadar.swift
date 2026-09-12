import Foundation
import SQLite3

extension HUDStore {
    func upsertDailyInsightPoint(_ point: DailyInsightPoint) throws {
        let encoder = JSONEncoder()
        let topics = String(data: try encoder.encode(point.topics), encoding: .utf8) ?? "[]"
        let decisions = String(data: try encoder.encode(point.decisions), encoding: .utf8) ?? "[]"
        let now = Int(Date().timeIntervalSince1970)
        try exec("""
            INSERT INTO chat_insight_daily(
                chat_username, day, headline, topics_json, decisions_json,
                waiting_count, overall_mood, message_count, my_message_count,
                insight, created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(chat_username, day) DO UPDATE SET
                headline = excluded.headline,
                topics_json = excluded.topics_json,
                decisions_json = excluded.decisions_json,
                waiting_count = excluded.waiting_count,
                overall_mood = excluded.overall_mood,
                message_count = excluded.message_count,
                my_message_count = excluded.my_message_count,
                insight = excluded.insight,
                created_at = excluded.created_at
        """, params: [
            point.chatUsername,
            point.day,
            point.headline,
            topics,
            decisions,
            "\(point.waitingCount)",
            point.overallMood,
            "\(point.messageCount)",
            "\(point.myMessageCount)",
            point.insight,
            "\(now)"
        ])
    }

    func loadDailyInsightPoints(
        chatUsername: String? = nil,
        sinceDay: String? = nil,
        limit: Int = 90
    ) -> [DailyInsightPoint] {
        var sql = """
            SELECT chat_username, day, headline, topics_json, decisions_json,
                   waiting_count, overall_mood, message_count, my_message_count, insight
            FROM chat_insight_daily
        """
        var clauses: [String] = []
        var params: [String] = []
        if let chatUsername {
            clauses.append("chat_username=?")
            params.append(chatUsername)
        }
        if let sinceDay {
            clauses.append("day>=?")
            params.append(sinceDay)
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY day ASC LIMIT \(max(1, limit))"

        return queryAll(sql, bind: { stmt in
            for (index, param) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), param, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }, decode: { stmt in
            decodeDailyInsightPoint(stmt)
        })
    }

    func saveRelationshipRadarSnapshot(_ snapshot: RelationshipRadarSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        let ts = Int(snapshot.generatedAt.timeIntervalSince1970)
        try exec("""
            INSERT INTO relationship_radar(chat_username, generated_at, window_days, payload)
            VALUES(?,?,?,?)
            ON CONFLICT(chat_username) DO UPDATE SET
                generated_at = excluded.generated_at,
                window_days = excluded.window_days,
                payload = excluded.payload
        """, params: [
            snapshot.chatUsername,
            "\(ts)",
            "\(snapshot.windowDays)",
            payload
        ])
    }

    func loadRelationshipRadarSnapshot(chatUsername: String) -> RelationshipRadarSnapshot? {
        queryOne("""
            SELECT payload FROM relationship_radar WHERE chat_username=? LIMIT 1
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, chatUsername, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, decode: { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            let raw = String(cString: ptr)
            return try? JSONDecoder().decode(RelationshipRadarSnapshot.self, from: Data(raw.utf8))
        })
    }

    func loadAllRelationshipRadarSnapshots(limit: Int = 50) -> [RelationshipRadarSnapshot] {
        queryAll("""
            SELECT payload FROM relationship_radar
            ORDER BY generated_at DESC
            LIMIT \(max(1, limit))
        """, bind: { _ in }, decode: { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            let raw = String(cString: ptr)
            return try? JSONDecoder().decode(RelationshipRadarSnapshot.self, from: Data(raw.utf8))
        })
    }

    private func decodeDailyInsightPoint(_ stmt: OpaquePointer?) -> DailyInsightPoint? {
        guard let stmt else { return nil }
        func text(_ index: Int32) -> String {
            guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
            return String(cString: ptr)
        }
        let decoder = JSONDecoder()
        let topics = (try? decoder.decode([String].self, from: Data(text(3).utf8))) ?? []
        let decisions = (try? decoder.decode([String].self, from: Data(text(4).utf8))) ?? []
        let chatUsername = text(0)
        let day = text(1)
        guard !chatUsername.isEmpty, !day.isEmpty else { return nil }
        return DailyInsightPoint(
            chatUsername: chatUsername,
            day: day,
            headline: text(2),
            topics: topics,
            decisions: decisions,
            waitingCount: Int(sqlite3_column_int64(stmt, 5)),
            overallMood: text(6),
            messageCount: Int(sqlite3_column_int64(stmt, 7)),
            myMessageCount: Int(sqlite3_column_int64(stmt, 8)),
            insight: text(9)
        )
    }
}
