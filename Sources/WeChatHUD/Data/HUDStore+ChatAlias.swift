import Foundation
import SQLite3

/// User-visible conversation names.
///
/// Two problems meet here:
///
/// 1. WeChat leaves a large share of group rooms unnamed (357 of 1180 on the
///    reference account). `contact.db` has a row for them but with empty
///    `nick_name`/`remark`, so anything that reads only `contact` shows the
///    raw `…@chatroom` id — meaningless to the user.
/// 2. Rows persisted before the placeholder fallback existed still carry that
///    raw id in their `chat_name`/`display_name` column.
///
/// `chat_aliases` lets the user give a conversation a name of their own, which
/// then wins over everything WeChat reports.
extension HUDStore {

    private static let chatNameColumnPairs: [(table: String, keyColumn: String, nameColumn: String)] = [
        ("commitments", "chat_username", "chat_name"),
        ("discussion_items", "chat_username", "chat_name"),
        ("pending_asks", "chat_username", "chat_name"),
        ("vip_traces", "chat_username", "chat_name"),
        ("recalled_messages", "chat_username", "chat_name"),
        ("reply_drafts", "chat_username", "chat_name"),
        ("autopilot_log", "chat_username", "chat_name"),
        ("autopilot_pending_sends", "chat_username", "chat_name"),
        ("autopilot_inbound_queue", "chat_username", "chat_name"),
        ("ignored_senders", "chat_username", "chat_name"),
        ("suggestions", "username", "display_name"),
        ("scan_dismissed", "username", "display_name"),
        ("contacts", "username", "display_name"),
        ("relationship_profiles", "username", "display_name"),
        ("whitelist", "username", "display_name"),
    ]

    nonisolated func migrateChatAliases() {
        execIgnoringError("""
            CREATE TABLE IF NOT EXISTS chat_aliases (
                username     TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                updated_at   INTEGER NOT NULL
            )
        """)
    }

    /// username → user-chosen display name.
    func loadChatAliases() -> [String: String] {
        let rows: [(String, String)] = queryAll(
            _: "SELECT username, display_name FROM chat_aliases",
            bind: { _ in },
            decode: { stmt -> (String, String)? in
                guard let key = sqlite3_column_text(stmt, 0),
                      let name = sqlite3_column_text(stmt, 1) else { return nil }
                return (String(cString: key), String(cString: name))
            }
        )
        return rows.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    func chatAlias(for username: String) -> String? {
        guard !username.isEmpty else { return nil }
        // Single-row lookup: callers hit this per UI render, so a full-table
        // read on every call would be wasteful.
        return queryOne(
            "SELECT display_name FROM chat_aliases WHERE username=?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            },
            decode: { stmt in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
        )
    }

    /// Store a user-chosen name and rewrite every row that cached the old one.
    /// Returns the number of rows rewritten.
    @discardableResult
    func setChatAlias(username: String, displayName: String, previousName: String? = nil) throws -> Int {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeChatAlias(username: username)
            return 0
        }
        let now = "\(Int(Date().timeIntervalSince1970))"
        let written = executeUpdate(
            "INSERT OR REPLACE INTO chat_aliases(username, display_name, updated_at) VALUES(?,?,?)",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, trimmed, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        )
        guard written > 0 else { throw HUDStoreError.sqlError("chat alias write failed") }
        return propagateChatName(username: username, displayName: trimmed, previousName: previousName)
    }

    func removeChatAlias(username: String) throws {
        // Idempotent: clearing a name that was never set is not an error.
        _ = executeUpdate(
            "DELETE FROM chat_aliases WHERE username=?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        )
    }

    /// Rename a conversation everywhere it is already recorded.
    ///
    /// Persisted rows cache the name they were written with, so without this
    /// a rename would only show up in the inbox while older commitments,
    /// discussion items and traces kept the previous label.
    /// `previousName` additionally rewrites commitment "答应谁" fields that
    /// named this chat, so a rename does not leave half the UI on the old label.
    /// Only an exact match is rewritten — a value naming a person stays put.
    @discardableResult
    func propagateChatName(username: String, displayName: String, previousName: String? = nil) -> Int {
        guard !username.isEmpty, !displayName.isEmpty else { return 0 }
        var changed = 0
        try? withTransaction {
            for pair in Self.chatNameColumnPairs {
                changed += executeUpdate(
                    "UPDATE \(pair.table) SET \(pair.nameColumn)=? WHERE \(pair.keyColumn)=? AND \(pair.nameColumn)<>?",
                    bind: { stmt in
                        sqlite3_bind_text(stmt, 1, displayName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 2, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 3, displayName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                )
            }
            if let previousName, !previousName.isEmpty, previousName != displayName {
                changed += executeUpdate(
                    "UPDATE commitments SET commit_to=? WHERE chat_username=? AND commit_to=?",
                    bind: { stmt in
                        sqlite3_bind_text(stmt, 1, displayName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 2, username, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 3, previousName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                )
            }
        }
        return changed
    }

    /// Rows still carrying a name that says nothing about which chat they
    /// belong to — a raw `…@chatroom` id or the bare placeholder.
    ///
    /// Returned per table so callers can resolve each chat once and skip the
    /// write transaction entirely when the answer would not change anything.
    func uninformativeChatNameRows() -> [(table: String, keyColumn: String, nameColumn: String, key: String, name: String)] {
        var rows: [(String, String, String, String, String)] = []
        for pair in Self.chatNameColumnPairs {
            // Coarse prefilter only — `isUninformativeChatName` is the authority.
            let filter = "\(pair.nameColumn) LIKE '%@chatroom'"
                + " OR \(pair.nameColumn) LIKE '%@openim'"
                + " OR \(pair.nameColumn) LIKE 'wxid%'"
                + " OR \(pair.nameColumn) = '\(ContactIdentityIndex.unnamedGroupPlaceholder)'"
            let found = queryAll(
                _: "SELECT DISTINCT \(pair.keyColumn), \(pair.nameColumn) FROM \(pair.table) WHERE \(filter)",
                bind: { _ in },
                decode: { stmt -> (String, String)? in
                    guard let key = sqlite3_column_text(stmt, 0),
                          let name = sqlite3_column_text(stmt, 1) else { return nil }
                    return (String(cString: key), String(cString: name))
                }
            )
            for (key, name) in found where ContactIdentityIndex.isUninformativeChatName(name) {
                rows.append((pair.table, pair.keyColumn, pair.nameColumn, key, name))
            }
        }
        return rows
    }

    /// Commitments whose "答应谁" field holds a raw chat id. The model
    /// occasionally echoes the room id when it cannot tell who the promise was
    /// made to, and that value is shown in alerts, exports and the UI.
    func uninformativeCommitTargets() -> [(msgUID: String, target: String)] {
        let rows = queryAll(
            _: "SELECT msg_uid, commit_to FROM commitments WHERE commit_to LIKE '%@chatroom' OR commit_to LIKE '%@openim' OR commit_to LIKE 'wxid%'",
            bind: { _ in },
            decode: { stmt -> (String, String)? in
                guard let uid = sqlite3_column_text(stmt, 0),
                      let target = sqlite3_column_text(stmt, 1) else { return nil }
                return (String(cString: uid), String(cString: target))
            }
        )
        return rows.filter { ContactIdentityIndex.isRawChatIdentifier($0.1) }
    }

    @discardableResult
    func applyResolvedCommitTargets(_ updates: [(msgUID: String, oldTarget: String, newTarget: String)]) -> Int {
        guard !updates.isEmpty else { return 0 }
        var changed = 0
        try? withTransaction {
            for update in updates {
                changed += executeUpdate(
                    "UPDATE commitments SET commit_to=? WHERE msg_uid=? AND commit_to=?",
                    bind: { stmt in
                        sqlite3_bind_text(stmt, 1, update.newTarget, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 2, update.msgUID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 3, update.oldTarget, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                )
            }
        }
        return changed
    }

    /// Rewrite the given rows to `displayName`. Rows are matched on their old
    /// value so a concurrent rename is never clobbered.
    ///
    /// Returns the number of rows changed.
    @discardableResult
    func applyResolvedChatNames(
        _ updates: [(table: String, keyColumn: String, nameColumn: String, key: String, oldName: String, newName: String)]
    ) -> Int {
        guard !updates.isEmpty else { return 0 }
        var changed = 0
        try? withTransaction {
            for update in updates {
                changed += executeUpdate(
                    "UPDATE \(update.table) SET \(update.nameColumn)=? WHERE \(update.keyColumn)=? AND \(update.nameColumn)=?",
                    bind: { stmt in
                        sqlite3_bind_text(stmt, 1, update.newName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 2, update.key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_text(stmt, 3, update.oldName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                )
            }
        }
        return changed
    }
}
