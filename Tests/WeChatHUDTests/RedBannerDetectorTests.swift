import Testing
import Foundation
@testable import WeChatHUD

@Suite("RedBannerDetector")
struct RedBannerDetectorTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    private func makeMineTodo(
        store: HUDStore,
        runID: Int,
        content: String,
        chat: String,
        deadlineDaysFromNow: Int,
        createdDaysAgo: Int
    ) -> Int {
        let todo = ReviewTodo(
            id: 0, originRunID: runID, lastRunID: runID, content: content,
            deadline: Date(timeIntervalSinceNow: TimeInterval(deadlineDaysFromNow * 86400)),
            direction: .mine, involved: ["counterpart"],
            sourceChatUsername: chat, sourceChatName: "Chat \(chat)",
            sourceMsgIDs: ["m1"], confidence: 0.8, status: .pending,
            createdAt: Date(timeIntervalSinceNow: TimeInterval(-createdDaysAgo * 86400)),
            completedAt: nil, snoozedTo: nil, delegatedTo: nil,
            carryCount: 0, lastUserActionAt: nil
        )
        return store.insertReviewTodo(todo)!
    }

    @Test("Past-deadline mine + pending + no follow-up → surfaced")
    func surfaceUnfollowed() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        _ = makeMineTodo(store: store, runID: runID, content: "send PRD",
                         chat: "wxid_a", deadlineDaysFromNow: -1, createdDaysAgo: 5)

        let mq = MockMessageQuery()
        let det = RedBannerDetector(store: store, messageQuery: mq)
        let banners = await det.detect()
        #expect(banners.count == 1)
        #expect(banners.first?.daysSinceCommit == 5)
    }

    @Test("Followed-up todo (Jaccard > 0.3) is NOT surfaced")
    func notSurfacedAfterFollowup() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        _ = makeMineTodo(store: store, runID: runID, content: "周一发PRD给王总",
                         chat: "wxid_a", deadlineDaysFromNow: -1, createdDaysAgo: 3)

        let mq = MockMessageQuery()
        await mq.setMessages([
            SimpleMessage(id: "fu1", text: "PRD 已经发给王总了", timestamp: Date(timeIntervalSinceNow: -86400))
        ], for: "wxid_a")

        let det = RedBannerDetector(store: store, messageQuery: mq)
        let banners = await det.detect()
        #expect(banners.isEmpty)
    }

    @Test("Dismissed within 24h → not surfaced")
    func dismissalSuppresses() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let todoID = makeMineTodo(store: store, runID: runID, content: "x",
                                   chat: "wxid_a", deadlineDaysFromNow: -1, createdDaysAgo: 2)
        store.recordDismissal(RedBannerDismissal(
            id: 0, todoID: todoID, action: .snoozed,
            reasonText: nil, snoozedTo: Date(timeIntervalSinceNow: 86400),
            createdAt: Date()
        ))

        let mq = MockMessageQuery()
        let det = RedBannerDetector(store: store, messageQuery: mq)
        let banners = await det.detect()
        #expect(banners.isEmpty)
    }

    @Test("Future-deadline (>24h) NOT surfaced")
    func futureDeadlineSkipped() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        _ = makeMineTodo(store: store, runID: runID, content: "future",
                         chat: "wxid_a", deadlineDaysFromNow: 5, createdDaysAgo: 1)

        let mq = MockMessageQuery()
        let det = RedBannerDetector(store: store, messageQuery: mq)
        let banners = await det.detect()
        #expect(banners.isEmpty)
    }

    @Test("Sort by daysSinceCommit DESC, cap at 3")
    func sortAndCap() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        for i in 1...5 {
            _ = makeMineTodo(
                store: store, runID: runID, content: "thing \(i)",
                chat: "wxid_\(i)", deadlineDaysFromNow: -1, createdDaysAgo: i
            )
        }
        let mq = MockMessageQuery()
        let det = RedBannerDetector(store: store, messageQuery: mq)
        let banners = await det.detect()
        #expect(banners.count == 3)
        // Most days first
        #expect(banners[0].daysSinceCommit >= banners[1].daysSinceCommit)
        #expect(banners[1].daysSinceCommit >= banners[2].daysSinceCommit)
    }
}
