import XCTest
import AppKit
@testable import WeChatHUD

/// The main menu is the one surface macOS specifies item by item, and the one
/// this app got wrong for the longest time — not by drawing it badly, but by
/// never building the parts it was supposed to have.
///
/// These assert the structure, because the failure mode is silent: a missing
/// 服务 menu produces no error, no log line and no visual glitch. It simply
/// means the app cannot receive text from any other app, forever.
final class MainMenuTests: XCTestCase {

    private var registration: MainMenu.Registration!

    override func setUp() {
        super.setUp()
        registration = MainMenu.build(target: NSObject())
    }

    // MARK: - Helpers

    private var submenus: [NSMenu] {
        registration.menu.items.compactMap(\.submenu)
    }

    private func menu(titled title: String) -> NSMenu? {
        submenus.first { $0.title == title }
    }

    private func item(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        menu?.items.first { $0.title == title }
    }

    // MARK: - Shape

    /// A menu-bar item with an empty title is a blank, unclickable slot. The
    /// previous builder set submenu titles only on some items.
    func testEveryMenuBarItemIsTitled() {
        for item in registration.menu.items {
            XCTAssertFalse(
                item.title.isEmpty,
                "a menu bar item with no title renders as a blank slot"
            )
        }
    }

    /// The order macOS users have in their hands: App, File, Edit, View,
    /// Window, Help. 帮助 must be last — AppKit keys the Help search field off
    /// that position.
    func testMenuBarOrderMatchesTheSystemConvention() {
        XCTAssertEqual(
            submenus.map(\.title),
            [MainMenu.Title.app, MainMenu.Title.file, MainMenu.Title.edit,
             MainMenu.Title.view, MainMenu.Title.window, MainMenu.Title.help]
        )
    }

    func testSeparatorsNeverLeadOrTrailAMenu() {
        for menu in submenus {
            let titles = menu.items.map(\.title)
            XCTAssertNotEqual(
                menu.items.first?.isSeparatorItem, true,
                "\(menu.title) starts with a separator"
            )
            XCTAssertNotEqual(
                menu.items.last?.isSeparatorItem, true,
                "\(menu.title) ends with a separator"
            )
            // Two separators in a row read as a rendering fault.
            XCTAssertFalse(
                zip(titles, titles.dropFirst()).contains { $0.isEmpty && $1.isEmpty },
                "\(menu.title) has a doubled separator"
            )
        }
    }

    /// Within one menu a chord may be claimed once. A duplicate silently
    /// shadows whichever item AppKit reaches second.
    func testNoChordIsClaimedTwiceInsideOneMenu() {
        for menu in submenus {
            var seen: [String: String] = [:]
            for item in menu.items where !item.keyEquivalent.isEmpty {
                let chord = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
                if let owner = seen[chord] {
                    XCTFail("\(menu.title): \(item.title) and \(owner) both claim \(chord)")
                }
                seen[chord] = item.title
            }
        }
    }

    // MARK: - Application menu

    /// The four rows the app menu is required to have. 服务 is the one with a
    /// functional consequence: without it WeChatHUD cannot appear in another
    /// app's 服务 submenu at all.
    func testApplicationMenuHasTheStandardRows() {
        let app = menu(titled: MainMenu.Title.app)
        XCTAssertNotNil(item(MainMenu.Title.about, in: app), "no 关于")
        XCTAssertNotNil(item(MainMenu.Title.settings, in: app), "no 设置…")
        XCTAssertNotNil(item(MainMenu.Title.services, in: app), "no 服务")
        XCTAssertNotNil(item(MainMenu.Title.hide, in: app), "no 隐藏")
        XCTAssertNotNil(item(MainMenu.Title.hideOthers, in: app), "no 隐藏其他")
        XCTAssertNotNil(item(MainMenu.Title.showAll, in: app), "no 全部显示")
        XCTAssertNotNil(item(MainMenu.Title.quit, in: app), "no 退出")
    }

    func testApplicationMenuChords() {
        let app = menu(titled: MainMenu.Title.app)
        XCTAssertEqual(item(MainMenu.Title.settings, in: app)?.keyEquivalent, ",")
        XCTAssertEqual(item(MainMenu.Title.hide, in: app)?.keyEquivalent, "h")
        XCTAssertEqual(
            item(MainMenu.Title.hideOthers, in: app)?.keyEquivalentModifierMask,
            [.command, .option],
            "隐藏其他 is ⌥⌘H on every Mac"
        )
        XCTAssertEqual(item(MainMenu.Title.quit, in: app)?.keyEquivalent, "q")
    }

    func testServicesMenuIsASubmenuNotALeaf() {
        let servicesItem = item(MainMenu.Title.services, in: menu(titled: MainMenu.Title.app))
        XCTAssertNotNil(servicesItem?.submenu, "服务 must be a submenu for AppKit to fill it")
        // AppKit rewrites a submenu parent's action to `submenuAction:` when
        // the submenu is attached. Anything else means the row would fire an
        // action instead of opening.
        XCTAssertEqual(
            servicesItem?.action, #selector(NSMenu.submenuAction(_:)),
            "服务 must open, not act"
        )
    }

    // MARK: - File menu

    /// ⌘W belongs in 文件. It used to live in 窗口, which is where no Mac puts
    /// it.
    func testCloseLivesInTheFileMenu() {
        let close = item(MainMenu.Title.close, in: menu(titled: MainMenu.Title.file))
        XCTAssertNotNil(close, "⌘W is not in 文件")
        XCTAssertEqual(close?.keyEquivalent, "w")
        XCTAssertNil(
            item(MainMenu.Title.close, in: menu(titled: MainMenu.Title.window)),
            "关闭窗口 must not also live in 窗口"
        )
    }

    // MARK: - Edit menu

    /// The pair that was half-missing. ⌘Z worked, ⇧⌘Z did nothing.
    func testUndoAndRedoAreBothPresent() {
        let edit = menu(titled: MainMenu.Title.edit)
        let undo = item(MainMenu.Title.undo, in: edit)
        let redo = item(MainMenu.Title.redo, in: edit)
        XCTAssertEqual(undo?.keyEquivalent, "z")
        XCTAssertEqual(redo?.keyEquivalent.lowercased(), "z")
        XCTAssertEqual(
            redo?.keyEquivalentModifierMask, [.command, .shift],
            "重做 is ⇧⌘Z"
        )
        XCTAssertNotEqual(undo?.action, redo?.action, "undo and redo cannot share a selector")
    }

    func testEditMenuCarriesTheTextEditingEssentials() {
        let edit = menu(titled: MainMenu.Title.edit)
        for (title, key) in [
            (MainMenu.Title.cut, "x"),
            (MainMenu.Title.copy, "c"),
            (MainMenu.Title.paste, "v"),
            (MainMenu.Title.selectAll, "a")
        ] {
            XCTAssertEqual(item(title, in: edit)?.keyEquivalent, key, "\(title) is missing or misfiled")
        }
        XCTAssertNotNil(item(MainMenu.Title.pasteAndMatchStyle, in: edit))
        XCTAssertNotNil(item(MainMenu.Title.delete, in: edit))
    }

    /// Find is a submenu, and its three rows carry the `NSTextFinder.Action`
    /// tags AppKit reads. Without the tags every row performs the same action.
    func testFindSubmenuCarriesTextFinderTags() {
        let findItem = item(MainMenu.Title.find, in: menu(titled: MainMenu.Title.edit))
        guard let find = findItem?.submenu else {
            return XCTFail("查找 is not a submenu")
        }
        XCTAssertEqual(find.items.map(\.tag), [1, 2, 3], "tags must be NSTextFinder.Action values")
        XCTAssertEqual(find.items.first?.keyEquivalent, "f")
        XCTAssertEqual(find.items[1].keyEquivalent, "g")
        XCTAssertEqual(find.items[2].keyEquivalentModifierMask, [.command, .shift])
        // Greyed out when nothing offers a finder — that is the correct macOS
        // behaviour, and it requires the item to be on the responder chain.
        XCTAssertTrue(find.items.allSatisfy { $0.target == nil })
    }

    // MARK: - View menu

    /// ⌃⌘S and ⌃⌘F are the two chords people press without looking.
    func testViewMenuHasSidebarAndFullScreen() {
        let view = menu(titled: MainMenu.Title.view)
        let sidebar = item(MainMenu.Title.toggleSidebar, in: view)
        XCTAssertEqual(sidebar?.keyEquivalent, "s")
        XCTAssertEqual(sidebar?.keyEquivalentModifierMask, [.command, .control])

        let fullScreen = item(MainMenu.Title.enterFullScreen, in: view)
        XCTAssertEqual(fullScreen?.keyEquivalent, "f")
        XCTAssertEqual(fullScreen?.keyEquivalentModifierMask, [.command, .control])
        XCTAssertNotNil(fullScreen?.action, "进入全屏幕 must target NSWindow.toggleFullScreen")
    }

    // MARK: - Window menu

    func testWindowMenuHasMinimizeZoomAndBringAllToFront() {
        guard let window = menu(titled: MainMenu.Title.window) else {
            return XCTFail("no 窗口 menu")
        }
        XCTAssertEqual(item(MainMenu.Title.minimize, in: window)?.keyEquivalent, "m")
        XCTAssertNotNil(item(MainMenu.Title.zoom, in: window), "no 缩放")
        XCTAssertNotNil(item(MainMenu.Title.arrangeInFront, in: window), "no 全部置于顶层")
        XCTAssertFalse(
            window.items.contains { $0.title == MainMenu.Title.quit },
            "退出 belongs to the app menu, not 窗口"
        )
    }

    // MARK: - Help menu

    func testHelpMenuOpensTheGuide() {
        let help = registration.help
        XCTAssertEqual(help.title, MainMenu.Title.help)
        XCTAssertEqual(item(MainMenu.Title.guide, in: help)?.keyEquivalent, "?")
        // 服务 hangs off the *app* menu, the other two off the bar, so the
        // check walks the whole tree rather than the top level.
        for (menu, name) in [
            (registration.help, "help"),
            (registration.windows, "windows"),
            (registration.services, "services")
        ] {
            XCTAssertTrue(
                contains(menu: menu, in: registration.menu),
                "the registered \(name) menu is not reachable from the menu bar"
            )
        }
    }

    /// Depth-first search for a menu instance inside the built tree.
    private func contains(menu target: NSMenu, in root: NSMenu, depth: Int = 0) -> Bool {
        guard depth < 6 else { return false }
        for item in root.items {
            guard let submenu = item.submenu else { continue }
            if submenu === target { return true }
            if contains(menu: target, in: submenu, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - The gap this closes

    /// The regression in one assertion: count the standard rows the old
    /// builder was missing. If a future edit deletes any of them this fails
    /// with the name attached.
    func testTheMenuIsNoLongerMissingTheStandardRows() {
        let required: [(String, NSMenu?)] = [
            (MainMenu.Title.about, menu(titled: MainMenu.Title.app)),
            (MainMenu.Title.services, menu(titled: MainMenu.Title.app)),
            (MainMenu.Title.hide, menu(titled: MainMenu.Title.app)),
            (MainMenu.Title.hideOthers, menu(titled: MainMenu.Title.app)),
            (MainMenu.Title.showAll, menu(titled: MainMenu.Title.app)),
            (MainMenu.Title.close, menu(titled: MainMenu.Title.file)),
            (MainMenu.Title.redo, menu(titled: MainMenu.Title.edit)),
            (MainMenu.Title.find, menu(titled: MainMenu.Title.edit)),
            (MainMenu.Title.delete, menu(titled: MainMenu.Title.edit)),
            (MainMenu.Title.toggleSidebar, menu(titled: MainMenu.Title.view)),
            (MainMenu.Title.enterFullScreen, menu(titled: MainMenu.Title.view)),
            (MainMenu.Title.zoom, menu(titled: MainMenu.Title.window)),
            (MainMenu.Title.arrangeInFront, menu(titled: MainMenu.Title.window))
        ]
        for (title, owner) in required {
            guard let owner else {
                XCTFail("missing menu for \(title)")
                continue
            }
            XCTAssertNotNil(item(title, in: owner), "\(title) is gone from the menu bar")
        }
    }
}
