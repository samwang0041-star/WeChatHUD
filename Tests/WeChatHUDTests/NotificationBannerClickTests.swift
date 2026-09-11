import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Click contract for the notification banner, exercised with real AppKit
/// mouse events against the real view.
///
/// The redesign removed the visible "看看什么事" text action and gave the whole
/// card the open action instead. That is only safe if a click on 稍后/关闭 still
/// does exactly one thing: the previous revision dropped the body action
/// precisely because it could not guarantee that. These tests drive the banner
/// the way the user does — a mouse down/up at a point — and assert on the state
/// the panel actually ends up in.
@MainActor
final class NotificationBannerClickTests: XCTestCase {

    private struct Fixture {
        let store: HUDStore
        let monitor: ChatMonitor
        let panelState: PanelState
        let root: String
        let window: NSWindow
    }

    private let notchHeight: CGFloat = 32
    private var bannerWidth: CGFloat { IslandNotificationLayout.panelWidth(notchWidth: 200) }

    private func makeFixture() throws -> Fixture {
        let root = NSTemporaryDirectory() + "notification-banner-click-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        let panelState = PanelState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: bannerWidth, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return Fixture(store: store, monitor: monitor, panelState: panelState, root: root, window: window)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.window.orderOut(nil)
        fixture.store.close()
        try? FileManager.default.removeItem(atPath: fixture.root)
    }

    /// Host the banner in a real window and lay it out, so AppKit hit-testing
    /// and SwiftUI's gesture recognisers both see a live view tree.
    private func host(_ fixture: Fixture, notification: HUDNotification, height: CGFloat) {
        let root = NotificationBannerView(notification: notification)
            .environmentObject(fixture.monitor)
            .environmentObject(fixture.panelState)
            .frame(width: bannerWidth, height: height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: bannerWidth, height: height)
        fixture.window.contentView = hosting
        fixture.window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        hosting.layoutSubtreeIfNeeded()
        pump()
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Click at a point in the window's coordinate space (origin bottom-left,
    /// the AppKit convention the banner's layout has to be flipped into).
    private func click(_ fixture: Fixture, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                XCTFail("could not synthesise a mouse event")
                return
            }
            fixture.window.sendEvent(event)
            pump(0.03)
        }
        pump()
    }

    private func notification(_ kind: HUDNotificationKind = .groupAt,
                              message: String = "明天下午评审，能否确认待办责任人的展示方案？") -> HUDNotification {
        HUDNotification(
            chatUsername: "wxid-click-fixture",
            chatName: "项目协作群",
            senderUsername: "wxid-peer",
            senderName: "林晓",
            attentionLevel: .vip,
            messageID: "click-\(UUID().uuidString)",
            rawText: message,
            snippet: message,
            isAtMention: true,
            timestamp: Date(),
            kind: kind
        )
    }

    /// Points in the banner's own top-left coordinate space, expressed as
    /// AppKit window coordinates (y measured from the bottom).
    private func windowPoint(x: CGFloat, fromTop y: CGFloat, height: CGFloat) -> NSPoint {
        NSPoint(x: x, y: height - y)
    }

    // MARK: - Tests

    /// The message is the page, so the message is the button: clicking the
    /// text itself must open what the body action promises.
    func testClickingTheMessageOpensTheBriefingForAGroupMention() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = notification()
        fixture.panelState.isReady = true
        fixture.panelState.showNotification(duration: 30)
        let height: CGFloat = 101
        host(fixture, notification: notification, height: height)

        // Middle of the message block: below the identity line, above the
        // bottom padding.
        click(fixture, at: windowPoint(x: bannerWidth / 2, fromTop: notchHeight + 45, height: height))

        XCTAssertTrue(
            fixture.panelState.briefingExpanded,
            "a click on the message must open the in-place briefing for a group @"
        )
    }

    /// …and for anything that is not a group mention it opens the conversation.
    func testClickingTheMessageOpensTheConversationForAPrivateChat() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = notification(.privateChat)
        fixture.panelState.isReady = true
        fixture.panelState.showNotification(duration: 30)
        let height: CGFloat = 101
        host(fixture, notification: notification, height: height)

        click(fixture, at: windowPoint(x: bannerWidth / 2, fromTop: notchHeight + 45, height: height))

        XCTAssertFalse(fixture.panelState.briefingExpanded)
        XCTAssertEqual(
            fixture.panelState.currentState, .detail,
            "a click on the message of a private-chat banner must open the conversation"
        )
    }

    /// The dangerous case: 关闭 must close, and nothing else.
    func testClickingCloseDismissesWithoutOpeningAnything() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = notification()
        fixture.panelState.isReady = true
        fixture.panelState.showNotification(duration: 30)
        let height: CGFloat = 101
        host(fixture, notification: notification, height: height)

        // The close glyph is the last 24 pt-wide control on the identity line:
        // 16 pt trailing inset, 24 pt wide, centred on the 22 pt line that
        // starts 10 pt below the notch.
        let closeX = bannerWidth - IslandMetrics.bannerInset - 12
        click(fixture, at: windowPoint(x: closeX, fromTop: notchHeight + IslandMetrics.bannerTopGap + 11, height: height))

        XCTAssertFalse(
            fixture.panelState.briefingExpanded,
            "closing the banner must not also open the briefing — a quick action has exactly one effect"
        )
        XCTAssertNotEqual(
            fixture.panelState.currentState, .detail,
            "closing the banner must not also open the conversation"
        )
        XCTAssertEqual(
            fixture.panelState.currentState, .compact,
            "关闭 collapses the island"
        )
    }

    /// 稍后提醒 opens the time menu and nothing else — in particular it must not
    /// fall through to the card's open action.
    func testClickingSnoozeOpensTheMenuWithoutOpeningAnything() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = notification()
        fixture.panelState.isReady = true
        fixture.panelState.showNotification(duration: 30)
        let height: CGFloat = 101
        host(fixture, notification: notification, height: height)

        let snoozeX = bannerWidth - IslandMetrics.bannerInset - 24 - 7 - 12
        click(fixture, at: windowPoint(x: snoozeX, fromTop: notchHeight + IslandMetrics.bannerTopGap + 11, height: height))

        XCTAssertTrue(fixture.panelState.snoozeMenuExpanded, "稍后提醒 expands the snooze menu")
        XCTAssertFalse(fixture.panelState.briefingExpanded, "the snooze click must not open the card action")
        XCTAssertNotEqual(fixture.panelState.currentState, .detail)
    }
}
