import XCTest
@testable import WeChatHUD

/// 「开始整理」 must report what actually happened.
///
/// The popover used to call the fire-and-forget `startAutopilot()` and toast
/// 成功 on the next line, so a start whose store write failed still told the
/// user 「自动回复已开始整理」 while nothing was running.
@MainActor
final class AutopilotStartReceiptTests: XCTestCase {

    func testAFailedStartIsNeverReportedAsSuccess() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        fixture.store.close()   // the session row cannot be written

        let started = await fixture.monitor.startAutopilotAndWait()

        XCTAssertFalse(started, "落库失败时启动必须返回失败")
        XCTAssertFalse(fixture.monitor.autopilotActive, "失败的启动不能把 UI 切到运行中")

        let receipt = AutopilotStartReceipt.resolve(started: started)
        XCTAssertFalse(receipt.started)
        XCTAssertEqual(receipt.toast, AutopilotStartCopy.failed)
        XCTAssertNotEqual(receipt.toast, AutopilotStartCopy.started, "失败绝不能弹成功文案")
        XCTAssertFalse(receipt.dismissesPopover, "失败必须留下可重试的入口")
    }

    func testASuccessfulStartIsReportedAndHandsOff() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let started = await fixture.monitor.startAutopilotAndWait()

        XCTAssertTrue(started)
        XCTAssertTrue(fixture.monitor.autopilotActive)
        let receipt = AutopilotStartReceipt.resolve(started: started)
        XCTAssertEqual(receipt.toast, AutopilotStartCopy.started)
        XCTAssertTrue(receipt.dismissesPopover)
        fixture.monitor.stopAutopilot()
    }

    func testTheStartButtonNamesTheInFlightState() {
        XCTAssertEqual(AutopilotStartCopy.start, "开始整理")
        XCTAssertFalse(AutopilotStartCopy.starting.isEmpty)
        XCTAssertNotEqual(AutopilotStartCopy.starting, AutopilotStartCopy.start)
    }

    /// `.autopilot` is declared as a `DetailKind` with no other caller in the
    /// app: the popover's 「浮窗内查看」 is the entry that makes the in-island
    /// 待确认回复 pane reachable.
    func testThePopoverEntryRoutesTheDetailPanelToTheAutopilotPane() {
        let panelState = PanelState()

        AutopilotPopoverRouting.openPendingRepliesInPanel(panelState)

        XCTAssertEqual(panelState.detailKind, .autopilot)
        XCTAssertEqual(panelState.currentState, .detail)
        XCTAssertNil(panelState.selectedChatName)
        XCTAssertNil(panelState.selectedChatUsername)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: HUDStore
        let monitor: ChatMonitor
        let root: String
    }

    private func makeFixture() throws -> Fixture {
        let root = NSTemporaryDirectory() + "autopilot-start-receipt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        return Fixture(store: store, monitor: monitor, root: root)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.store.close()
        try? FileManager.default.removeItem(atPath: fixture.root)
    }
}
