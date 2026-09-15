import XCTest
import AppKit
@testable import WeChatHUD

/// Proves the menu reaches `NSApp` — not that it is *correct* (`MainMenuTests`
/// covers that) and not that the call exists in source (`MainMenuWiringTests`
/// covers that), but that after the launch hook runs, the application really
/// has a menu bar with the standard rows in it.
///
/// The distinction matters because the first two gates were both green while
/// the app shipped with a one-item menu bar. A source scan can be satisfied by
/// a call the compiler never links; building the tree proves nothing about
/// whether anyone installed it. Only running the hook against the real
/// `NSApplication` closes the loop.
@MainActor
final class MainMenuInstallationTests: XCTestCase {

    private var savedMenu: NSMenu?
    private var savedServices: NSMenu?
    private var savedWindows: NSMenu?
    private var savedHelp: NSMenu?

    override func setUp() {
        super.setUp()
        // The test bundle is not an app, so `NSApp` is nil until something
        // asks for the shared instance. Materialising it here is also what
        // makes this a real test of the installation path rather than of a
        // dictionary: `NSApp.mainMenu` only exists once there is an NSApp.
        _ = NSApplication.shared
        savedMenu = NSApp.mainMenu
        savedServices = NSApp.servicesMenu
        savedWindows = NSApp.windowsMenu
        savedHelp = NSApp.helpMenu
    }

    override func tearDown() {
        NSApp.mainMenu = savedMenu
        NSApp.servicesMenu = savedServices
        NSApp.windowsMenu = savedWindows
        NSApp.helpMenu = savedHelp
        super.tearDown()
    }

    func testLaunchHookInstallsTheMenuBarTheUserActuallySees() {
        // Start from the state a fresh accessory app is in.
        NSApp.mainMenu = nil
        NSApp.servicesMenu = nil
        NSApp.windowsMenu = nil
        NSApp.helpMenu = nil

        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        let titles = (NSApp.mainMenu?.items ?? []).map(\.title)
        XCTAssertEqual(
            titles,
            [MainMenu.Title.app, MainMenu.Title.file, MainMenu.Title.edit,
             MainMenu.Title.view, MainMenu.Title.window, MainMenu.Title.help],
            "the installed menu bar is not the standard macOS bar"
        )

        // The three menus AppKit has to be handed separately. Asserting the
        // identity rather than merely non-nil: registering a *different*
        // NSMenu instance produces a Services menu that never populates and a
        // Window menu with no window list, which looks fine in a screenshot.
        XCTAssertTrue(
            NSApp.servicesMenu === menu(titled: MainMenu.Title.services, in: NSApp.mainMenu),
            "NSApp.servicesMenu is not the 服务 submenu that is in the bar"
        )
        XCTAssertTrue(
            NSApp.windowsMenu === menu(titled: MainMenu.Title.window, in: NSApp.mainMenu),
            "NSApp.windowsMenu is not the 窗口 submenu that is in the bar"
        )
        XCTAssertTrue(
            NSApp.helpMenu === menu(titled: MainMenu.Title.help, in: NSApp.mainMenu),
            "NSApp.helpMenu is not the 帮助 submenu that is in the bar"
        )
    }

    /// The specific rows whose absence is invisible: no error, no log line,
    /// just a menu that stops halfway through the standard list.
    func testTheRowsThatWereMissingAreOnTheInstalledBar() {
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        let bar = NSApp.mainMenu
        let app = menu(titled: MainMenu.Title.app, in: bar)
        let edit = menu(titled: MainMenu.Title.edit, in: bar)
        let view = menu(titled: MainMenu.Title.view, in: bar)

        for (title, owner) in [
            (MainMenu.Title.about, app),
            (MainMenu.Title.services, app),
            (MainMenu.Title.hide, app),
            (MainMenu.Title.hideOthers, app),
            (MainMenu.Title.showAll, app),
            (MainMenu.Title.redo, edit),
            (MainMenu.Title.find, edit),
            (MainMenu.Title.toggleSidebar, view),
            (MainMenu.Title.enterFullScreen, view)
        ] {
            XCTAssertNotNil(
                owner?.items.first { $0.title == title },
                "\(title) is not on the installed menu bar"
            )
        }
    }

    private func menu(titled title: String, in root: NSMenu?) -> NSMenu? {
        guard let root else { return nil }
        if root.title == title { return root }
        for item in root.items {
            if let found = menu(titled: title, in: item.submenu) { return found }
        }
        return nil
    }
}
