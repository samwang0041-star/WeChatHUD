import XCTest
import AppKit
@testable import WeChatHUD

/// The menu bar is built by `MainMenu` and asserted item by item by
/// `MainMenuTests` — and for a while it was never *installed*.
///
/// `configureMainMenu()` was written, documented, and never called from any
/// launch hook. A menu-bar app with no `NSApp.mainMenu` shows its own name and
/// nothing else, so 关于 / 服务 / 重做 / ⌃⌘S did not exist on screen while every
/// assertion about them passed. Measured on the running app:
///
/// - without the call: `mainMenu=` (empty)
/// - with it: `mainMenu=WeChatHUD|文件|编辑|显示|窗口|帮助`
///
/// This is the "both ends are correct, the wire between them is missing" shape
/// that a previous QA round already caught once in the key-file diagnostics.
/// The gate is a source scan because the defect is *absence of a call*, which
/// no amount of testing the thing itself can reveal.
final class MainMenuWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/App/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The delegate must install the menu from a launch hook that runs before
    /// any window is shown.
    func testTheDelegateInstallsTheMainMenuOnLaunch() throws {
        let text = try source("AppDelegate.swift")
        let hooks = ["applicationWillFinishLaunching", "applicationDidFinishLaunching"]
        let calledFromAHook = hooks.contains { hook in
            guard let range = text.range(of: "func \(hook)(") else { return false }
            let body = Self.body(ofFunctionAt: range.lowerBound, in: text)
            return Self.containsStatement(body, "configureMainMenu()")
        }
        XCTAssertTrue(
            calledFromAHook,
            """
            no launch hook calls configureMainMenu(). The menu bar is then empty: \
            the app shows its own name and none of 关于 / 服务 / 重做 / ⌃⌘S exist.
            """
        )
    }

    /// The source text of one function: from its declaration to the next
    /// function declaration at any visibility.
    ///
    /// The first version searched for the literal `"\n    func "`, which misses
    /// `private func`, `@objc func` and every other modifier — so the hook's
    /// "body" ran on for hundreds of lines and swallowed the *definition* of
    /// `configureMainMenu`. The gate then passed against the exact defect it
    /// was written for. Two rounds of that: a plain `contains` first matched a
    /// commented-out call, then an over-long body matched the declaration.
    /// A gate has to be run against the bug, not just written.
    static func body(ofFunctionAt start: String.Index, in text: String) -> String {
        let rest = text[start...]
        let pattern = try? NSRegularExpression(
            pattern: #"\n    (?:@objc |private |static |final |override )*func "#,
            options: []
        )
        let searchRange = NSRange(rest.startIndex..<rest.endIndex, in: text)
        let end = pattern?.firstMatch(in: text, options: [], range: searchRange)
            .map { Range($0.range, in: text)!.lowerBound } ?? rest.endIndex
        return String(rest[..<end])
    }

    /// True when `needle` appears as a *statement*: a line of its own, not a
    /// comment and not the tail of a declaration.
    static func containsStatement(_ body: String, _ needle: String) -> Bool {
        body.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == needle
        }
    }

    /// …and that hook must build the menu through `MainMenu`, not by hand.
    func testTheMenuIsBuiltByMainMenuAndHandedToAppKit() throws {
        let text = try source("AppDelegate.swift")
        guard let range = text.range(of: "private func configureMainMenu()") else {
            return XCTFail("configureMainMenu is gone; this gate needs rewriting, not deleting")
        }
        let body = Self.body(ofFunctionAt: range.lowerBound, in: text)
        XCTAssertTrue(body.contains("MainMenu.build(target:"), "the menu is built by hand again")
        XCTAssertTrue(body.contains("NSApp.mainMenu ="), "the built menu is never handed to AppKit")
        // Each of the three needs its own handshake: AppKit discovers services,
        // appends the window list, and attaches the Help search field only for
        // menus it is told about separately.
        for assignment in ["NSApp.servicesMenu =", "NSApp.windowsMenu =", "NSApp.helpMenu ="] {
            XCTAssertTrue(body.contains(assignment), "\(assignment) is missing")
        }
    }

    /// 设置… must not force a page.
    ///
    /// ⌘, opens the settings window — that is its whole contract on macOS. It
    /// used to also jump to 微信连接, so pressing it from 待办 threw away the
    /// page the user was on and dropped them into a connection screen. ⌘? is
    /// `openGuide`, a destination *named by its own item*, and picking a page
    /// there is correct; the difference is the menu title.
    func testTheSettingsItemDoesNotHijackTheCurrentPage() throws {
        let text = try source("AppDelegate.swift")
        guard let range = text.range(of: "@objc func openPreferences()") else {
            return XCTFail("openPreferences is gone")
        }
        let body = Self.body(ofFunctionAt: range.lowerBound, in: text)
        XCTAssertFalse(
            body.contains("pendingSettingsTab"),
            "设置… forces a tab, so ⌘, is a navigation action instead of \"open settings\""
        )
        XCTAssertTrue(body.contains("panelState.showDetail()"), "设置… no longer opens the window")
    }

    /// The on-screen menu and the tests must not be able to drift: the titles
    /// the bar shows are asserted to be the ones `MainMenu` builds.
    func testEveryTopLevelMenuTitleIsNonEmpty() {
        let registration = MainMenu.build(target: NSObject())
        XCTAssertEqual(registration.menu.items.count, 6)
        for item in registration.menu.items {
            XCTAssertFalse(item.title.isEmpty, "a menu-bar item with no title is a blank slot")
            XCTAssertNotNil(item.submenu, "\(item.title) is a leaf, so nothing can be reached through it")
        }
    }
}
