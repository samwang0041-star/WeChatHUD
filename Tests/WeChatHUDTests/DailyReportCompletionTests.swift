import XCTest
@testable import WeChatHUD

final class DailyReportCompletionTests: XCTestCase {

    func testReplyDebtChatUsernamePrefersRelatedID() {
        let action = makeAction(relatedID: "wxid_debt", sourceChatUsername: "wxid_other")
        XCTAssertEqual(DailyReportCompletion.replyDebtChatUsername(for: action), "wxid_debt")
    }

    func testReplyDebtChatUsernameFallsBackToSourceChat() {
        let action = makeAction(relatedID: "", sourceChatUsername: "wxid_source")
        XCTAssertEqual(DailyReportCompletion.replyDebtChatUsername(for: action), "wxid_source")
    }

    func testDismissTimestampUsesDebtTimestamp() {
        let debt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        XCTAssertEqual(
            DailyReportCompletion.replyDebtDismissTimestamp(debtTimestamp: debt, now: now),
            1_700_000_000
        )
    }

    func testDismissTimestampFallsBackToNowWhenDebtIsMissing() {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        XCTAssertEqual(
            DailyReportCompletion.replyDebtDismissTimestamp(debtTimestamp: nil, now: now),
            1_700_000_500
        )
    }

    func testDebtWatermarkHidesCurrentInboxRow() {
        let debtTs = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let watermark = DailyReportCompletion.replyDebtDismissTimestamp(debtTimestamp: debtTs, now: now)
        let debt = makeDebt(timestamp: debtTs)

        let result = InboxBuilder.build(
            replyDebtItems: [debt],
            notifications: [],
            dismissed: [debt.chatUsername: Int64(watermark)],
            snoozed: [:],
            silenced: []
        )

        XCTAssertTrue(result.active.isEmpty, "current debt must leave the live inbox")
        XCTAssertEqual(result.handled.map(\.chatUsername), [debt.chatUsername])
        XCTAssertEqual(result.handled.first?.status, .dismissed)
    }

    func testNewerInboundResurfacesAfterDailyReportDismiss() {
        let originalDebtTs = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let watermark = DailyReportCompletion.replyDebtDismissTimestamp(
            debtTimestamp: originalDebtTs,
            now: now
        )
        let newerDebt = makeDebt(timestamp: Date(timeIntervalSince1970: 1_700_000_200))

        let result = InboxBuilder.build(
            replyDebtItems: [newerDebt],
            notifications: [],
            dismissed: [newerDebt.chatUsername: Int64(watermark)],
            snoozed: [:],
            silenced: []
        )

        XCTAssertEqual(result.active.map(\.chatUsername), [newerDebt.chatUsername])
        XCTAssertTrue(result.handled.isEmpty)
    }

    @MainActor
    func testMarkReplyDebtDoneClearsLiveInboxWithDebtWatermark() async throws {
        let (store, monitor, root) = try harness()
        defer { cleanup(store, root) }

        let debtTs = Date(timeIntervalSince1970: 1_700_000_000)
        let debt = makeDebt(timestamp: debtTs)
        monitor.replyDebtItems = [debt]
        monitor.rebuildInbox()
        XCTAssertEqual(monitor.inboxItems.map(\.chatUsername), [debt.chatUsername])

        let action = makeAction(relatedID: debt.chatUsername, sourceChatUsername: debt.chatUsername)
        monitor.markDailyReportActionDone(action)

        XCTAssertTrue(monitor.inboxItems.isEmpty, "live inbox must drop the chat, not only daily_report_state")
        XCTAssertEqual(monitor.handledItems.map(\.chatUsername), [debt.chatUsername])
        XCTAssertEqual(store.loadChatActions()[debt.chatUsername]?.silencedAt, 1_700_000_000)
        XCTAssertNotEqual(
            store.loadChatActions()[debt.chatUsername]?.silencedAt ?? 0,
            Int(Date().timeIntervalSince1970) + 315_360_000,
            "must not mute with a far-future watermark"
        )
        let states = store.loadDailyReportCommandStates(dateKey: Date().dailyReportDateKey)
        XCTAssertEqual(states.first { $0.itemID == action.id }?.state, .completed)
    }

    @MainActor
    func testMarkReplyDebtDoneSilencesFromDebtListWhenInboxRowIsMissing() async throws {
        let (store, monitor, root) = try harness()
        defer { cleanup(store, root) }

        let debtTs = Date(timeIntervalSince1970: 1_700_000_000)
        let debt = makeDebt(timestamp: debtTs)
        monitor.replyDebtItems = [debt]
        XCTAssertTrue(monitor.inboxItems.isEmpty)

        let action = makeAction(relatedID: debt.chatUsername, sourceChatUsername: "wxid_alias")
        monitor.markDailyReportActionDone(action)

        XCTAssertEqual(store.loadChatActions()[debt.chatUsername]?.silencedAt, 1_700_000_000)
        XCTAssertTrue(monitor.inboxItems.isEmpty)
        XCTAssertEqual(monitor.handledItems.map(\.chatUsername), [debt.chatUsername])
    }

    // MARK: - Fixtures

    private func makeAction(
        relatedID: String,
        sourceChatUsername: String
    ) -> DailyReportAction {
        DailyReportAction(
            content: "回复 同事: 请确认",
            type: .replyDebt,
            urgency: .high,
            deadline: nil,
            sourceChatName: "同事",
            sourceChatUsername: sourceChatUsername,
            relatedID: relatedID
        )
    }

    private func makeDebt(timestamp: Date) -> ReplyDebtItem {
        ReplyDebtItem(
            id: "wxid_debt",
            chatUsername: "wxid_debt",
            chatName: "同事",
            senderName: "同事",
            preview: "请确认",
            latestOutboundPreview: nil,
            timestamp: timestamp,
            priority: .p1,
            score: 6,
            unreadCount: 1,
            isGroup: false,
            isWhitelisted: true,
            isVIP: false,
            isAtMention: false,
            inboundCountSinceLastOutbound: 1,
            reasons: [],
            suggestedReplyMinutes: 30
        )
    }

    @MainActor
    private func harness() throws -> (HUDStore, ChatMonitor, String) {
        let root = NSTemporaryDirectory() + "daily-report-completion-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        var config = AIConfig()
        config.dailyReportActionInsightsEnabled = false
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        return (store, ChatMonitor(reader: reader, store: store, aiService: AIService(config: config)), root)
    }

    @MainActor
    private func cleanup(_ store: HUDStore, _ root: String) {
        store.close()
        try? FileManager.default.removeItem(atPath: root)
    }
}
