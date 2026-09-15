import AppKit

/// What the app's one global key monitor should do with a key event.
///
/// This exists as a pure function for two reasons.
///
/// **It was shadowing the menu bar.** The monitor is an
/// `NSEvent.addLocalMonitorForEvents` hook: it sees ⌘-chords *before* AppKit
/// matches them against `NSApp.mainMenu`, and returning `true` swallows the
/// event. The handler used to claim ⌘1 and ⌘, itself, while the menu bar
/// advertised those same two chords for 打开 WeChatHUD and 设置… — so pressing
/// them ran a different action than the one printed next to the item, and the
/// menu item was unreachable. `MainMenuTests` cannot catch that: it asserts the
/// menu in isolation, and a hidden handler living in another file is exactly
/// what "in isolation" excludes.
///
/// **It had no coverage at all.** Escape, the one shortcut a Mac user presses
/// without looking, was untested in every state it can fire in.
enum KeyboardShortcutPolicy {

    /// Where the key event landed. The same chord means different things in
    /// the island and in the workspace window, which is why this is an input.
    enum Target: Equatable {
        /// The floating panel (compact / peek / extended / notification).
        case island
        /// The workspace window.
        case workspace
        /// Onboarding or any other window that claims no shortcuts.
        case other
    }

    enum Action: Equatable {
        /// Island: fold back into the notch.
        case collapseIsland
        /// Workspace: close the window, the way ⌘W would.
        case closeWorkspace
    }

    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`. 53 is Escape.
    ///   - characters: `NSEvent.charactersIgnoringModifiers`, lowercased here.
    ///   - modifiers: `NSEvent.modifierFlags`.
    ///   - target: which window received the event.
    ///   - hasAttachedSheet: whether that window is currently presenting a
    ///     sheet. A sheet owns Escape while it is up, and this monitor runs
    ///     before the sheet's own responder chain sees the key.
    static func action(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        target: Target,
        hasAttachedSheet: Bool
    ) -> Action? {
        // ⌘. is the other standard cancel chord. Escape and ⌘. are the pair
        // macOS users have in their fingers; supporting only the first is the
        // kind of half-implemented standard this file exists to avoid.
        let isCancel = keyCode == 53
            || (characters?.lowercased() == "." && modifiers.contains(.command))

        guard isCancel else { return nil }
        // A held ⌘/⌃/⌥ turns Escape into somebody else's chord (⌘⎋ is the
        // system's force-quit). Only bare Escape cancels.
        if keyCode == 53,
           !modifiers.intersection([.command, .control, .option]).isEmpty {
            return nil
        }
        // The sheet takes Escape first: closing the window out from under an
        // open sheet would discard the user's half-finished input without the
        // confirmation the sheet was asking for.
        guard !hasAttachedSheet else { return nil }

        switch target {
        case .island: return .collapseIsland
        case .workspace: return .closeWorkspace
        case .other: return nil
        }
    }
}
