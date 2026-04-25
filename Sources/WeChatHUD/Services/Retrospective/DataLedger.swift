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
    /// data-ledger Preferences view (Phase 2). Fields are RFC 4180
    /// escaped — values containing comma / quote / newline are quoted
    /// with internal double-quotes doubled.
    func exportCSV(to url: URL, days: Int = 90) throws {
        let entries = recent(days: days)
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
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
            return cols.map(DataLedger.csvEscape).joined(separator: ",")
        }.joined(separator: "\n")
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
    }

    /// RFC 4180 quoting: wrap in `"..."` if the value contains comma,
    /// double-quote, or newline; double-up internal quotes. Pure-numeric
    /// or stopword-free strings pass through untouched for cleanliness.
    static func csvEscape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
