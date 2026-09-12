import XCTest
@testable import WeChatHUD

/// 稍后提醒 on the notification banner.
///
/// A failed snooze used to run the same `goExtended()` as a saved one: the
/// banner vanished into the inbox, the memo was never written, and a toast was
/// the only trace of an action that did not happen. A failed write now leaves
/// the user exactly where they were, with the same control as the retry entry.
@MainActor
final class BannerSnoozeFailureTests: XCTestCase {

    func testAFailedSnoozeKeepsTheBannerAndExplainsWhy() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = groupNotification()
        fixture.panelState.isReady = true
        fixture.panelState.showNotification(duration: 30)
        fixture.store.close()   // the snooze row cannot be written

        let handedOff = NotificationBannerView.applySnooze(
            Date().addingTimeInterval(3600),
            notification: notification,
            monitor: fixture.monitor,
            panelState: fixture.panelState
        )

        XCTAssertFalse(handedOff)
        XCTAssertEqual(fixture.panelState.currentState, .notification, "失败的稍后提醒不能把用户带去收件箱")
        XCTAssertNil(fixture.panelState.islandSnoozeUndo, "没落库就没有可撤销的收据")
        XCTAssertNotNil(fixture.monitor.inboxActionError)
        let toast = try XCTUnwrap(fixture.panelState.toastMessage, "失败必须留下可见说明")
        XCTAssertTrue(toast.contains("稍后提醒"), "说明要说清是哪件事没成，实际 \(toast)")
    }

    func testASavedSnoozeStillHandsOffToTheInbox() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = groupNotification()
        fixture.panelState.isReady = true
        fixture.panelState.showNotification(duration: 30)

        let handedOff = NotificationBannerView.applySnooze(
            Date().addingTimeInterval(3600),
            notification: notification,
            monitor: fixture.monitor,
            panelState: fixture.panelState
        )

        XCTAssertTrue(handedOff)
        XCTAssertEqual(fixture.panelState.currentState, .extended, "存下来的稍后提醒才把用户带到收件箱")
        XCTAssertEqual(fixture.panelState.islandSurface, .inbox)
        XCTAssertNotNil(fixture.panelState.islandSnoozeUndo, "存下来就要能撤销")
        XCTAssertNil(fixture.monitor.inboxActionError)
        let toast = try XCTUnwrap(fixture.panelState.toastMessage)
        XCTAssertTrue(toast.contains("已安排"), "成功要有回执，实际 \(toast)")
    }

    /// The briefing card's 稍后提醒 shares the same receipt: a failed write must
    /// not look like a completed action there either.
    func testTheBriefingCardSnoozeUsesTheSameReceipt() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = groupNotification()
        fixture.store.close()

        let applied = IslandSnoozeOutcome.apply(
            notification.actionInboxItem(),
            until: Date().addingTimeInterval(3600),
            monitor: fixture.monitor,
            panelState: fixture.panelState
        )

        XCTAssertFalse(applied)
        XCTAssertNil(fixture.panelState.islandSnoozeUndo)
        let toast = try XCTUnwrap(fixture.panelState.toastMessage)
        XCTAssertTrue(toast.contains("稍后提醒"))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: HUDStore
        let monitor: ChatMonitor
        let panelState: PanelState
        let root: String
    }

    private func makeFixture() throws -> Fixture {
        let root = NSTemporaryDirectory() + "banner-snooze-failure-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        return Fixture(store: store, monitor: monitor, panelState: PanelState(), root: root)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.store.close()
        try? FileManager.default.removeItem(atPath: fixture.root)
    }

    private func groupNotification() -> HUDNotification {
        HUDNotification(
            chatUsername: "wxid-snooze-failure",
            chatName: "项目协作群",
            senderUsername: "wxid-peer",
            senderName: "林晓",
            attentionLevel: .vip,
            messageID: "snooze-\(UUID().uuidString)",
            rawText: "@我 明天下午评审",
            snippet: "明天下午评审",
            isAtMention: true,
            timestamp: Date(),
            kind: .groupAt
        )
    }
}
