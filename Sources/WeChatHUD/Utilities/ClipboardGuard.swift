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

    static func restore(_ state: SavedState) {
        let pb = NSPasteboard.general
        // Only restore if the clipboard was changed (by our send)
        guard pb.changeCount != state.changeCount else { return }
        if state.hadContent && (state.items == nil || state.items?.isEmpty == true) {
            // Snapshot failed (promised files / images). Do not wipe irreplaceable data.
            return
        }
        pb.clearContents()
        if let items = state.items, !items.isEmpty {
            pb.writeObjects(items)
        }
    }
}
