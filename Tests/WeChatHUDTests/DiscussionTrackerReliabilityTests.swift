import XCTest
import SQLite3
@testable import WeChatHUD

final class DiscussionTrackerReliabilityTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "discussion-reliability-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false, category: .work)
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    private func model(response: String) async -> MockAIService {
        let model = MockAIService()
        var config = AIConfig()
        config.provider = AIProviderSlot(providerID: "custom", baseURL: "http://localhost:9999", model: "mock", apiKey: "test")
        await model.setConfig(config)
        await model.setDefaultResponse(response)
        return model
    }

    private func message(_ id: Int, time: Int = 1000, text: String? = nil) -> MessageInfo {
        MessageInfo(id: "m\(id)", localId: id, chatUsername: "peer", chatName: "同事",
                    senderUsername: "me", senderName: "我", text: text ?? "消息\(id)",
                    baseType: 1, subType: 0, createTime: time)
    }

    private func extract(_ tracker: DiscussionTracker, _ messages: [MessageInfo]) async -> Int {
        await tracker.extract(chatUsername: "peer", chatName: "同事", messages: messages,
                              myUsername: "me", myDisplayName: "我", mySelfNames: [])
    }

    func testEmptySuccessCheckpointsAndSameSecondNewMessageIsProcessed() async {
        let ai = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, [message(2), message(1)])
        _ = await extract(tracker, [message(2), message(1)])
        let callsBefore = await ai.calls.count
        XCTAssertEqual(callsBefore, 1)
        _ = await extract(tracker, [message(3), message(2), message(1)])
        let callsAfter = await ai.calls.count
        XCTAssertEqual(callsAfter, 2)
        let cursor = store.getSettingJSON(DiscussionTracker.cursorKey("peer"), as: DiscussionTracker.SourceCursor.self)
        XCTAssertEqual(cursor?.localID, 3)
        // Restarting the actor still uses the persisted processing checkpoint.
        _ = await extract(DiscussionTracker(store: store, aiService: ai), [message(3), message(2)])
        let restartedCalls = await ai.calls.count
        XCTAssertEqual(restartedCalls, 2)
    }

    func testNewestAnchorChronologicalTranscriptAndSourceRelativeDeadline() async {
        let ai = await model(response: #"{"items":[{"kind":"todo","owner":"mine","content":"整理项目资料","due":"+1d","confidence":0.9}]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        let count = await extract(tracker, [message(3, time: 3000), message(2, time: 2000), message(1)])
        XCTAssertEqual(count, 1)
        let item = store.loadDiscussionItems(chatUsername: "peer").first
        XCTAssertEqual(item?.anchorMsgUID, "m3")
        XCTAssertEqual(item?.sourceTimestamp, 3000)
        XCTAssertEqual(item?.dueAt?.timeIntervalSince1970, 3000 + 86400)
        let prompt = await ai.calls.first?.user ?? ""
        XCTAssertLessThan(prompt.range(of: "消息1")!.lowerBound, prompt.range(of: "消息3")!.lowerBound)
    }

    /// "我要求别人去做" must land in 等对方, not 我要做 — the v3 prompt asks
    /// for `executor`, and the parser maps it deterministically.
    func testDelegatedTaskExtractedAsTheirs() async {
        let ai = await model(response: #"{"items":[{"kind":"todo","executor":"peer","msg":1,"content":"客户回访名单","due":"+1d","confidence":0.9}]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        let count = await extract(tracker, [
            message(1, time: 1000, text: "小李，客户回访名单明天前给我"),
            message(2, time: 2000, text: "收到")
        ])
        XCTAssertEqual(count, 1)
        let item = store.loadDiscussionItems(chatUsername: "peer").first
        XCTAssertEqual(item?.owner, .theirs)
        XCTAssertEqual(item?.anchorMsgUID, "m1")
        XCTAssertEqual(item?.sourceTimestamp, 1000)
        // due resolves relative to the item's own source message, not the batch tail.
        XCTAssertEqual(item?.dueAt?.timeIntervalSince1970, 1000 + 86400)
    }

    func testExecutorOverridesLegacyOwnerField() async {
        let ai = await model(response: #"{"items":[{"kind":"todo","owner":"mine","executor":"peer","msg":1,"content":"出报价单","confidence":0.8}]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, [message(1)])
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "peer").first?.owner, .theirs)
    }

    func testInvalidMsgIndexFallsBackToNewest() async {
        let ai = await model(response: #"{"items":[{"kind":"info","executor":"unknown","msg":99,"content":"预算30万","confidence":0.9}]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, [message(1, time: 1000), message(2, time: 2000)])
        let item = store.loadDiscussionItems(chatUsername: "peer").first
        XCTAssertEqual(item?.owner, .shared)
        XCTAssertEqual(item?.anchorMsgUID, "m2")
    }

    func testMissingExecutorFallsBackToOwnerField() async {
        let ai = await model(response: #"{"items":[{"kind":"todo","owner":"mine","content":"我明天发你","confidence":0.9}]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, [message(1)])
        XCTAssertEqual(store.loadDiscussionItems(chatUsername: "peer").first?.owner, .mine)
    }

    func testFailureDoesNotAdvanceCheckpointAndCanRetry() async {
        let ai = await model(response: "invalid JSON")
        let tracker = DiscussionTracker(store: store, aiService: ai, retryBaseDelay: 0)
        _ = await extract(tracker, [message(1)])
        XCTAssertNil(store.getSetting(DiscussionTracker.cursorKey("peer")))
        await ai.setDefaultResponse(#"{"items":[]}"#)
        _ = await extract(tracker, [message(1)])
        XCTAssertNotNil(store.getSetting(DiscussionTracker.cursorKey("peer")))
    }

    func testWindowDrainsOldestFortyThenRemainder() async throws {
        let ai = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, (1...45).reversed().map { message($0, text: "唯一消息[\($0)]") })
        let prompt = await ai.calls.first?.user ?? ""
        XCTAssertTrue(prompt.contains("唯一消息[1]"))
        XCTAssertTrue(prompt.contains("唯一消息[40]"))
        XCTAssertFalse(prompt.contains("唯一消息[41]"))
        let calls = await ai.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].user.contains("唯一消息[45]"))
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
    }
    func testOverlappingScanDrainsNewerMessagesWithoutLosingCheckpoint() async {
        let base = await model(response: #"{"items":[]}"#)
        let ai = DelayedDiscussionAI(base: base)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        let first = Task { await self.extract(tracker, [self.message(1)]) }
        await ai.waitUntilStarted()
        _ = await extract(tracker, [message(2), message(1)])
        await ai.release()
        _ = await first.value
        let calls = await base.calls.count
        XCTAssertEqual(calls, 2)
        let cursor = store.getSettingJSON(DiscussionTracker.cursorKey("peer"), as: DiscussionTracker.SourceCursor.self)
        XCTAssertEqual(cursor?.localID, 2)
    }


    func testHundredMessageBurstProcessesEverySourceInOldestBatches() async throws {
        let ai = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, (1...100).reversed().map { message($0, text: "source[\($0)]") })
        let calls = await ai.calls
        XCTAssertEqual(calls.count, 3)
        for id in 1...100 {
            XCTAssertEqual(calls.filter { $0.user.contains("source[\(id)]") }.count, 1, "each source must be sent exactly once")
        }
        XCTAssertTrue(calls[0].user.contains("source[1]"))
        XCTAssertTrue(calls[1].user.contains("source[41]"))
        XCTAssertTrue(calls[2].user.contains("source[81]"))
        XCTAssertEqual(store.getSettingJSON(DiscussionTracker.cursorKey("peer"), as: DiscussionTracker.SourceCursor.self)?.localID, 100)
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
    }

    func testFailureBackoffBlocksNewerRowsAndRetryWithoutNewMessagesIncludesFailure() async throws {
        let ai = await model(response: "invalid JSON")
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, [message(1, text: "old-failed-source")])
        let failedCalls = await ai.calls.count
        XCTAssertEqual(failedCalls, 2)
        let failed = try XCTUnwrap(store.pendingDiscussionMessages(chatUsername: "peer").first)
        XCTAssertGreaterThan(failed.retryAfter, Date().timeIntervalSince1970)
        await ai.setDefaultResponse(#"{"items":[]}"#)
        _ = await extract(tracker, [message(2, text: "new-source")])
        _ = await tracker.resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        let duringBackoff = await ai.calls.count
        XCTAssertEqual(duringBackoff, failedCalls)
        XCTAssertNil(store.getSetting(DiscussionTracker.cursorKey("peer")))
        try store.deferDiscussionMessages(["m1"], until: 0)
        await tracker.resetRetryBackoff()
        _ = await tracker.resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        let retriedPrompt = await ai.calls.last?.user ?? ""
        XCTAssertTrue(retriedPrompt.contains("old-failed-source"))
        XCTAssertTrue(retriedPrompt.contains("new-source"))
        XCTAssertEqual(store.getSettingJSON(DiscussionTracker.cursorKey("peer"), as: DiscussionTracker.SourceCursor.self)?.localID, 2)
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
    }

    func testDurableQueueRecoversAfterStoreAndActorRestart() async throws {
        let failing = await model(response: "invalid JSON")
        _ = await extract(DiscussionTracker(store: store, aiService: failing), [message(1, text: "durable-source")])
        store.close()
        store = HUDStore(dbPath: dbPath)
        try store.open()
        XCTAssertEqual(try store.pendingDiscussionMessages(chatUsername: "peer").count, 1)
        try store.deferDiscussionMessages(["m1"], until: 0)
        let recovered = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: recovered)
        _ = await tracker.resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        let prompt = await recovered.calls.first?.user ?? ""
        XCTAssertTrue(prompt.contains("durable-source"))
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
    }

    func testWorkBeyondThreeBatchesRemainsQueuedForNextTick() async throws {
        let ai = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await extract(tracker, (1...160).map { message($0) })
        let firstRunCalls = await ai.calls.count
        XCTAssertEqual(firstRunCalls, 3)
        XCTAssertEqual(try store.pendingDiscussionMessages(chatUsername: "peer", limit: 200).count, 40)
        _ = await tracker.resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        let finalCalls = await ai.calls.count
        XCTAssertEqual(finalCalls, 4)
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
    }

    func testQueueEnqueueIsAtomicWhenANewerInsertFails() throws {
        // EnsureDiscussionQueue owns table creation; the test trigger can only
        // be installed after the first queue touch.
        _ = try store.discussionQueueCount()
        let sql = "CREATE TRIGGER block_discussion_newer BEFORE INSERT ON discussion_queue WHEN NEW.msg_uid = 'm2' BEGIN SELECT RAISE(ABORT, 'newer insert blocked'); END"
        XCTAssertEqual(sqlite3_exec(store.rawDB, sql, nil, nil, nil), SQLITE_OK)
        do {
            try store.enqueueDiscussionMessages([message(2), message(1)])
            XCTAssertEqual(try store.pendingDiscussionMessages(chatUsername: "peer").map(\.message.id), [])
            XCTFail("The blocked insert must surface instead of silently accepting a partial batch")
        } catch {
            XCTAssertEqual(try store.discussionQueueCount(), 0)
        }
        XCTAssertEqual(sqlite3_exec(store.rawDB, "DROP TRIGGER block_discussion_newer", nil, nil, nil), SQLITE_OK)
        try store.enqueueDiscussionMessages([message(2), message(1)])
        XCTAssertEqual(try store.pendingDiscussionMessages(chatUsername: "peer").map(\.message.id), ["m1", "m2"])
    }

    func testRevokedScopePurgesPendingSourcesWithoutSending() async throws {
        try store.enqueueDiscussionMessages([message(1)])
        try store.removeFromWhitelist(username: "peer")
        let ai = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        _ = await tracker.resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        let calls = await ai.calls.count
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
        XCTAssertNil(store.getSetting(DiscussionTracker.cursorKey("peer")))
    }


    func testScopeRemovedDuringNetworkDoesNotInsertOrAdvanceCursor() async throws {
        let base = await model(response: #"{"items":[{"kind":"todo","owner":"mine","content":"不应写入","confidence":0.9}]}"#)
        let ai = DelayedDiscussionAI(base: base)
        let tracker = DiscussionTracker(store: store, aiService: ai)
        let running = Task { await self.extract(tracker, [self.message(1)]) }
        await ai.waitUntilStarted()
        try store.removeFromWhitelist(username: "peer")
        await ai.release()
        _ = await running.value
        XCTAssertTrue(store.loadDiscussionItems(chatUsername: "peer").isEmpty)
        XCTAssertNil(store.getSetting(DiscussionTracker.cursorKey("peer")))
        XCTAssertTrue(try store.pendingDiscussionMessages(chatUsername: "peer").isEmpty)
    }

    func testFailedCheckpointLeavesSourceQueuedForRetry() async throws {
        let ai = await model(response: #"{"items":[]}"#)
        let tracker = DiscussionTracker(store: store, aiService: ai, retryBaseDelay: 0)
        let sql = "CREATE TRIGGER block_discussion_checkpoint BEFORE INSERT ON settings WHEN NEW.key LIKE 'discussion_processed_cursor_v1:%' BEGIN SELECT RAISE(ABORT, 'checkpoint blocked'); END"
        XCTAssertEqual(sqlite3_exec(store.rawDB, sql, nil, nil, nil), SQLITE_OK)
        _ = await extract(tracker, [message(1)])
        XCTAssertNil(store.getSetting(DiscussionTracker.cursorKey("peer")))
        XCTAssertEqual(try store.discussionQueueCount(), 1)
        XCTAssertEqual(sqlite3_exec(store.rawDB, "DROP TRIGGER block_discussion_checkpoint", nil, nil, nil), SQLITE_OK)
        _ = await tracker.resumePending(myUsername: "me", myDisplayName: "我", mySelfNames: [])
        XCTAssertEqual(try store.discussionQueueCount(), 0)
        XCTAssertEqual(store.getSettingJSON(DiscussionTracker.cursorKey("peer"), as: DiscussionTracker.SourceCursor.self)?.localID, 1)
    }

}


private actor DelayedDiscussionAI: AIServiceProtocol {
    let base: MockAIService
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    init(base: MockAIService) { self.base = base }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { resume?.resume(); resume = nil }
    func currentConfig() async -> AIConfig { await base.currentConfig() }
    func complete(system: String, user: String, options: CompleteOptions) async throws -> String {
        try await completeWithMetadata(system: system, user: user, options: options).text
    }
    func completeWithMetadata(system: String, user: String, options: CompleteOptions) async throws -> AICompletionResult {
        if !started {
            started = true
            await withCheckedContinuation { continuation in
                resume = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        return try await base.completeWithMetadata(system: system, user: user, options: options)
    }
}
