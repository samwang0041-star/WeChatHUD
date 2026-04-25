import Foundation

/// Wraps `HUDStore.recordLedgerBatch` for orchestrators (Spec §8.1.5,
/// §8.3). Provides CSV export for the data-ledger settings view.
actor DataLedger {
    private let store: HUDStore

    init(store: HUDStore) {
        self.store = store
    }

    func recordBatch(_ entries: [AILedgerEntry]) {
        store.recordLedgerBatch(entries)
    }

    func recent(days: Int = 90) -> [AILedgerEntry] {
        store.recentLedger(days: days)
    }

    @discardableResult
    func clearOlderThan(days: Int) -> Int {
        store.clearLedger(olderThanDays: days)
    }

    /// CSV export to a file URL. Used by `[导出 CSV]` button in the
    /// data-ledger Preferences view (Phase 2).
    func exportCSV(to url: URL, days: Int = 90) throws {
        let entries = recent(days: days)
        let isoFmt = ISO8601DateFormatter()
        let header = "timestamp,provider,model,purpose,chat_count,msg_count,byte_count,token_in,token_out,redacted\n"
        let rows = entries.map { e -> String in
            let chatCountStr: String = e.chatCount.map(String.init) ?? ""
            let msgCountStr: String = e.msgCount.map(String.init) ?? ""
            let tokenInStr: String = e.tokenIn.map(String.init) ?? ""
            let tokenOutStr: String = e.tokenOut.map(String.init) ?? ""
            let cols: [String] = [
                isoFmt.string(from: e.ts),
                e.provider,
                e.model,
                e.purpose.rawValue,
                chatCountStr,
                msgCountStr,
                String(e.byteCount),
                tokenInStr,
                tokenOutStr,
                e.redacted ? "1" : "0"
            ]
            return cols.joined(separator: ",")
        }.joined(separator: "\n")
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
    }
}
