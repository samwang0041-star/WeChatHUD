import XCTest
@testable import WeChatHUD

final class DailyReportLoadingTests: XCTestCase {
    @MainActor
    private func harness() throws -> (HUDStore, ChatMonitor, String) {
        let root = NSTemporaryDirectory() + "daily-report-loading-\(UUID())"
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

    @MainActor
    func testFreshCacheForAnotherDateDoesNotShortCircuitRequestedDate() async throws {
        let (store, monitor, root) = try harness()
        defer { cleanup(store, root) }

        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        // Populate the visible report with today's data, then seed a fresh
        // cache timestamp for yesterday. The old implementation returned
        // here solely on the timestamp and kept today's body visible.
        await monitor.loadDailyReport(for: today)
        monitor.dailyReportViewedDate = yesterday
        monitor.dailyReportCache[yesterday.dailyReportDateKey] = Date()

        await monitor.loadDailyReport(for: yesterday)

        XCTAssertEqual(monitor.dailyReport?.date.dailyReportDateKey, yesterday.dailyReportDateKey)
    }

    @MainActor
    func testCacheDoesNotHideReplyDebtThatArrivedAfterTheReport() async throws {
        let (store, monitor, root) = try harness()
        defer { cleanup(store, root) }

        await monitor.loadDailyReport(force: true)
        let stampBefore = monitor.currentDailyReportFactsStamp()
        XCTAssertEqual(monitor.dailyReportCacheStamp[Date().dailyReportDateKey], stampBefore)

        monitor.replyDebtItems = [
            ReplyDebtItem(
                id: "wxid_new",
                chatUsername: "wxid_new",
                chatName: "同事",
                senderName: "同事",
                preview: "请确认",
                latestOutboundPreview: nil,
                timestamp: Date(),
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
        ]
        XCTAssertNotEqual(monitor.currentDailyReportFactsStamp(), stampBefore)

        await monitor.loadDailyReport(force: false)
        XCTAssertTrue(monitor.dailyReport?.actions.contains { $0.type == .replyDebt && $0.relatedID == "wxid_new" } == true)
    }

    @MainActor
    func testOlderAsyncRequestCannotReplaceNewerDateRequest() async throws {
        let (store, monitor, root) = try harness()
        defer { cleanup(store, root) }

        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        monitor.dailyReportViewedDate = yesterday
        let older = Task { @MainActor in await monitor.loadDailyReport(for: yesterday) }
        await Task.yield()
        monitor.dailyReportViewedDate = today
        let newer = Task { @MainActor in await monitor.loadDailyReport(for: today) }
        await newer.value
        await older.value

        XCTAssertEqual(monitor.dailyReport?.date.dailyReportDateKey, today.dailyReportDateKey)
        XCTAssertFalse(monitor.dailyReportIsLoading)
    }
}
