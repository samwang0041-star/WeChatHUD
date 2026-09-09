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
        let reader = WeChatReader(keysPath: "/nonexistent/test-keys.json",
                                  dbDir: WeChatReader.autoDetectDBDir() ?? "/tmp/test_me/db_storage", cacheStrategy: .memory)
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

    private func message(_ id: Int, chat: String = "synthetic_peer") -> MessageInfo {
        MessageInfo(id: "queued-\(id)", localId: id, chatUsername: chat, chatName: "合成同事",
                    senderUsername: chat, senderName: "合成同事", text: "请发方案",
                    baseType: 1, subType: 0, createTime: 1000 + id)
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
