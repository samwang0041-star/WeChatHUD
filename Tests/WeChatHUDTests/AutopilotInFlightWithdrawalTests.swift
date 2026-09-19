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

    /// The other direction of the same bug: stopping the keystrokes must not
    /// consume the draft. A pause mid-flight used to fall into the failed-send
    /// tail, which stamps `manualOnlyReason` — and only an unstamped row is
    /// ever eligible for automatic send again, so tabbing into WeChat during
    /// the typing window silently retired a queued reply forever.
    func testPauseMidFlightKeepsTheDraftQueuedButAWithdrawalConsumesIt() throws {
        XCTAssertTrue(AutopilotService.withheldByPause(
            paused: true, sessionOpen: true, rowStillQueued: true),
            "暂停（含「用户正在用微信」）⇒ 只是没发，行还要留在队列里")
        XCTAssertFalse(AutopilotService.withheldByPause(
            paused: true, sessionOpen: true, rowStillQueued: false),
            "行已被删 ⇒ 这是真撤回，不能复活")
        XCTAssertFalse(AutopilotService.withheldByPause(
            paused: true, sessionOpen: false, rowStillQueued: true),
            "会话已结束（停止）⇒ 按停止的处置走")
        XCTAssertFalse(AutopilotService.withheldByPause(
            paused: false, sessionOpen: true, rowStillQueued: true),
            "没暂停却失败 ⇒ 仍是发送失败，要转人工")
    }

    /// The disposition is one function, so the truth table covers the case the
    /// mutation used to slip through: a pause whose reason string is NOT one of
    /// the retryable "another send is running" strings still must not consume
    /// the draft.
    func testSendFailureDispositionKeepsAPausedDraftAndConsumesARealFailure() {
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: true, sessionOpen: true, rowStillQueued: true,
                reason: "这条回复在按下发送前已经停住，微信没有收到。", retryableReason: false),
            .requeueUnchanged(reason: "自动驾驶暂停，这条没有发出，仍留在队列里。"))
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                reason: "发送结果无法确认", retryableReason: false),
            .humanRequired(reason: "发送结果无法确认，已转为人工确认"))
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                reason: "已有发送正在进行", retryableReason: true),
            .requeueUnchanged(reason: "已有发送正在进行"))
    }

    func testFailureTailDecidesPauseBeforeStampingManualOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let body = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "private func executeSend").last!
            // The cap and staleness branches stamp manual-only BEFORE the send
            // and must keep doing so; the ordering that matters is inside the
            // post-send failure tail.
            .components(separatedBy: "let failureReason = lastSendFailureMessage").last!
        let decide = body.range(of: "let disposition = Self.sendFailureDisposition(")!.lowerBound
        let stamp = body.range(of: "retained.manualOnlyReason =")!.lowerBound
        XCTAssertLessThan(decide, stamp,
                          "必须先算出处置，再决定要不要把这条转人工")
        XCTAssertTrue(body.contains("if case .humanRequired = disposition {"),
                      "转人工的记账必须挂在那一个判定上，而不是挂在某个布尔的取反上")
        XCTAssertTrue(body.contains("rowStillQueued: store.hasPendingSend(id: item.id)"),
                      "处置判定漏掉「行还在不在」⇒ 暂停和撤回又会被混成一谈")
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
