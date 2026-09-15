import XCTest
import AppKit
@testable import WeChatHUD

/// What the keyboard does, and what the menu bar does with the same chords.
///
/// Both halves of this file exist because of the same real defect: the app's
/// local key monitor (`NSEvent.addLocalMonitorForEvents`) sees ⌘-chords
/// *before* AppKit matches them against the menu bar, and returning `true`
/// swallows the event. The monitor used to claim ⌘1 and ⌘, — exactly the two
/// chords the menu advertises for 打开 WeChatHUD and 设置… — so the menu items
/// could not be reached and those keys did something else.
///
/// `MainMenuTests` could not catch it: it builds the menu in isolation, and a
/// hidden handler in another file is precisely what "in isolation" excludes.
final class KeyboardShortcutPolicyTests: XCTestCase {

    // MARK: - Escape

    func testEscapeCollapsesTheIsland() {
        XCTAssertEqual(
            KeyboardShortcutPolicy.action(
                keyCode: 53, characters: "\u{1B}", modifiers: [],
                target: .island, hasAttachedSheet: false
            ),
            .collapseIsland
        )
    }

    func testEscapeClosesTheWorkspaceWindow() {
        XCTAssertEqual(
            KeyboardShortcutPolicy.action(
                keyCode: 53, characters: "\u{1B}", modifiers: [],
                target: .workspace, hasAttachedSheet: false
            ),
            .closeWorkspace
        )
    }

    /// Onboarding and every other window claim nothing: Escape there belongs to
    /// whatever control is focused.
    func testEscapeIsLeftAloneInWindowsWeDoNotOwn() {
        XCTAssertNil(
            KeyboardShortcutPolicy.action(
                keyCode: 53, characters: "\u{1B}", modifiers: [],
                target: .other, hasAttachedSheet: false
            )
        )
    }

    /// ⌘⎋ is the system's force-quit and ⌥⎋ / ⌃⎋ belong to other tools. A held
    /// modifier must not turn Escape into "close this window".
    func testModifiedEscapeIsNotOurs() {
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .control] {
            XCTAssertNil(
                KeyboardShortcutPolicy.action(
                    keyCode: 53, characters: "\u{1B}", modifiers: modifiers,
                    target: .workspace, hasAttachedSheet: false
                ),
                "\(modifiers) + Escape must not close the window"
            )
        }
    }

    /// The other standard cancel chord, and the reason this policy is a
    /// function rather than four lines: Escape alone would have shipped.
    func testCommandPeriodAlsoCancels() {
        XCTAssertEqual(
            KeyboardShortcutPolicy.action(
                keyCode: 47, characters: ".", modifiers: [.command],
                target: .island, hasAttachedSheet: false
            ),
            .collapseIsland
        )
    }

    func testPlainPeriodIsJustAPeriod() {
        XCTAssertNil(
            KeyboardShortcutPolicy.action(
                keyCode: 47, characters: ".", modifiers: [],
                target: .island, hasAttachedSheet: false
            )
        )
    }

    /// A sheet owns Escape while it is up. This monitor runs first, so without
    /// the guard Escape would close the window out from under a half-finished
    /// 确认发送 and discard what the sheet was asking about.
    func testAnAttachedSheetKeepsEscape() {
        for target: KeyboardShortcutPolicy.Target in [.island, .workspace] {
            XCTAssertNil(
                KeyboardShortcutPolicy.action(
                    keyCode: 53, characters: "\u{1B}", modifiers: [],
                    target: target, hasAttachedSheet: true
                ),
                "\(target) must not act while a sheet is up"
            )
        }
    }

    func testOrdinaryKeysAreNeverConsumed() {
        for (code, characters) in [(0 as UInt16, "a"), (49, " "), (36, "\r"), (48, "\t")] {
            XCTAssertNil(
                KeyboardShortcutPolicy.action(
                    keyCode: code, characters: characters, modifiers: [],
                    target: .island, hasAttachedSheet: false
                )
            )
        }
    }

    // MARK: - The monitor must not shadow the menu bar

    /// The rule, asserted against the shipped source: the key monitor claims
    /// cancel only. If a future edit teaches it a ⌘-chord, that chord silently
    /// stops reaching the menu item that advertises it — which is how ⌘1 and
    /// ⌘, were broken.
    func testKeyMonitorClaimsNoCommandChord() throws {
        let source = try appSource("AppDelegate.swift")
        guard let start = source.range(of: "private func handleKeyDown") else {
            return XCTFail("handleKeyDown is gone; this gate needs rewriting, not deleting")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    }")?.upperBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertTrue(
            body.contains("KeyboardShortcutPolicy.action("),
            "handleKeyDown no longer asks the policy; the rule moved somewhere untested"
        )
        // Passing the characters *to* the policy is fine — that is how ⌘. is
        // recognised. Branching on them here is not: that is the shape that
        // stole ⌘1 and ⌘, from the menu bar.
        XCTAssertFalse(
            body.contains("switch event.charactersIgnoringModifiers"),
            "handleKeyDown branches on the typed character again, which is how it stole ⌘1 / ⌘, from the menu bar"
        )
        XCTAssertFalse(
            body.contains("case \"1\""),
            "handleKeyDown claims ⌘1, which 显示 > 打开 WeChatHUD advertises"
        )
        XCTAssertFalse(
            body.contains("event.modifierFlags.contains(.command)"),
            "handleKeyDown gates on ⌘ again; cancel is the only thing it may claim"
        )
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/App/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
