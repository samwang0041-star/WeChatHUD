import AppKit

extension Notification.Name {
    /// ⌃⌘S from the 显示 menu. The workspace owns the split view's column
    /// visibility, so the menu item asks rather than commands.
    static let hudToggleSidebar = Notification.Name("WeChatHUD.ToggleSidebar")
}

/// The application's main menu, built to the macOS standard.
///
/// Why this is its own file rather than four lines inside `AppDelegate`: the
/// menu bar is the one piece of UI a Mac user reads *before* looking at the
/// window, and it is the only surface in this app that macOS itself specifies
/// item by item. Keeping it declarative makes the structure assertable in a
/// test (`MainMenuTests`) instead of only observable by opening the app and
/// squinting at the screen.
///
/// What was wrong before (all four are HIG requirements, not preferences):
///
/// 1. **No 关于 / 服务 / 隐藏.** `NSApp.mainMenu` was assigned by hand, which
///    switches off every automatic item AppKit would otherwise supply. Without
///    a Services menu the app cannot receive text from other apps at all —
///    for a clipboard-adjacent product that is a missing feature, not a
///    missing menu row.
/// 2. **⌘W lived in 窗口.** Every Mac since 1984 has Close in the File menu.
/// 3. **No 显示 menu** and therefore no 显示/隐藏边栏 (⌃⌘S) or 进入全屏幕 (⌃⌘F),
///    both of which users reach for without looking.
/// 4. **No 重做 (⇧⌘Z)** and no Find, so the Edit menu stopped halfway through
///    the standard list — a user who hit ⇧⌘Z after ⌘Z got nothing.
struct MainMenu {

    /// The menus AppKit has to be told about separately from `mainMenu`:
    /// Services, Windows and Help each get special treatment from the system
    /// (service discovery, the automatic window list, and the Help search
    /// field), and none of it happens unless the app registers them.
    struct Registration {
        let menu: NSMenu
        let services: NSMenu
        let windows: NSMenu
        let help: NSMenu
    }

    /// Titles, in one place, so the tests and the builder cannot drift.
    enum Title {
        static let app = CompanionProductCopy.brandName
        static let about = "关于 \(CompanionProductCopy.brandName)"
        static let settings = "设置…"
        static let updates = CompanionProductCopy.checkUpdates
        static let services = "服务"
        static let hide = "隐藏 \(CompanionProductCopy.brandName)"
        static let hideOthers = "隐藏其他"
        static let showAll = "全部显示"
        static let quit = CompanionProductCopy.quitCompanion

        static let file = "文件"
        static let close = "关闭窗口"

        static let edit = "编辑"
        static let undo = "撤销"
        static let redo = "重做"
        static let cut = "剪切"
        static let copy = "复制"
        static let paste = "粘贴"
        static let pasteAndMatchStyle = "粘贴并匹配样式"
        static let delete = "删除"
        static let selectAll = "全选"
        static let find = "查找"
        static let findEllipsis = "查找…"

        static let view = "显示"
        static let toggleSidebar = "显示/隐藏边栏"
        static let refresh = "刷新消息"
        static let openCompanion = CompanionProductCopy.openCompanion
        static let enterFullScreen = "进入全屏幕"

        static let window = "窗口"
        static let minimize = "最小化"
        static let zoom = "缩放"
        static let arrangeInFront = "全部置于顶层"

        static let help = "帮助"
        static let guide = CompanionProductCopy.howToUse
    }

    /// The selector names macOS reserves for each standard item. Using the
    /// documented selectors (rather than app-specific ones) is what makes the
    /// items route through the responder chain, light up only when a responder
    /// can actually handle them, and get the system's own localisation of the
    /// key equivalents.
    private enum Selector_ {
        static let about = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        static let hide = #selector(NSApplication.hide(_:))
        static let hideOthers = #selector(NSApplication.hideOtherApplications(_:))
        static let showAll = #selector(NSApplication.unhideAllApplications(_:))
        static let close = #selector(NSWindow.performClose(_:))
        static let undo = NSSelectorFromString("undo:")
        static let redo = NSSelectorFromString("redo:")
        static let cut = #selector(NSText.cut(_:))
        static let copy = #selector(NSText.copy(_:))
        static let paste = #selector(NSText.paste(_:))
        static let pasteAndMatchStyle = NSSelectorFromString("pasteAsPlainText:")
        static let delete = #selector(NSText.delete(_:))
        static let selectAll = #selector(NSText.selectAll(_:))
        static let find = #selector(NSResponder.performTextFinderAction(_:))
        static let minimize = #selector(NSWindow.performMiniaturize(_:))
        static let zoom = #selector(NSWindow.performZoom(_:))
        static let arrangeInFront = #selector(NSApplication.arrangeInFront(_:))
        static let toggleFullScreen = #selector(NSWindow.toggleFullScreen(_:))
    }

    /// `NSTextFinder.Action` cases the Find submenu drives.
    private enum FindAction {
        static let show = 1
        static let next = 2
        static let previous = 3
    }

    static func build(target: AnyObject) -> Registration {
        let main = NSMenu()
        main.autoenablesItems = true

        let appMenu = NSMenu(title: Title.app)
        add(to: appMenu, Title.about, Selector_.about, target: NSApp)
        appMenu.addItem(.separator())
        add(to: appMenu, Title.settings, #selector(AppDelegate.openPreferences), key: ",", target: target)
        add(to: appMenu, Title.updates, #selector(AppDelegate.checkForUpdates), target: target)
        appMenu.addItem(.separator())

        let services = NSMenu(title: Title.services)
        let servicesItem = NSMenuItem(title: Title.services, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        add(to: appMenu, Title.hide, Selector_.hide, key: "h", target: NSApp)
        // ⌥⌘H, the standard Hide Others chord.
        add(to: appMenu, Title.hideOthers, Selector_.hideOthers, key: "h",
            modifiers: [.command, .option], target: NSApp)
        add(to: appMenu, Title.showAll, Selector_.showAll, target: NSApp)
        appMenu.addItem(.separator())
        add(to: appMenu, Title.quit, #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        main.addItem(submenu(appMenu))

        let fileMenu = NSMenu(title: Title.file)
        add(to: fileMenu, Title.close, Selector_.close, key: "w")
        main.addItem(submenu(fileMenu))

        let edit = editMenu()
        let view = viewMenu(target: target)
        let window = windowMenu()
        let help = helpMenu(target: target)
        main.addItem(submenu(edit))
        main.addItem(submenu(view))
        main.addItem(submenu(window))
        main.addItem(submenu(help))

        return Registration(menu: main, services: services, windows: window, help: help)
    }

    // MARK: - Menus

    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: Title.edit)
        add(to: edit, Title.undo, Selector_.undo, key: "z")
        // ⇧⌘Z. Absent before this pass, which meant the single most-used undo
        // pair on macOS worked in exactly one direction.
        add(to: edit, Title.redo, Selector_.redo, key: "Z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(to: edit, Title.cut, Selector_.cut, key: "x")
        add(to: edit, Title.copy, Selector_.copy, key: "c")
        add(to: edit, Title.paste, Selector_.paste, key: "v")
        add(to: edit, Title.pasteAndMatchStyle, Selector_.pasteAndMatchStyle, key: "v",
            modifiers: [.command, .option, .shift])
        add(to: edit, Title.delete, Selector_.delete)
        add(to: edit, Title.selectAll, Selector_.selectAll, key: "a")
        edit.addItem(.separator())

        // Find. Routes to whatever text finder is live; greyed out when
        // nothing in the responder chain offers one, which is the correct
        // macOS behaviour and better than a hand-rolled always-on item.
        let findItem = NSMenuItem(title: Title.find, action: nil, keyEquivalent: "")
        let find = NSMenu(title: Title.find)
        add(to: find, Title.findEllipsis, Selector_.find, key: "f", tag: FindAction.show)
        add(to: find, "查找下一个", Selector_.find, key: "g", tag: FindAction.next)
        add(to: find, "查找上一个", Selector_.find, key: "G",
            modifiers: [.command, .shift], tag: FindAction.previous)
        findItem.submenu = find
        edit.addItem(findItem)
        return edit
    }

    private static func viewMenu(target: AnyObject) -> NSMenu {
        let view = NSMenu(title: Title.view)
        add(to: view, Title.openCompanion, #selector(AppDelegate.toggleCompanionFromMenu),
            key: "1", target: target)
        add(to: view, Title.refresh, #selector(AppDelegate.refreshNow), key: "r", target: target)
        view.addItem(.separator())
        // ⌃⌘S. The workspace is a NavigationSplitView; the action is forwarded
        // to the live SwiftUI window rather than toggled here, because only the
        // view knows its current column visibility.
        add(to: view, Title.toggleSidebar, #selector(AppDelegate.toggleSidebar), key: "s",
            modifiers: [.command, .control], target: target)
        view.addItem(.separator())
        add(to: view, Title.enterFullScreen, Selector_.toggleFullScreen, key: "f",
            modifiers: [.command, .control])
        return view
    }

    private static func windowMenu() -> NSMenu {
        let window = NSMenu(title: Title.window)
        add(to: window, Title.minimize, Selector_.minimize, key: "m")
        add(to: window, Title.zoom, Selector_.zoom)
        window.addItem(.separator())
        add(to: window, Title.arrangeInFront, Selector_.arrangeInFront, target: NSApp)
        return window
    }

    private static func helpMenu(target: AnyObject) -> NSMenu {
        let help = NSMenu(title: Title.help)
        add(to: help, Title.guide, #selector(AppDelegate.openGuide), key: "?", target: target)
        return help
    }

    // MARK: - Item helpers

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Adds one item. `target` stays nil unless given, which is what puts the
    /// item on the responder chain and lets AppKit enable it only when a
    /// responder implements the selector.
    @discardableResult
    private static func add(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        tag: Int = 0,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.tag = tag
        item.target = target
        menu.addItem(item)
        return item
    }
}
