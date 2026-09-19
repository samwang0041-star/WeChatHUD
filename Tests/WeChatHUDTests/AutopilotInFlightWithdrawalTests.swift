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
        // The 'sent' write-back failed, so the audit row still says 'pending'
        // and no row read can rule out a second send. This is the only signal.
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: nil, approvalRowPending: nil,
            alreadySentHere: true),
            "写回失败的已发送草稿不能再发一次")
        // 取消侧同形：写回失败时数据库里那条还是 'pending'，任何行读法都排不掉
        // 「用户已经把它取消了」这件事。
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: nil, approvalRowPending: nil,
            rejectedHere: true),
            "写回失败的已取消草稿不许再发出去")
    }

    /// The set is only worth having if `rejectPending` fills it at the moment the
    /// write fails — that instant is the one where the database still says
    /// 'pending' while the user has already said 不发了. The control in front
    /// proves the hold is per-row rather than a blanket refusal.
    @MainActor
    func testCancelWithFailedWriteIsHeldByTheGate() async throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "shard/Msg_g/1", triggerText: "结论有了吗",
            generatedReply: "我下午给你结论", confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        let openId = try XCTUnwrap(store.loadAutopilotLog(sessionId: sessionId).first?.id)
        let openStillAllowed = await service.deliveryStillPermitted(queueId: nil, logId: openId)
        XCTAssertTrue(openStillAllowed, "没被取消过的待确认行不该被这条闸门拦住")

        // 让 UPDATE 失败而 SELECT 照常：整张表没了的话，闸门会因为「读不到 pending
        // 行」而拒绝，那个假绿测不到本地集合是否在承重（第一条变异就是这么活的）。
        try store.exec("""
            CREATE TRIGGER break_skip_write BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END
            """)
        XCTAssertEqual(store.autopilotLogPendingReply(id: openId), "我下午给你结论",
                       "行必须仍是 pending，否则这条测试又在验另一个信号")
        await service.rejectPending(logId: openId, chatUsername: "wxid_peer", replyText: "我下午给你结论")
        let cancelledHeld = await service.deliveryStillPermitted(queueId: nil, logId: openId)
        XCTAssertFalse(cancelledHeld, "写回失败的取消也必须拦住发送")
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
        // The real reason strings are complete sentences ending in 。; the
        // concatenation this replaces printed
        // 「…，微信没有收到。，已转为人工确认」 on the approval card.
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                reason: "这条回复在按下发送前已经停住，微信没有收到。", retryableReason: false),
            .humanRequired(reason: "这条回复在按下发送前已经停住，微信没有收到，已转为人工确认"))
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

    /// A twin read that failed answered `false`, which the guard behind it read
    /// as "the user already took this back": the draft left `pendingSendQueue`
    /// — which is what the 待确认 list renders from — while its DB row stayed
    /// pending until the next launch. Unknown is now its own answer.
    func testRetainedDraftActionSeparatesUnknownFromCancelled() {
        XCTAssertEqual(
            AutopilotService.retainedDraftAction(sessionOpen: false, twin: .open), .drop,
            "a stopped session must not leave an in-memory zombie"
        )
        XCTAssertEqual(
            AutopilotService.retainedDraftAction(sessionOpen: true, twin: .resolved), .drop)
        XCTAssertEqual(
            AutopilotService.retainedDraftAction(sessionOpen: true, twin: .open),
            .keep(forceManualOnly: false))
        XCTAssertEqual(
            AutopilotService.retainedDraftAction(sessionOpen: true, twin: .unreadable),
            .keep(forceManualOnly: true))
    }

    func testFailureTailRoutesTheQueueThroughTheAction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let body = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "private func executeSend").last!
        // The action has to be what decides, and it has to decide before the
        // queue is touched: an `if` that only logs would keep the old behaviour.
        let decide = try XCTUnwrap(body.range(of: "let action = Self.retainedDraftAction(")).lowerBound
        let append = try XCTUnwrap(
            body.range(of: "pendingSendQueue.append(retained)", range: decide..<body.endIndex)
        ).lowerBound
        XCTAssertLessThan(decide, append, "the queue append must be downstream of the twin read")
        XCTAssertTrue(body.contains("case .drop:\n            return .blocked(failureReason)"))
        XCTAssertTrue(body.contains("if forceManualOnly, retained.manualOnlyReason == nil {"))
    }

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
        let body = try XCTUnwrap(
            source.components(separatedBy: "private static func performTextAction").last,
            "锚点没了：这条判据不能对整篇文件断言")
        let checkpoints = body.components(separatedBy: "await sendStillAllowed(abortCheck)").count - 1
        XCTAssertEqual(checkpoints, 2, "一次在粘贴前，一次在按发送键前")

        // Both, not just the first: the count alone also holds when the second
        // guard is moved below the send key, which is the one that matters.
        let sendKey = try XCTUnwrap(body.range(of: "switch sendKey {"), "找不到发送键")
        let paste = try XCTUnwrap(body.range(of: "postCmdKey(kVK_ANSI_V)"), "找不到粘贴")
        var cursor = body.startIndex
        var firstCheckpoint: String.Index?
        for index in 0..<2 {
            let found = try XCTUnwrap(
                body.range(of: "await sendStillAllowed(abortCheck)", range: cursor..<body.endIndex),
                "只有 \(index) 个检查点")
            XCTAssertLessThan(found.lowerBound, sendKey.lowerBound,
                              "第 \(index + 1) 个检查点必须严格早于按发送键")
            if index == 0 { firstCheckpoint = found.lowerBound }
            cursor = found.upperBound
        }
        XCTAssertLessThan(paste.lowerBound, sendKey.lowerBound, "粘贴本身要在发送键之前")
        XCTAssertGreaterThan(paste.lowerBound, firstCheckpoint ?? body.endIndex,
                             "粘贴这一步本身要落在第一个检查点之后，否则检查点管不到它")
        XCTAssertTrue(body.contains("return .failed(.withdrawnBeforeSend)"))
    }

    /// The gate can only refuse what it is handed: after a failed write-back the
    /// database row is still 'pending', so a second 确认发送 passes every row
    /// check and sends a duplicate to a real person. The local set is the only
    /// thing standing in the way, and it is invisible to `mayStillDeliver`'s
    /// unit tests unless the call site actually feeds it.
    func testUnresolvedSendWriteIsRecordedAndConsulted() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // Only 确认发送 那一段：`.writeFailed` 在重试函数里也有一次，切片越界的话
        // 这条断言就由重试函数满足了，发送路径删掉它也不会红。
        let fromApproval = try XCTUnwrap(
            source.components(separatedBy: "func approvePending(logId:").last,
            "锚点没了")
        let approval = fromApproval.components(separatedBy: "func retryUnresolvedSendWrites").first ?? ""
        XCTAssertFalse(approval.isEmpty, "切片不能为空")
        XCTAssertTrue(approval.contains("case .writeFailed:"), "发送后要区分『写回了』和『没写回』")
        XCTAssertTrue(approval.contains("unresolvedSentLogWrites.insert(logId)"),
                      "写回失败必须记下这条，否则闸门什么都不知道")
        XCTAssertTrue(source.contains("alreadySentHere: logId.map { unresolvedSentLogWrites.contains($0) }"),
                      "闸门必须真的读这个集合")
        // 声明本身也叫这个名字，所以 `contains` 一句是空判：要看的是真的有人调它。
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "retryUnresolvedSendWrites()").count - 1, 2,
            "写回要重试，不然这条草稿永远卡在待确认里"
        )
        XCTAssertTrue(source.contains("rejectedHere: logId.map { unresolvedSkippedLogWrites.contains($0) }"),
                      "取消侧的集合也必须真的喂给闸门，否则那条被取消的草稿照样能发")
    }
}
