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

    /// What this process last put on the general pasteboard inside an open
    /// save/restore window, recorded at the write itself.
    ///
    /// `restore` cannot rely on the caller's `pastedText` alone: `navigateToChat`
    /// pastes each candidate search name in a loop, so the string on the board is
    /// not necessarily the one the call site can name. Comparing against a value
    /// that does not match skips `clearContents()` and leaves the contact's
    /// nickname on the general pasteboard — the leak the parameter exists to
    /// close. Both are consulted, so a call site that names its own text still
    /// works and one that cannot is covered.
    private(set) static var lastWritten: String?

    static func noteWritten(_ text: String, on pasteboard: NSPasteboard? = nil) {
        lastWritten = text
        let pb = pasteboard ?? .general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func save() -> SavedState {
        lastWritten = nil
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
            let ours = [pastedText, lastWritten].compactMap { $0 }.filter { !$0.isEmpty }
            if state.hadContent, let current = pb.string(forType: .string), ours.contains(current) {
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
