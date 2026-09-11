import XCTest
@testable import WeChatHUD

/// A backlog larger than one page must not be skipped in silence.
///
/// `whitelistFetchLimit` returned the fixed 100-row default whenever a chat had
/// a cursor, and the scan then advanced that cursor to the newest fetched
/// message. Any chat with more than 100 unread messages therefore lost the
/// middle of its backlog — never classified, never shown, never mentioned.
final class ScanBacklogPagingTests: XCTestCase {
    private let chat = "backlog_peer"

    private func scan(_ reader: WeChatReader, store: HUDStore) async throws -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: reader,
            store: store,
            aiService: AIService(config: AIConfig()),
            changedRelPaths: nil,
            thresholds: UnreadThresholds(),
            replyDebtConfig: ReplyDebtConfig(),
            currentRecent: [],
            recentLimit: 10,
            autopilotActive: false
        )
    }

    func testIncrementalScanCoversABacklogLargerThanThePageCap() async throws {
        // 501 unread rows: one more than the 500-row hard cap, so covering the
        // backlog requires the backward paging the scan now does.
        let rows = (1...501).map {
            SyntheticShardedScanFixture.MessageRow(
                localId: $0,
                createTime: 1_000 + $0,
                senderId: 1,
                text: "第 \($0) 条待整理消息"
            )
        }
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: rows.count
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        // A cursor from an earlier run: this is the incremental path, not the
        // first scan, and the old code's bug lived in that branch.
        try store.setWhitelistCursor(username: chat, lastCreateTime: 1_000, lastLocalId: 0)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned, "the scan itself failed")

        XCTAssertEqual(outcome.newInboundForClassifier.count, 501)
        XCTAssertEqual(store.classificationQueueCount(), 501)
        XCTAssertEqual(try store.discussionQueueCount(), 501)
        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 1_501)
    }

    func testSmallIncrementalBacklogIsUnaffected() async throws {
        let rows = (1...3).map {
            SyntheticShardedScanFixture.MessageRow(
                localId: $0, createTime: 1_000 + $0, senderId: 1, text: "第 \($0) 条"
            )
        }
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: rows.count
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        defer { store.close() }

        try store.addToWhitelist(
            username: chat, displayName: "同事", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        try store.setWhitelistCursor(username: chat, lastCreateTime: 1_000, lastLocalId: 0)

        let scanned = try await scan(fixture.reader, store: store)
        let outcome = try XCTUnwrap(scanned)
        XCTAssertEqual(outcome.newInboundForClassifier.count, 3)
        XCTAssertEqual(store.getWhitelistCursor(username: chat)?.lastCreateTime, 1_003)
    }
}
