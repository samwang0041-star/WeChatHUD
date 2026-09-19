import AppKit
import Foundation

/// Saves and restores the system clipboard around WeChat UI automation.
///
/// Pasteboard access belongs on the main actor (AppKit). Callers that are not
/// already on MainActor must `await` these entry points.
@MainActor
enum ClipboardGuard {
    struct SavedState: @unchecked Sendable {
        // Pasteboard item copies are only read/written on MainActor in save/restore.
        let items: [NSPasteboardItem]?
        let changeCount: Int
        let hadContent: Bool
    }

    static func save() -> SavedState {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        let originalItems = pb.pasteboardItems ?? []
        let hadContent = !originalItems.isEmpty || !(pb.types ?? []).isEmpty

        // Deep-copy pasteboard items so they survive clearContents()
        var saved: [NSPasteboardItem] = []
        for item in originalItems {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            if copy.types.isEmpty, let data = pb.data(forType: item.types.first ?? .string) {
                copy.setData(data, forType: item.types.first ?? .string)
            }
            saved.append(copy)
        }
        if saved.allSatisfy({ $0.types.isEmpty }) {
            saved = []
        }

        return SavedState(items: saved.isEmpty ? nil : saved, changeCount: changeCount, hadContent: hadContent)
    }

    /// - Parameter pastedText: exactly what this process wrote to the
    ///   pasteboard during the send. Only consulted when the snapshot came
    ///   back empty, where it is the one way to tell our own draft from
    ///   something the user copied afterwards.
    /// - Parameter pasteboard: injectable so the leak below has a behaviour
    ///   test; the general pasteboard cannot be observed from a test run.
    static func restore(_ state: SavedState, pastedText: String? = nil,
                        on pasteboard: NSPasteboard? = nil) {
        let pb = pasteboard ?? .general
        // Only restore if the clipboard was changed (by our send)
        guard pb.changeCount != state.changeCount else { return }
        if state.hadContent && (state.items == nil || state.items?.isEmpty == true) {
            // The snapshot failed (promised files / images). The comment here
            // used to say 「do not wipe irreplaceable data」 — but the caller's
            // `clearContents()` runs before the paste, so by this line that
            // data is already gone and this branch protects nothing. What it
            // did keep alive was our own draft: chat text, often quoting the
            // other party, parked on the general pasteboard for any clipboard
            // manager to read and for Universal Clipboard to sync to the
            // user's other devices. Erase it, but only when the pasteboard
            // still holds exactly the string we wrote — content someone else
            // copied since then is not ours to destroy.
            if state.hadContent, let pastedText, !pastedText.isEmpty,
               pb.string(forType: .string) == pastedText {
                pb.clearContents()
            }
            return
        }
        pb.clearContents()
        if let items = state.items, !items.isEmpty {
            pb.writeObjects(items)
        }
    }
}
