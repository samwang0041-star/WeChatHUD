import XCTest
@testable import WeChatHUD

/// The guardrail that only exists in the time dimension.
///
/// Every pre-send guard in `AutopilotService` runs BEFORE the send is
/// suspended inside `serialSend`. A 停止 / 暂停 / 取消本条 that lands during the
/// 1.5–8s typing-and-paste window used to have no effect at all: the launcher
/// never asked whether the reply was still wanted, so WeChat received text the
/// UI had already declared canceled — and `cancelPendingSend` dropped the
/// cancel on the floor, because a row mid-send is no longer in
/// `pendingSendQueue`.
final class AutopilotInFlightWithdrawalTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUp() async throws {
        tmpPath = NSTemporaryDirectory() + "hud_inflight_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await service.start()
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    private func item(_ text: String = "收到，我看一下") -> PendingSend {
        PendingSend(
            chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: text, confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1)
        )
    }

    // MARK: - The decision itself

    func testMayStillDeliverClosesOnEveryWithdrawalThatCanLandMidSend() {
        // Control first: a plain send with nothing withdrawn must never be
        // blocked, or the guard would silently stop autopilot delivering.
        XCTAssertTrue(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: true, approvalRowPending: nil))
        // The manual paste-draft path carries no row identity at all.
        XCTAssertTrue(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: nil, approvalRowPending: nil))

        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: true, sessionOpen: true, queueRowLive: true, approvalRowPending: nil),
            "暂停 landing mid-flight must stop the keystrokes")
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: false, queueRowLive: true, approvalRowPending: nil),
            "停止 ends the session mid-flight")
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: false, approvalRowPending: nil),
            "取消本条 deletes the queue row mid-flight")
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: true, approvalRowPending: false),
            "取消本条 on an approval row flips it out of 'pending' mid-send")
    }

    // MARK: - Gate driven by real actor + store state

    func testGateTracksPauseStopAndTheRowItself() async throws {
        let queued = item()
        await service.testingEnqueue(queued)
        var config = AutopilotConfig()
        config.maxSendsPerSession = 0
        // A send attempt leaves the row's `pending_sends` twin behind even
        // though no WeChat is running to receive it.
        _ = await service.testingExecuteSend(item: queued, config: config)

        let live = await service.deliveryStillPermitted(queueId: queued.id, logId: nil)
        XCTAssertTrue(live, "an untouched in-flight row must stay sendable")

        await service.manualPause()
        let paused = await service.deliveryStillPermitted(queueId: queued.id, logId: nil)
        XCTAssertFalse(paused)
        await service.manualResume()

        try store.deletePendingSend(id: queued.id)
        let withdrawn = await service.deliveryStillPermitted(queueId: queued.id, logId: nil)
        XCTAssertFalse(withdrawn, "the row is the user's withdrawal — it is gone, so stop")
    }

    /// The approval branch, against a real log row: `approvePending` leaves the
    /// row in 'pending' for the whole send (it flips it only on success), so a
    /// 取消本条 landing mid-flight is visible to the gate exactly through this.
    func testApprovalGateFollowsTheRealLogRow() async throws {
        let reply = "我下午给你结论"
        let logSession = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: logSession, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "shard/Msg_a/7", triggerText: "结论有了吗",
            generatedReply: reply, confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        let logId = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: logSession).first?.id,
            "fixture 没落库 ⇒ 这条测试什么都没验")
        XCTAssertEqual(store.autopilotLogPendingReply(id: logId), reply,
                       "行必须处于 pending，否则闸门没有理由打开")

        let open = await service.deliveryStillPermitted(queueId: nil, logId: logId)
        XCTAssertTrue(open, "人还没撤回 ⇒ 允许发送")

        await service.rejectPending(logId: logId, chatUsername: "wxid_peer", replyText: reply)
        let closed = await service.deliveryStillPermitted(queueId: nil, logId: logId)
        XCTAssertFalse(closed, "取消本条把行翻出 pending ⇒ 闸门必须关掉")
    }

    /// The cancel path itself: the old `guard pendingSendQueue.first …  else
    /// return` early-out meant a cancel aimed at an in-flight row did nothing
    /// except print a success receipt.
    func testCancelRetiresTheRowEvenWhenMemoryNoLongerHoldsIt() async throws {
        let flying = item("这个我来跟进")
        var config = AutopilotConfig()
        config.maxSendsPerSession = 0
        // `executeSend` keeps the row in the database but never re-queues it
        // without an open log twin — the exact shape of a row mid-send.
        _ = await service.testingExecuteSend(item: flying, config: config)
        let stillQueued = await service.pendingSendQueue.contains { $0.id == flying.id }
        XCTAssertTrue(store.hasPendingSend(id: flying.id), "the send must have a row to be judged by")
        XCTAssertFalse(stillQueued, "fixture did not reach the mid-flight shape this test is about")

        await service.cancelPendingSend(id: flying.id)

        XCTAssertFalse(store.hasPendingSend(id: flying.id))
        let after = await service.deliveryStillPermitted(queueId: flying.id, logId: nil)
        XCTAssertFalse(after, "a canceled row must not press keys")
    }

    // MARK: - Wiring, for the part no unit test can execute

    /// The last-mile code needs a live WeChat + accessibility, so this is the
    /// honest maximum: the checkpoints exist on both sides of the paste, and
    /// both are strictly before the send key. It is NOT a proof that the
    /// keystroke is withheld — only a production run with 微信 open can show
    /// that, and the copy above is what the user reads when it works.
    func testLauncherReReadsPermissionAtBothSidesOfThePaste() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/WeChatLauncher.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = source.components(separatedBy: "private static func performTextAction").last!
        let checkpoints = body.components(separatedBy: "await sendStillAllowed(abortCheck)").count - 1
        XCTAssertEqual(checkpoints, 2, "one before the paste, one before the send key")

        let firstCheckpoint = body.range(of: "await sendStillAllowed(abortCheck)")!.lowerBound
        let sendKey = body.range(of: "switch sendKey {")!.lowerBound
        let paste = body.range(of: "postCmdKey(kVK_ANSI_V)")!.lowerBound
        XCTAssertGreaterThan(paste, firstCheckpoint, "the paste itself must be gated")
        XCTAssertGreaterThan(sendKey, firstCheckpoint)
        XCTAssertTrue(body.contains("return .failed(.withdrawnBeforeSend)"))
    }
}
