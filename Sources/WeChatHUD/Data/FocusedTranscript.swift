import Foundation

/// The message a conversation view must land on, instead of the latest line.
struct TranscriptFocus: Equatable {
    let chatUsername: String
    let messageID: String
    let senderName: String
    let body: String
    let timestamp: Date
}

enum FocusedTranscript {
    struct Row: Equatable {
        let sender: String
        let body: String
        let isFocus: Bool
    }

    /// Keep the loaded window, but guarantee the focused inbound is visible.
    /// If the reader did not return it (preview, truncated page), insert it
    /// at the top so the person still sees the line they came here for.
    static func assemble(
        loaded: [(sender: String, body: String)],
        focus: TranscriptFocus?
    ) -> [Row] {
        guard let focus else {
            return loaded.map { Row(sender: $0.sender, body: $0.body, isFocus: false) }
        }
        let focusBody = focus.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = loaded.map { row in
            Row(
                sender: row.sender,
                body: row.body,
                isFocus: row.body.trimmingCharacters(in: .whitespacesAndNewlines) == focusBody
                    && (row.sender == focus.senderName || focus.senderName.isEmpty)
            )
        }
        if !rows.contains(where: { $0.isFocus }) {
            rows.insert(
                Row(sender: focus.senderName, body: focus.body, isFocus: true),
                at: 0
            )
        }
        return rows
    }
}
