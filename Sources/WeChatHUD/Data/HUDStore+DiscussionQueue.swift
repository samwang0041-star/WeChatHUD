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
                try discussionSQL("INSERT INTO discussion_queue(msg_uid,chat_username,payload,source_timestamp,local_id) SELECT ?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM discussion_queue WHERE msg_uid=?)",
                                  [message.id, message.chatUsername, payload, String(message.createTime), String(message.localId), message.id])
            }
        }
    }
    /// Deliberately do NOT filter retry_after in SQL: a failed oldest message
    /// must block newer rows, rather than allowing a later watermark past it.
    func pendingDiscussionMessages(chatUsername: String, limit: Int = 40) throws -> [QueuedDiscussionMessage] {
        try ensureDiscussionQueue()
        let statement = try discussionStatement("SELECT payload,attempts,retry_after FROM discussion_queue WHERE chat_username=? ORDER BY source_timestamp,local_id,msg_uid LIMIT ?",
                                                [chatUsername, String(max(1, min(limit, 200)))])
        defer { sqlite3_finalize(statement) }
        var rows: [QueuedDiscussionMessage] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let message = try? JSONDecoder().decode(MessageInfo.self, from: Data(String(cString: text).utf8)) else {
                throw HUDStoreError.sqlError("Invalid queued discussion message")
            }
            rows.append(QueuedDiscussionMessage(message: message,
                                                attempts: Int(sqlite3_column_int(statement, 1)),
                                                retryAfter: sqlite3_column_double(statement, 2)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw HUDStoreError.sqlError("Could not read discussion queue") }
        return rows
    }

    func discussionQueueChats() throws -> [String] {
        try ensureDiscussionQueue()
        let statement = try discussionStatement("SELECT chat_username FROM discussion_queue GROUP BY chat_username ORDER BY MIN(retry_after),MIN(source_timestamp)")
        defer { sqlite3_finalize(statement) }
        var chats: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { chats.append(String(cString: text)) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw HUDStoreError.sqlError("Could not read discussion queue") }
        return chats
    }

    func discussionQueueCount() throws -> Int {
        try ensureDiscussionQueue()
        let statement = try discussionStatement("SELECT COUNT(*) FROM discussion_queue")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HUDStoreError.sqlError("Could not count discussion queue") }
        return Int(sqlite3_column_int(statement, 0))
    }

    func retryDiscussionMessages() throws {
        try ensureDiscussionQueue()
        try discussionSQL("UPDATE discussion_queue SET retry_after=0")
    }

    func completeDiscussionMessages(_ ids: [String]) throws {
        for id in ids { try discussionSQL("DELETE FROM discussion_queue WHERE msg_uid=?", [id]) }
    }

    func deferDiscussionMessages(_ ids: [String], until: TimeInterval) throws {
        for id in ids {
            try discussionSQL("UPDATE discussion_queue SET attempts=attempts+1,retry_after=? WHERE msg_uid=?", [String(until), id])
        }
    }

    func clearDiscussionMessages(chatUsername: String) throws {
        try ensureDiscussionQueue()
        try discussionSQL("DELETE FROM discussion_queue WHERE chat_username=?", [chatUsername])
    }

    private func ensureDiscussionQueue() throws {
        try discussionSQL("""
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
        try discussionSQL("CREATE INDEX IF NOT EXISTS discussion_queue_chat_order ON discussion_queue(chat_username,source_timestamp,local_id,msg_uid)")
    }

    private func discussionStatement(_ sql: String, _ parameters: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(rawDB, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HUDStoreError.sqlError("Could not prepare discussion queue operation")
        }
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return statement
    }

    private func discussionSQL(_ sql: String, _ parameters: [String] = []) throws {
        let statement = try discussionStatement(sql, parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HUDStoreError.sqlError("Could not persist discussion queue operation") }
    }
}
