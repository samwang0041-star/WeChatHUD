import XCTest
import SQLite3
@testable import WeChatHUD

/// Guards for the scan-time perf gates on ChatMonitor:
/// - off-main summary fetches (item: main-thread SQLite reads),
/// - the expand-panel prefetch gate + cap (item: 2×N AI calls per scan),
/// - the throttled stale-row archive sweep (item: write transaction per scan).
final class ChatMonitorPerfGatesTests: XCTestCase {

    @MainActor
    private func makeFixture() throws -> (HUDStore, ChatMonitor, String) {
        let root = NSTemporaryDirectory() + "perf-gates-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        return (store, monitor, root)
    }

    private func cleanup(_ store: HUDStore, _ root: String) {
        store.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Hand-built action row: unlike InboxBuilder (one row per chat) this lets
    /// a test put two rows for the same chat at two timestamps.
    private func actionItem(
        chat: String,
        timestamp: Date,
        notification: HUDNotification? = nil,
        isGroup: Bool = false,
        isAtMention: Bool = false
    ) -> InboxItem {
        InboxItem(
            id: chat,
            chatUsername: chat,
            chatName: "合成会话",
            senderName: "同事",
            preview: "请确认合成测试事项",
            isGroup: isGroup,
            timestamp: timestamp,
            actionRequired: true,
            priority: .p1,
            isVIP: false,
            isWhitelisted: true,
            unreadCount: 1,
            isAtMention: isAtMention,
            askType: .none,
            reasons: [],
            suggestedReplyMinutes: 30,
            status: .active,
            dismissedAtMsgId: nil,
            aiSummary: nil,
            moodEmoji: nil,
            isOverdue: false,
            overdueMinutes: 0,
            replied: false,
            snoozedUntil: nil,
            contextNotification: notification,
            silenced: false
        )
    }

    private func groupAtNotification(chat: String, messageID: String, at timestamp: Date) -> HUDNotification {
        HUDNotification(
            chatUsername: chat,
            chatName: "项目群",
            senderUsername: "wxid_peer",
            senderName: "同事",
            attentionLevel: .vip,
            messageID: messageID,
            rawText: "@我 请确认一下",
            snippet: "@我 请确认一下",
            isAtMention: true,
            timestamp: timestamp,
            kind: .groupAt
        )
    }

    private func insertStaleDiscussionRow(_ store: HUDStore, uid: String) throws {
        let staleTs = Int(Date().timeIntervalSince1970) - (DiscussionLiveWindow.pendingDays + 2) * 86_400
        _ = try store.insertDiscussionItem(
            chatUsername: "synthetic-peer",
            chatName: "合成同事",
            kind: .todo,
            owner: .mine,
            content: "合成过期待办",
            detail: nil,
            anchorMsgUID: uid,
            sourceTimestamp: staleTs,
            dueAt: nil,
            confidence: 0.9,
            promptVersion: "perf-test"
        )
        // insertDiscussionItem stamps created_at with "now"; the archive sweep
        // requires a stale created_at too, so backdate the row.
        let sql = "UPDATE discussion_items SET created_at='\(staleTs)' WHERE anchor_msg_uid='\(uid)'"
        XCTAssertEqual(sqlite3_exec(store.rawDB, sql, nil, nil, nil), SQLITE_OK)
    }

    // MARK: - Off-main summary fetch

    func testSummaryFetchRunsOffTheMainThread() async {
        let ranOnMainThread = await ChatMonitor.runOffMain { Thread.isMainThread }
        XCTAssertFalse(ranOnMainThread, "summary reads of the encrypted shards must not block the main actor")
    }

    @MainActor
    func testGroupAtSummaryStillValidatesSourceBeforeServingCache() async throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        let now = Date()
        let item = actionItem(
            chat: "room@chatroom",
            timestamp: now,
            notification: groupAtNotification(chat: "room@chatroom", messageID: "missing-message", at: now),
            isGroup: true,
            isAtMention: true
        )
        // Pre-seed the row-summary cache with the same generation key. The
        // source message cannot be read back (synthetic reader, no database),
        // so the cached summary must not be attached to this row.
        try store.writeAnalysisCache(
            chatUsername: item.chatUsername,
            analysisType: "inbox_row_summary_v3",
            inputHash: item.generationKey,
            result: "陈旧摘要",
            ttlHours: 72
        )
        monitor.inboxItems = [item]
        monitor.generateSummaries()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(monitor.inboxItems.first?.aiSummary,
                     "a group @ summary whose source row vanished must not fall back to a cached summary")
    }

    @MainActor
    func testPrivateRowStillServesCachedSummaryWithoutCallingAI() async throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        let item = actionItem(chat: "synthetic-peer", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try store.writeAnalysisCache(
            chatUsername: item.chatUsername,
            analysisType: "inbox_row_summary_v3",
            inputHash: item.generationKey,
            result: "缓存摘要",
            ttlHours: 72
        )
        monitor.inboxItems = [item]
        monitor.generateSummaries()

        var summary: String?
        for _ in 0..<40 {
            if let value = monitor.inboxItems.first?.aiSummary { summary = value; break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(summary, "缓存摘要", "the summary cache must still short-circuit the AI call")
    }

    // MARK: - Expand-panel prefetch gate

    @MainActor
    func testActionPrefetchIsSkippedWhilePanelIsCollapsed() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        monitor.inboxItems = [actionItem(chat: "synthetic-a", timestamp: Date())]
        monitor.panelExpansionProvider = { false }
        monitor.prefetchActionPanelData()

        XCTAssertTrue(monitor.actionPrefetch.isEmpty,
                      "nothing can render prefetched panel data while the panel is collapsed")
    }

    @MainActor
    func testActionPrefetchTargetsCapAtVisibleLimitAndKeepNewestPerChat() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            actionItem(chat: "chat-a", timestamp: base),
            actionItem(chat: "chat-a", timestamp: base.addingTimeInterval(120)),
            actionItem(chat: "chat-b", timestamp: base),
            actionItem(chat: "chat-c", timestamp: base),
            actionItem(chat: "chat-d", timestamp: base),
            actionItem(chat: "chat-e", timestamp: base)
        ]

        let targets = ChatMonitor.actionPrefetchTargets(items)
        XCTAssertEqual(targets.count, ChatMonitor.actionPrefetchVisibleLimit)
        XCTAssertEqual(targets.map(\.chatUsername), ["chat-a", "chat-b", "chat-c"])
        XCTAssertEqual(targets.first?.timestamp, base.addingTimeInterval(120),
                       "the newest row per chat is the one worth warming")
    }

    // MARK: - Stale-row archive sweep

    @MainActor
    func testStaleArchiveSweepRunsOncePerInterval() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        let now = Date()
        XCTAssertTrue(monitor.shouldSweepStaleRows(now: now), "the first sweep after launch must always run")
        monitor.reloadAIData()
        XCTAssertFalse(monitor.shouldSweepStaleRows(now: now.addingTimeInterval(60)))
        // The sweep stamp is written from the monitor's own clock, so compare
        // against an instant safely past the interval rather than the exact
        // boundary.
        XCTAssertTrue(monitor.shouldSweepStaleRows(now: now.addingTimeInterval(ChatMonitor.staleArchiveSweepInterval + 1)))
    }

    @MainActor
    func testSecondReloadWithinThrottleWindowDoesNotArchive() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        try insertStaleDiscussionRow(store, uid: "stale-1")
        monitor.reloadAIData()
        XCTAssertTrue(store.loadDiscussionItems(status: .pending).isEmpty,
                      "the launch sweep folds rows that are already stale")

        try insertStaleDiscussionRow(store, uid: "stale-2")
        monitor.reloadAIData()
        XCTAssertEqual(store.loadDiscussionItems(status: .pending).map(\.anchorMsgUID), ["stale-2"],
                       "a throttled reload must not open the archive write path")
    }

    @MainActor
    func testThrottledReloadIssuesNoWriteStatements() throws {
        let (store, monitor, root) = try makeFixture()
        defer { cleanup(store, root) }

        monitor.reloadAIData()   // launch sweep: one-time cost
        let baseline = store.writeStatementCount
        monitor.reloadAIData()
        XCTAssertEqual(store.writeStatementCount, baseline,
                       "nothing stale ⇒ no archive write, and no other write on the reload path")
    }
}
