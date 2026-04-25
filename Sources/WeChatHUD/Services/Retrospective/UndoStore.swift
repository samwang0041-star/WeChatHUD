import Foundation

/// Self-contained undo stack persisted to `undo_stack` table (Spec §3.3).
///
/// Why not Cocoa UndoManager: UndoManager is per-responder and resets when
/// keyWindow changes — sharing across the floating tab + independent
/// retrospective NSWindow would be unreliable. This service owns its own
/// 30-minute scoped undo journal.
///
/// `record(...)` snapshots before/after JSON; `popLatest()` returns and
/// removes the most recent entry so callers can reverse-apply it.
actor UndoStore {
    private let store: HUDStore

    init(store: HUDStore) {
        self.store = store
    }

    /// Snapshots `before`/`after` payloads (Codable) into the undo journal.
    /// Returns the new entry id, or nil if encoding/insert failed.
    @discardableResult
    func record<T: Codable>(
        targetTable: String,
        targetID: Int,
        operation: UndoOperation,
        before: T,
        after: T
    ) -> Int? {
        let encoder = JSONEncoder()
        guard let beforeData = try? encoder.encode(before),
              let afterData = try? encoder.encode(after),
              let beforeStr = String(data: beforeData, encoding: .utf8),
              let afterStr = String(data: afterData, encoding: .utf8)
        else { return nil }
        let entry = UndoEntry(
            id: 0, ts: Date(), targetTable: targetTable, targetID: targetID,
            operation: operation, payloadBefore: beforeStr, payloadAfter: afterStr
        )
        return store.pushUndo(entry)
    }

    /// Returns the most recent entry and deletes it from the journal.
    /// Caller is responsible for actually reverting the recorded change.
    func popLatest() -> UndoEntry? {
        store.popLatestUndo()
    }
}
