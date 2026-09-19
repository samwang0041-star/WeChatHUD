import XCTest
@testable import WeChatHUD

final class ClassificationQueueWorkerTests: XCTestCase {
    @MainActor
    private func harness(configured: Bool = true) async throws -> (HUDStore, ChatMonitor, MockAIService, String) {
        let path = NSTemporaryDirectory() + "classification-worker-\(UUID()).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        var config = AIConfig()
        if configured {
            config.provider = AIProviderSlot(providerID: "custom", baseURL: "http://localhost:9999", model: "mock", apiKey: "test")
        }
        // Use the detected account path only for the account-change guard. No keys
        // are loaded, so no real WeChat databases can be decrypted/read by this test.
        // The fallback directory must exist: a missing dbDir reads as an account
        // switch, which makes the worker bail before ever consulting the model.
        let dbDir = WeChatReader.autoDetectDBDir()
            ?? NSTemporaryDirectory() + "classification-worker-\(UUID())/db_storage"
        try? FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        let reader = WeChatReader(keysPath: "/nonexistent/test-keys.json",
                                  dbDir: dbDir, cacheStrategy: .memory)
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: config))
        let ai = MockAIService()
        await ai.setConfig(config)
        await ai.setDefaultResponse(#"{"is_ask":true,"type":"send_file","summary":"发方案","confidence":0.95}"#)
        monitor.aiClassifier = AIClassifier(store: store, aiService: ai)
        return (store, monitor, ai, path)
    }

    private func cleanup(_ store: HUDStore, _ path: String) {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func message(
        _ id: Int, chat: String = "synthetic_peer",
        text: String = "请发方案", baseType: Int = 1
    ) -> MessageInfo {
        MessageInfo(id: "queued-\(id)", localId: id, chatUsername: chat, chatName: "合成同事",
                    senderUsername: chat, senderName: "合成同事", text: text,
                    baseType: baseType, subType: 0, createTime: 1000 + id)
    }

    /// A message that is nothing but a WeChat media placeholder has no text
    /// left after sanitizing, and the classifier's own prompt teaches it that
    /// such a message is not an ask. It used to be sent anyway with an empty
    /// `{message_body}`, which left the model deciding from the two names
    /// around the gap — and the prompt's "[图片]" few-shot example could no
    /// longer reach it, because the sanitizer deletes that literal.
    @MainActor
    func testMediaPlaceholderMessageIsAcknowledgedWithoutModelCall() async throws {
        let (store, monitor, ai, path) = try await harness()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "synthetic_peer", displayName: "合成同事", isGroup: false, category: .work)
        try store.enqueueClassificationMessages([message(1, text: "[图片]", baseType: 3)])
        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value

        XCTAssertEqual(store.classificationQueueCount(), 0, "the queue must still drain")
        let calls = await ai.calls.count
        XCTAssertEqual(calls, 0, "a message with no readable text must not reach the model")
        XCTAssertTrue(store.loadPendingAsks().isEmpty)
    }

    @MainActor
    func testSingleWorkerPersistsBeforeAckAndDiscardsUntrackedScope() async throws {
        let (store, monitor, ai, path) = try await harness()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "synthetic_peer", displayName: "合成同事", isGroup: false, category: .work)
        try store.enqueueClassificationMessages([message(1), message(2, chat: "untracked_peer")])
        monitor.drainClassificationQueue()
        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value
        XCTAssertEqual(store.classificationQueueCount(), 0)
        XCTAssertEqual(store.loadPendingAsks().map(\.msgUID), ["queued-1"])
        let calls = await ai.calls.count
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(monitor.classificationProcessing)
        XCTAssertEqual(monitor.classificationPendingCount, 0)
    }

    @MainActor
    func testModelFailureStaysQueuedThenExplicitRetryRecovers() async throws {
        let (store, monitor, ai, path) = try await harness()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "synthetic_peer", displayName: "合成同事", isGroup: false, category: .work)
        try store.enqueueClassificationMessages([message(1)])
        await ai.setShouldThrow(URLError(.timedOut))
        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertTrue(store.pendingClassificationMessages().isEmpty)
        XCTAssertTrue(store.loadPendingAsks().isEmpty)
        let recoveredAI = MockAIService()
        await recoveredAI.setDefaultResponse(#"{"is_ask":true,"type":"send_file","summary":"发方案","confidence":0.95}"#)
        monitor.aiClassifier = AIClassifier(store: store, aiService: recoveredAI)
        try store.retryClassificationMessages()
        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value
        XCTAssertEqual(store.classificationQueueCount(), 0)
        XCTAssertEqual(store.loadPendingAsks().count, 1)
    }

    @MainActor
    func testUnconfiguredAILeavesWorkIntact() async throws {
        let (store, monitor, ai, path) = try await harness(configured: false)
        defer { cleanup(store, path) }
        try store.enqueueClassificationMessages([message(1)])
        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value
        XCTAssertEqual(store.classificationQueueCount(), 1)
        XCTAssertEqual(monitor.classificationPendingCount, 1)
        let calls = await ai.calls.count
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testSuccessfulNonAskIsAcknowledgedWithoutPendingTask() async throws {
        let (store, monitor, ai, path) = try await harness()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "synthetic_peer", displayName: "合成同事", isGroup: false, category: .work)
        try store.enqueueClassificationMessages([message(1)])
        await ai.setDefaultResponse(#"{"is_ask":false,"type":"none","summary":"","confidence":0.95}"#)
        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value
        XCTAssertEqual(store.classificationQueueCount(), 0)
        XCTAssertTrue(store.loadPendingAsks().isEmpty)
    }
    @MainActor
    func testRemovingChatWhileModelRunsPreventsPersistingTheResult() async throws {
        let (store, monitor, ai, path) = try await harness()
        defer { cleanup(store, path) }
        let gate = RecipientGateAI(base: ai)
        monitor.aiClassifier = AIClassifier(store: store, aiService: gate)
        try store.addToWhitelist(username: "synthetic_peer", displayName: "合成同事", isGroup: false, category: .work)
        try store.enqueueClassificationMessages([message(1)])
        monitor.drainClassificationQueue()
        await gate.waitUntilStarted()
        try store.removeFromWhitelist(username: "synthetic_peer")
        await gate.release()
        await monitor.classificationWorker?.value
        XCTAssertTrue(store.loadPendingAsks().isEmpty)
        XCTAssertEqual(store.classificationQueueCount(), 0)
    }

    /// The scope re-check has three answers and the store used to have one Bool
    /// for two of them: `isWhitelisted` is `false` both for 「没关注」 and for
    /// 「读不到」, and the worker retired the queue row on `false`. One busy lock
    /// or I/O error therefore erased the only record that this message needed
    /// analysis — no 待办, no badge, no 未回, nothing in the log. The test above is
    /// the positive control: a genuinely unfollowed chat must still be dropped.
    @MainActor
    func testUnreadableWhitelistKeepsTheQueueRowForRetry() async throws {
        let (store, monitor, ai, path) = try await harness()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "synthetic_peer", displayName: "合成同事", isGroup: false, category: .work)
        try store.enqueueClassificationMessages([message(1)])
        try store.exec("DROP TABLE whitelist")

        monitor.drainClassificationQueue()
        await monitor.classificationWorker?.value

        XCTAssertEqual(store.classificationQueueCount(), 1,
                       "读不到白名单不等于这条不用管，队列行必须还在")
        XCTAssertTrue(store.loadPendingAsks().isEmpty)
        let calls = await ai.calls.count
        XCTAssertEqual(calls, 0, "范围判定读不到时不许接着问模型")
        // 「队列里还有 1 条」也正好是 worker 完全没跑的样子，所以这条才是承重的那半句：
        // 行必须已经被推到将来，证明确实执行过一次退避。
        XCTAssertTrue(store.pendingClassificationMessages().isEmpty,
                      "这条得是被 defer 推到将来的，不是原地没人碰过")

        // A retry, not a dead row: once its backoff is cleared it is scheduled
        // again, which is the whole point of deferring instead of deleting.
        try store.retryClassificationMessages()
        XCTAssertEqual(store.pendingClassificationMessages().count, 1,
                       "这条还得排得回去，否则和删掉只差一步")
    }

    /// All three arms of the verdict, driven directly. The queue test above can
    /// only show one of them at a time, and it is the wiring; this is the rule.
    func testScopeVerdictMapsAllThreeWhitelistAnswers() {
        XCTAssertEqual(
            ChatMonitor.scopeVerdict(whitelist: .unreadable, muted: false), .retry,
            "读不到时唯一不许做的事就是把这条当处理完了")
        XCTAssertEqual(ChatMonitor.scopeVerdict(whitelist: .unfollowed, muted: false), .retire)
        XCTAssertEqual(ChatMonitor.scopeVerdict(whitelist: .followed, muted: true), .retire)
        XCTAssertEqual(ChatMonitor.scopeVerdict(whitelist: .followed, muted: false), .proceed)
        // `.unreadable` outranks the mute check: a read failure must not be able
        // to turn 「这条被免打扰」 into a reason to delete the row.
        XCTAssertEqual(ChatMonitor.scopeVerdict(whitelist: .unreadable, muted: true), .retry)
    }

}


private actor RecipientGateAI: AIServiceProtocol {
    let base: MockAIService
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    init(base: MockAIService) { self.base = base }
    func currentConfig() async -> AIConfig { await base.currentConfig() }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { resume?.resume(); resume = nil }
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
