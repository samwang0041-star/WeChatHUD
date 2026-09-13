import Foundation
import SQLite3

extension HUDStore {
    struct QueuedDiscussionMessage {
        let message: MessageInfo
        let attempts: Int
        let retryAfter: TimeInterval
    }

    /// Snapshots are account-local, and survive both provider failures and app
    /// restarts. Source cursors may advance only after this insert succeeds.
    func enqueueDiscussionMessages(_ messages: [MessageInfo]) throws {
        try ensureDiscussionQueue()
        // The queue is read oldest-first. Sorting plus one transaction means a
        // crash can never persist only the newest row and then advance past an
        // older row that had not yet reached disk.
        let ordered = messages.sorted {
            DiscussionTracker.SourceCursor($0).precedes(DiscussionTracker.SourceCursor($1))
        }
        try withTransaction {
            for message in ordered {
                if let cursor = getSettingJSON(DiscussionTracker.cursorKey(message.chatUsername), as: DiscussionTracker.SourceCursor.self),
                   !cursor.precedes(DiscussionTracker.SourceCursor(message)) { continue }
                let payload = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
                // Plain INSERT preserves trigger aborts. OR IGNORE would also
                // swallow the explicit failure this queue needs for rollback.
                try exec(
                    "INSERT INTO discussion_queue(msg_uid,chat_username,payload,source_timestamp,local_id) SELECT ?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM discussion_queue WHERE msg_uid=?)",
                    params: [message.id, message.chatUsername, payload, String(message.createTime), String(message.localId), message.id]
                )
            }
        }
    }
    /// Deliberately do NOT filter retry_after in SQL: a failed oldest message
    /// must block newer rows, rather than allowing a later watermark past it.
    func pendingDiscussionMessages(chatUsername: String, limit: Int = 40) throws -> [QueuedDiscussionMessage] {
        try ensureDiscussionQueue()
        let capped = String(max(1, min(limit, 200)))
        return try queryAllThrowing(
            "SELECT payload,attempts,retry_after FROM discussion_queue WHERE chat_username=? ORDER BY source_timestamp,local_id,msg_uid LIMIT ?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, chatUsername, -1, Self.sqliteTransient)
                sqlite3_bind_text(stmt, 2, capped, -1, Self.sqliteTransient)
            },
            decode: { stmt in
                let payload = Self.textColumn(stmt, 0)
                guard let message = try? JSONDecoder().decode(MessageInfo.self, from: Data(payload.utf8)) else {
                    throw HUDStoreError.sqlError("Invalid queued discussion message")
                }
                return QueuedDiscussionMessage(
                    message: message,
                    attempts: Int(sqlite3_column_int(stmt, 1)),
                    retryAfter: sqlite3_column_double(stmt, 2)
                )
            }
        )
    }

    func discussionQueueChats() throws -> [String] {
        try ensureDiscussionQueue()
        return try queryAllThrowing(
            "SELECT chat_username FROM discussion_queue GROUP BY chat_username ORDER BY MIN(retry_after),MIN(source_timestamp)",
            bind: { _ in },
            decode: { stmt in Self.textColumn(stmt, 0) }
        )
    }

    func discussionQueueCount() throws -> Int {
        try ensureDiscussionQueue()
        guard let count = try queryOneThrowing(
            "SELECT COUNT(*) FROM discussion_queue",
            bind: { _ in },
            decode: { stmt in Int(sqlite3_column_int(stmt, 0)) }
        ) else {
            throw HUDStoreError.sqlError("Could not count discussion queue")
        }
        return count
    }

    func retryDiscussionMessages() throws {
        try ensureDiscussionQueue()
        try exec("UPDATE discussion_queue SET retry_after=0")
    }

    func completeDiscussionMessages(_ ids: [String]) throws {
        for id in ids { try exec("DELETE FROM discussion_queue WHERE msg_uid=?", params: [id]) }
    }

    func deferDiscussionMessages(_ ids: [String], until: TimeInterval) throws {
        for id in ids {
            try exec(
                "UPDATE discussion_queue SET attempts=attempts+1,retry_after=? WHERE msg_uid=?",
                params: [String(until), id]
            )
        }
    }

    func clearDiscussionMessages(chatUsername: String) throws {
        try ensureDiscussionQueue()
        try exec("DELETE FROM discussion_queue WHERE chat_username=?", params: [chatUsername])
    }

    private func ensureDiscussionQueue() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS discussion_queue (
                msg_uid TEXT PRIMARY KEY,
                chat_username TEXT NOT NULL,
                payload TEXT NOT NULL,
                source_timestamp INTEGER NOT NULL,
                local_id INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                retry_after REAL NOT NULL DEFAULT 0
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS discussion_queue_chat_order ON discussion_queue(chat_username,source_timestamp,local_id,msg_uid)")
    }
}
