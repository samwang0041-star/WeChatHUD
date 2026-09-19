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
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: true, approvalRowPending: nil,
            queueHeldHere: true),
            "收口失败的已投递队列行不能再发一次给同一个人")
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
        let openStillAllowed = await service.deliveryStillPermitted(queueId: nil, logId: openId, chatUsername: nil)
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
        let cancelledHeld = await service.deliveryStillPermitted(queueId: nil, logId: openId, chatUsername: nil)
        XCTAssertFalse(cancelledHeld, "写回失败的取消也必须拦住发送")
    }

    /// 只在一条 id 轴上记账 = 另一条轴上的闸门一直是开的。`approvePending` 的 gate
    /// 传的是 `queueId: nil`，而「取消本条」写失败时那条日志行仍然是 'pending' ——
    /// 只记队列轴的话，「待确认回复」上那颗按钮照样能按，用户取消掉的回复还是会发给真人。
    @MainActor
    func testFailedCancelWriteHoldsBothIdAxes() async throws {
        let sid = try XCTUnwrap(
            store.loadAutopilotSessions(limit: 1).first?.id,
            "start() 没建出会话 ⇒ 这条测试什么都没验")
        let queueId = UUID()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            triggerMsgUID: "shard/Msg_x/1", triggerText: "结论有了吗",
            generatedReply: "我下午给你结论", confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: queueId.uuidString
        ))
        let logId = try XCTUnwrap(store.loadAutopilotLog(sessionId: sid).first?.id)
        let pending = item("我下午给你结论")
        let twin = PendingSend(
            id: queueId, chatUsername: pending.chatUsername, chatName: pending.chatName,
            senderName: pending.senderName, replyText: pending.replyText,
            confidence: 0.9, risk: .low, reasoning: "ok", styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(-1)
        )
        try store.upsertPendingSend(twin, sessionId: sid)
        let control = await service.deliveryStillPermitted(queueId: nil, logId: logId, chatUsername: nil)
        XCTAssertTrue(control, "没被取消过的行不该被拦住")

        try store.exec("""
            CREATE TRIGGER break_log_update BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'simulated log write failure'); END
            """)
        await service.cancelPendingSend(id: queueId)

        XCTAssertFalse(store.hasPendingSend(id: queueId), "这条路径上队列行删掉了")
        XCTAssertEqual(store.autopilotLogPendingReply(id: logId), "我下午给你结论",
                       "日志行仍是 pending —— 待确认那颗按钮还活着")
        let viaQueueAxis = await service.deliveryStillPermitted(queueId: queueId, logId: nil, chatUsername: nil)
        XCTAssertFalse(viaQueueAxis, "队列轴上必须记着")
        let viaLogAxis = await service.deliveryStillPermitted(queueId: nil, logId: logId, chatUsername: nil)
        XCTAssertFalse(viaLogAxis, "确认发送只读 logId 轴，跨轴也必须拦住")
    }

    /// 队列行的终态写回失败 = 那行还在表里 = 恢复会话或重启后它会被再发一次。
    /// 用触发器只让 DELETE 失败：读一切正常，所以闸门唯一的依据就是这个本地集合
    /// （上一版整张表删掉的写法被另一个信号满足了，见 §169）。
    @MainActor
    func testCancelWithFailedQueueDeleteIsHeldThenReleasedWhenTheWriteLands() async throws {
        let sid = try XCTUnwrap(
            store.loadAutopilotSessions(limit: 1).first?.id,
            "start() 没建出会话 ⇒ 这条测试什么都没验")
        let pending = item("我下午给你结论")
        try store.upsertPendingSend(pending, sessionId: sid)
        let control = await service.deliveryStillPermitted(queueId: pending.id, logId: nil, chatUsername: nil)
        XCTAssertTrue(control, "没被动过手脚的队列行不该被这条闸门拦住")

        try store.exec("""
            CREATE TRIGGER break_queue_delete BEFORE DELETE ON autopilot_pending_sends
            BEGIN SELECT RAISE(ABORT, 'simulated delete failure'); END
            """)
        await service.cancelPendingSend(id: pending.id)

        let held = await service.unresolvedQueueWritesSnapshot[pending.id]
        XCTAssertEqual(
            held, .cancelled(chatUsername: "wxid_peer", replyText: "我下午给你结论"),
            "删除失败必须被记下来，而不是只 print 一行"
        )
        XCTAssertTrue(store.hasPendingSend(id: pending.id), "盘上这行确实还在 —— 所以才需要拦")
        let afterCancel = await service.deliveryStillPermitted(queueId: pending.id, logId: nil, chatUsername: nil)
        XCTAssertFalse(afterCancel, "写回失败的取消必须拦住发送")

        // 先验一次「重试仍然失败」：这时集合必须仍然拦着。上一版只验了成功那次，
        // 于是「失败也放掉」的变异是活的 —— 那等于写回失败一次就再也不拦。
        await service.retryUnresolvedSendWrites()
        let stillHeld = await service.unresolvedQueueWritesSnapshot[pending.id]
        XCTAssertNotNil(stillHeld, "写还没成就不能放掉这条")
        XCTAssertTrue(store.hasPendingSend(id: pending.id))
        let afterFailedRetry = await service.deliveryStillPermitted(queueId: pending.id, logId: nil, chatUsername: nil)
        XCTAssertFalse(afterFailedRetry, "重试失败的这一轮也照样不许发")

        try store.exec("DROP TRIGGER break_queue_delete")
        await service.retryUnresolvedSendWrites()
        XCTAssertFalse(store.hasPendingSend(id: pending.id), "重试成功时必须真的把这行清掉")
        let snapshot = await service.unresolvedQueueWritesSnapshot
        XCTAssertTrue(snapshot.isEmpty, "写成了就该放掉这条，否则这条闸门永远抬不起来")
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
                conversationMuted: false,
keystrokesMayHaveLanded: false,
                                reason: "这条回复在按下发送前已经停住，微信没有收到。", retryableReason: false),
            .requeueUnchanged(reason: "自动驾驶暂停，这条没有发出，仍留在队列里。"))
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: false,
keystrokesMayHaveLanded: false,
                                reason: "发送结果无法确认", retryableReason: false),
            .humanRequired(reason: "发送结果无法确认，已转为人工确认"))
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: false,
keystrokesMayHaveLanded: false,
                                reason: "已有发送正在进行", retryableReason: true),
            .requeueUnchanged(reason: "已有发送正在进行"))
        // The real reason strings are complete sentences ending in 。; the
        // concatenation this replaces printed
        // 「…，微信没有收到。，已转为人工确认」 on the approval card.
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: false,
keystrokesMayHaveLanded: false,
                                reason: "这条回复在按下发送前已经停住，微信没有收到。", retryableReason: false),
            .humanRequired(reason: "这条回复在按下发送前已经停住，微信没有收到，已转为人工确认"))
    }

    /// 静音此对话 is a permission the user can revoke, so it cannot be allowed
    /// to leave a permanent verdict on the draft. Before this branch existed the
    /// mute refusal fell into the 「发送失败」 tail: the row got
    /// `manualOnlyReason = "…请先检查微信，再手动处理"`, which
    /// `isEligibleForAutomaticSend` reads as a disqualifier forever —取消静音
    /// never gave the draft back, and the receipt blamed WeChat for something
    /// nothing had failed at.
    func testMuteRefusalNeverBurnsTheDraftAsManualOnly() {
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: true,
keystrokesMayHaveLanded: false,
                                reason: "发送前已撤回，微信没有收到。", retryableReason: false),
            .requeueUnchanged(reason: "这个对话已静音，这条没有发出，仍留在队列里。"))
        // Positive control: the same reason with an unmuted conversation is
        // still a real failure, so the branch cannot pass by never stamping.
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: false,
keystrokesMayHaveLanded: false,
                                reason: "发送前已撤回，微信没有收到。", retryableReason: false),
            .humanRequired(reason: "发送前已撤回，微信没有收到，已转为人工确认"))
    }

    /// Wiring: the failure tail must ask the durable table, not a flag. A mute
    /// lands while the send is already in flight, so only the 「永久静音」 row
    /// can tell the two cases apart afterwards.
    func testFailureTailAsksTheDurableMuteTable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let tail = try XCTUnwrap(
            source.components(separatedBy: "let disposition = Self.sendFailureDisposition(").last
        ).components(separatedBy: "if case .humanRequired").first ?? ""
        XCTAssertFalse(tail.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertTrue(tail.contains("conversationMuted: conversationIsMuted(item.chatUsername)"),
                      "记账必须按这条草稿所属的对话去查静音表，否则永远传 false")
        // One predicate, both consumers: the gate and the bookkeeping must not
        // keep their own copy of "is this chat muted".
        let gate = source.components(separatedBy: "func deliveryStillPermitted(").last ?? ""
        XCTAssertTrue(gate.components(separatedBy: "conversationIsMuted(").count - 1 >= 1,
                      "闸门也要走同一个读法")
        let helper = (source.components(separatedBy: "private func conversationIsMuted(").last ?? "")
            .components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertFalse(helper.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertTrue(helper.contains("isPermanentlySilenced("),
                      "读法要落在 §180 的那个哨兵上，而不是自己再比一次时间")
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

        let live = await service.deliveryStillPermitted(queueId: queued.id, logId: nil, chatUsername: nil)
        XCTAssertTrue(live, "an untouched in-flight row must stay sendable")

        await service.manualPause()
        let paused = await service.deliveryStillPermitted(queueId: queued.id, logId: nil, chatUsername: nil)
        XCTAssertFalse(paused)
        await service.manualResume()

        try store.deletePendingSend(id: queued.id)
        let withdrawn = await service.deliveryStillPermitted(queueId: queued.id, logId: nil, chatUsername: nil)
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

        let open = await service.deliveryStillPermitted(queueId: nil, logId: logId, chatUsername: nil)
        XCTAssertTrue(open, "人还没撤回 ⇒ 允许发送")

        await service.rejectPending(logId: logId, chatUsername: "wxid_peer", replyText: reply)
        let closed = await service.deliveryStillPermitted(queueId: nil, logId: logId, chatUsername: nil)
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
        let after = await service.deliveryStillPermitted(queueId: flying.id, logId: nil, chatUsername: nil)
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

    /// The paste path pressed `Cmd+A` before `Cmd+V` — which selects whatever
    /// the human had typed and not yet sent and throws it away. Nothing else in
    /// the app can undo that, and it happened in exactly the mode where the user
    /// is standing in WeChat. The predicate is the decision; the wiring gate is
    /// the proof it runs before the first keystroke that can destroy anything.
    func testInputBoxWithUnsentTextIsNeverSelectedAndOverwritten() {
        XCTAssertTrue(WeChatLauncher.inputBoxIsSafeToOverwrite(readValue: nil),
                      "读不到不能当成『有人写了东西』——那会让托管在微信改版后永久失灵")
        XCTAssertTrue(WeChatLauncher.inputBoxIsSafeToOverwrite(readValue: ""))
        XCTAssertTrue(WeChatLauncher.inputBoxIsSafeToOverwrite(readValue: "  \n\t "))
        XCTAssertFalse(WeChatLauncher.inputBoxIsSafeToOverwrite(readValue: "半句话没打完"))

        // The paste-side re-read has a different question: after `Cmd+V` the box
        // is *supposed* to hold our text, so "matches what we pasted" is the
        // test, and an empty box (paste never landed) must still let Return
        // through — it does nothing.
        XCTAssertTrue(WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: nil, expecting: "回复"))
        XCTAssertTrue(WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: "", expecting: "回复"))
        XCTAssertTrue(WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: "回复", expecting: "回复"))
        XCTAssertTrue(WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: "回复\r\n第二行", expecting: "回复\n第二行"),
                      "换行符的写法不该变成拒绝发送的理由")
        XCTAssertFalse(WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: "我的半句回复", expecting: "回复"),
                       "人和助手的内容拼在一起发出去，是最坏的一种")
        XCTAssertFalse(WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: "回复 还有我加的一句", expecting: "回复"))
    }

    /// …and the gate is on the real keystroke sequence, not just defined.
    func testDraftGateRunsBeforeTheFirstSelectAll() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/WeChatLauncher.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(
            source.components(separatedBy: "private static func performTextAction").last,
            "锚点没了：这条判据不能对整篇文件断言")
        // `postCmdKey(kVK_ANSI_A)` also appears later in this slice (navigation
        // and retraction live below), so pin the order against the *first* one.
        let firstSelectAll = try XCTUnwrap(
            body.range(of: "postCmdKey(kVK_ANSI_A)"),
            "找不到全选")
        let paste = try XCTUnwrap(body.range(of: "postCmdKey(kVK_ANSI_V)"), "找不到粘贴")
        let sendKey = try XCTUnwrap(body.range(of: "switch sendKey {"), "找不到发送键")

        // Twice, not once: the box can gain text in the awaits between the
        // select-all and the paste, and a `Cmd+A` over an empty selection makes
        // the paste *insert* into whatever the human typed in that gap.
        // `guard ` prefix so the predicate's own definition does not count.
        let emptyBoxChecks = body.components(separatedBy: "guard inputBoxIsSafeToOverwrite(readValue:").count - 1
        XCTAssertEqual(emptyBoxChecks, 2, "全选前和粘贴前各要读一次输入框")
        var cursor = body.startIndex
        for index in 0..<2 {
            let found = try XCTUnwrap(
                body.range(of: "guard inputBoxIsSafeToOverwrite(readValue:", range: cursor..<body.endIndex),
                "只有 \(index) 处读输入框")
            if index == 0 {
                XCTAssertLessThan(found.lowerBound, firstSelectAll.lowerBound,
                                  "第一次必须早于全选，否则读到的是已经被自己清掉的东西")
            } else {
                XCTAssertLessThan(found.lowerBound, paste.lowerBound,
                                  "第二次必须紧贴粘贴，否则中间那段 await 里人打的字会被拼进去")
                XCTAssertGreaterThan(found.lowerBound, firstSelectAll.lowerBound)
            }
            cursor = found.upperBound
        }
        // Third question, at the last moment before a real recipient sees it.
        let finalCheck = try XCTUnwrap(
            body.range(of: "guard pastedBoxStillHoldsOnlyTheReply("),
            "发送键前没有回读输入框")
        // The withdrawal path (`retractPastedDraft`) presses Cmd+A + Delete too,
        // and it runs *after* the paste — so a human who typed in the gap loses
        // their words to the retraction that was meant to undo only ours.
        let boxReads = body.components(separatedBy: "readInputBoxValue(input)").count - 1
        XCTAssertGreaterThanOrEqual(boxReads, 4,
                                    "全选前/粘贴前/发送键前/撤回前，每一处按键前都要先读框")
        XCTAssertLessThan(finalCheck.lowerBound, sendKey.lowerBound)
        XCTAssertGreaterThan(finalCheck.lowerBound, paste.lowerBound)
        XCTAssertTrue(body.contains("return .failed(.inputHasUnsentDraft)"),
                      "拦下来要给出可行动的理由，而不是笼统的失败")
        XCTAssertTrue(body.contains("return .failed(.pastedBoxChanged)"))
        XCTAssertLessThan(paste.lowerBound, sendKey.lowerBound, "粘贴本身要在发送键之前")
    }

    /// Both refusals have to say the reply did *not* go out — a user who reads
    /// 「没有覆盖它」 and assumes the draft was sent anyway is the failure this
    /// whole axis exists to prevent.
    func testBothBoxRefusalsSayNothingWasSent() {
        let draft = WeChatLauncher.SendFailureReason.inputHasUnsentDraft.userMessage
        XCTAssertTrue(draft.contains("没有覆盖"), draft)
        XCTAssertTrue(draft.contains("未发出"), draft)
        let changed = WeChatLauncher.SendFailureReason.pastedBoxChanged.userMessage
        XCTAssertTrue(changed.contains("没有按下发送"), changed)
    }

    /// `handleNewMessages` captures the session id before its first await and
    /// `processBatch` stamps the log row from that parameter while the queue
    /// twin is written from the *live* property — so a 停止 landing during the
    /// model call used to record a 待确认 card for a session that no longer
    /// exists, backed by no draft.
    ///
    /// Priced honestly: the interleaving itself has no test, because
    /// `generator` is a concrete `AutoReplyGenerator` and nothing in the tree
    /// can make that await hang on purpose. This gate pins where the re-check
    /// sits; it does not prove the race is closed.
    func testStoppedSessionCannotRecordABatchItNeverOwned() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let fromAwait = try XCTUnwrap(
            source.components(separatedBy: "let entry = await processBatch(").last,
            "锚点没了")
        let upToInsert = fromAwait.components(separatedBy: "try store.insertAutopilotLog(entry)").first ?? ""
        XCTAssertFalse(upToInsert.isEmpty, "切片不能为空")
        XCTAssertTrue(upToInsert.contains("if sid != sessionId"),
                      "await 之后、记账之前要重读会话，否则记的是上一个会话的决定")
        // 只看字面存在会被「重读了但没跳过」满足 —— 那条分支必须真的 continue。
        let branch = try XCTUnwrap(
            upToInsert.components(separatedBy: "if sid != sessionId").last
        ).components(separatedBy: "\n            }").first ?? ""
        XCTAssertTrue(branch.contains("continue"),
                      "重读到了却不跳过记账，等于什么都没拦")
        XCTAssertEqual(
            branch.components(separatedBy: "pendingSendQueue.removeAll { $0.id == uuid }").count - 1, 1,
            "跳过记账的同时要把内存里那条幽灵草稿撤掉")
        // 内存之外还有 DB 那一半：:1419 用的是活着的 sessionId，stop→start 会把
        // 这条草稿记到**新**会话下，start() 再水化后就自己发出去了。
        XCTAssertTrue(branch.contains("try store.deletePendingSend(id: uuid)"),
                      "只删内存不删 DB 孪干 = 停掉的那条草稿在新会话里等着发")
        XCTAssertTrue(branch.contains("unresolvedQueueWrites[uuid] = .cancelled"),
                      "删不掉的时候要按 §171 的形态挂住，而不是当没事发生")
    }

    /// 「读不到配置」 is not an answer a send guard may guess at: the default
    /// keyword list drops whatever the user added, and the default cap of 50
    /// overrules a user who set 5.
    func testSendGuardsReadTheConfigThroughOneHonestHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let files = ["Services/AutopilotService.swift", "Services/ChatMonitor.swift"]
        var sites = 0
        for name in files {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            sites += source.components(separatedBy: "autopilotConfigForSendGate()").count - 1
        }
        XCTAssertGreaterThanOrEqual(sites, 3,
                                    "队列 tick、生成、人工确认三处发送闸门都要走同一个读法")
        let service = try String(contentsOf: root.appendingPathComponent(files[0]), encoding: .utf8)
        let approval = try XCTUnwrap(
            service.components(separatedBy: "func approvePending(logId:").last
        ).components(separatedBy: "func retryUnresolvedSendWrites").first ?? ""
        // The *call*, not the phrase: the comment above the guard spells out
        // what used to be there, and matching that made this gate red on the fix.
        XCTAssertFalse(approval.contains("getSettingJSON(\"autopilot\""),
                       "确认发送这段里不许再出现「读不到就用默认值」")
        // 两处投递闸门都要真的把「这是哪条对话」交给 gate，否则静音那条输入永远是 nil。
        let gateWired = service.components(
            separatedBy: "deliveryStillPermitted(queueId:").count - 1
        XCTAssertGreaterThanOrEqual(gateWired, 2, "队列与人工确认两条路都要问闸门")
        XCTAssertFalse(service.contains("deliveryStillPermitted(queueId: nil, logId: logId)"),
                       "人工确认那条要带上对话名，否则静音拦不住它")
        // 这条谓词的最后一个消费点：发送键。它以前是全仓最后一处
        // `getSettingJSON("autopilot", ...) ?? AutopilotConfig()`，而它在
        // 真人按「确认发送」的那条路上 —— 猜错键要么把已确认的文本留在框里，
        // 要么提前发出去。
        XCTAssertEqual(service.components(separatedBy: "getSettingJSON(\"autopilot\"").count - 1, 0,
                       "托管设置只许经诚实读法进入按键路径")
        XCTAssertTrue(service.contains("guard let sendConfig = store.autopilotConfigForSendGate()"),
                      "读不到发送键必须停住，而不是猜一个默认发送键")
        XCTAssertTrue(service.contains("sendKey: sendConfig.sendKey"),
                      "闸门之后要用那次读到的键，不要再读第二次")
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
        // 队列轴：已验证投递之后只是收口失败的那条，和取消写失败的那条，都必须记下来；
        // 而且两条都要同时喂给另一根 id 轴（approvePending 只读 logId）。
        XCTAssertEqual(source.components(separatedBy: "unresolvedQueueWrites[item.id] = hold").count - 1, 2,
                       "两处终态写回失败都必须记队列轴，一处漏了那条闸门就永远读不到它")
        // 第三条：人工「确认发送」之后孪干删不掉，同样要记队列轴（那条路没有测试能走）。
        XCTAssertTrue(source.contains("unresolvedQueueWrites[twinQueueId] = .delivered("),
                      "确认发送后的收口失败也必须记队列轴")
        XCTAssertEqual(source.components(separatedBy: "holdTwinLog(for: item.id, kind: hold)").count - 1, 2,
                       "两根轴必须同时记：确认发送只读 logId 轴")
        XCTAssertTrue(source.contains("case .delivered: unresolvedSentLogWrites.insert(logId)"))
        XCTAssertTrue(source.contains("case .cancelled: unresolvedSkippedLogWrites.insert(logId)"))
        XCTAssertTrue(source.contains("queueHeldHere: queueId.map { unresolvedQueueWrites[$0] != nil }"))
    }

    /// 「静音此对话」 is a withdrawal, not just an invisibility cloak. Gating the
    /// two ingest feeds is one half of that; a draft already queued when the
    /// user mutes is the other half, and `deliveryStillPermitted` is the last
    /// place that can still stop it. The expired-watermark case is what keeps
    /// this from turning every one-time silence into a permanent one.
    @MainActor
    func testMutingAConversationWithdrawsWhatIsAlreadyQueued() async throws {
        let sessionId = try store.startAutopilotSession()
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sessionId, chatUsername: "wxid_muted", chatName: "同事乙",
            senderUsername: "wxid_muted", senderName: "同事乙",
            triggerMsgUID: "shard/Msg_g/9", triggerText: "在吗",
            generatedReply: "在的", confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date()
        ))
        let logId = try XCTUnwrap(store.loadAutopilotLog(sessionId: sessionId).first?.id)
        let now = Int(Date().timeIntervalSince1970)

        let before = await service.deliveryStillPermitted(
            queueId: nil, logId: logId, chatUsername: "wxid_muted")
        XCTAssertTrue(before, "对照组：没静音时这一行是允许发的")

        try store.silenceChat(chatUsername: "wxid_muted", silencedAt: now + 10 * 365 * 24 * 3600)
        let muted = await service.deliveryStillPermitted(
            queueId: nil, logId: logId, chatUsername: "wxid_muted")
        XCTAssertFalse(muted, "刚静音的对话仍然被回一条，而且那正是唯一能看见它的界面")

        try store.silenceChat(chatUsername: "wxid_muted", silencedAt: now - 60)
        let expired = await service.deliveryStillPermitted(
            queueId: nil, logId: logId, chatUsername: "wxid_muted")
        XCTAssertTrue(expired, "过期的 silencedAt 不是静音")
    }

    /// The pure half of the same rule, so a caller that cannot pass a username
    /// cannot accidentally read "muted" as "not muted".
    func testMayStillDeliverTreatsMutedAsWithdrawn() {
        XCTAssertTrue(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: true, approvalRowPending: nil))
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, conversationMuted: true,
            queueRowLive: true, approvalRowPending: nil),
                       "静音必须和「已发过」「已取消」同级")
    }

    /// `.absent` and `.corrupt` used to be one answer, and for a send guard the
    /// two are opposite: 「没存过」 means the safe defaults, 「存着但读不懂」 must
    /// mean 不发 —— otherwise a half-written row opens the two gates the doc
    /// says this helper exists to close.
    @MainActor
    func testCorruptStoredConfigRefusesTheSendGate() throws {
        let fresh = store.autopilotConfigForSendGate()
        XCTAssertNotNil(fresh, "从没存过 → 用默认值是安全的")
        try store.setSetting("autopilot", value: "{这不是 JSON")
        XCTAssertNil(store.autopilotConfigForSendGate(),
                     "存着但解不开，不能当成「用户没设过，用默认敏感词表和上限 50」")
        // The settings page still has to be able to save its way out of that.
        XCTAssertTrue(try store.updateAutopilotConfig { $0.autoSendEnabled = true })
        XCTAssertEqual(store.autopilotConfigForSendGate()?.autoSendEnabled, true)
    }

    /// The three overwrite guards fail *open* on a nil AX read on purpose: a
    /// WeChat build that stops exposing `kAXValueAttribute` must not turn into
    /// "auto-send never works". Retraction is the opposite caller — it runs
    /// after the send was already abandoned, and the only thing it risks is a
    /// draft staying in the box. Guessing there means `Cmd+A`+Delete into text
    /// this process never read, which is the loss the guards were added for.
    func testRetractionRefusesToDeleteOnAnUnreadableBox() {
        XCTAssertFalse(
            WeChatLauncher.boxIsKnownToHoldOnlyTheReply(readValue: nil, expecting: "你好"),
            "读不到输入框时不许全选删除")
        XCTAssertTrue(
            WeChatLauncher.pastedBoxStillHoldsOnlyTheReply(readValue: nil, expecting: "你好"),
            "发送侧仍是刻意失败打开：看不见不等于拦住")
        // Same read, both directions agree once there is content to compare.
        XCTAssertTrue(WeChatLauncher.boxIsKnownToHoldOnlyTheReply(readValue: "你好", expecting: "你好"))
        XCTAssertFalse(WeChatLauncher.boxIsKnownToHoldOnlyTheReply(readValue: "你好，还有我打的字", expecting: "你好"))
        XCTAssertTrue(WeChatLauncher.boxIsKnownToHoldOnlyTheReply(readValue: "   ", expecting: "你好"),
                      "空盒里全选删除不丢任何东西")
    }

    /// Wiring: a correct predicate that the destructive caller doesn't use is
    /// the defect, not a mitigation.
    func testRetractCallSiteUsesTheFailClosedPredicate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/WeChatLauncher.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(
            source.components(separatedBy: "private static func retractPastedDraft(").last
        ).components(separatedBy: "@MainActor private static func accountFailure").first ?? ""
        XCTAssertFalse(body.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertEqual(body.components(separatedBy: "boxIsKnownToHoldOnlyTheReply(").count - 1, 1,
                       "撤回必须只走失败关闭的那个读法")
        XCTAssertFalse(body.contains("pastedBoxStillHoldsOnlyTheReply("),
                       "撤回里出现失败打开的谓词 = 读不到就删别人的字")
        // Every keystroke that selects all is a chance to destroy text, so each
        // one has to be preceded by the guard that fits its surface: the message
        // box before overwriting, the message box before retracting, and WeChat's
        // search field (whose contents are a query, not the human's draft).
        let chunks = source.components(separatedBy: "postCmdKey(kVK_ANSI_A)")
        XCTAssertEqual(chunks.count - 1, 3, "全选键的总数变了要逐条看，不能默认安全")
        for (index, chunk) in chunks.dropLast().enumerated() {
            let tail = String(chunk.suffix(700))
            XCTAssertTrue(
                tail.contains("inputBoxIsSafeToOverwrite")
                    || tail.contains("boxIsKnownToHoldOnlyTheReply")
                    || tail.contains("findSearchField"),
                "第 \(index + 1) 处 Cmd+A 前面没有任何守卫")
        }
    }

    /// 「读不到托管设置」 used to be answered with the built-in config on the four
    /// human-pressed send paths, so a half-written row meant 立即发送 ran with the
    /// stock 敏感词 list, the stock 每小时/每会话上限 and a guessed 发送键 —— the
    /// exact widening the autopilot gates were closed against one commit earlier.
    func testManualSendPathsRefuseAnUnreadableConfig() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let monitor = try String(
            contentsOf: root.appendingPathComponent("Services/ChatMonitor.swift"), encoding: .utf8)
        let body = monitor.components(separatedBy: "func loadAutopilotConfig() -> AutopilotConfig?").last ?? ""
        XCTAssertFalse(body.isEmpty, "锚点没了：这个读法又 returning 非可选了")
        XCTAssertTrue(body.hasPrefix(" {\n        store.autopilotConfigForSendGate()\n    }"),
                      "手动发送的读法必须就是那个诚实读法")
        XCTAssertFalse(body.components(separatedBy: "\n    }\n").first?
            .contains("?? AutopilotConfig()") ?? false,
                       "这里不许再用默认值兜底")

        var sites = 0
        for name in ["Views/AutopilotTabView.swift",
                     "Views/ApprovalWorkspaceView.swift",
                     "Views/ConversationDetailView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            sites += text.components(separatedBy: "guard let config = monitor.loadAutopilotConfig()").count - 1
            XCTAssertFalse(text.contains("monitor.loadAutopilotConfig()."),
                           "\(name) 还在把可选读法当非可选直接用")
        }
        XCTAssertEqual(sites, 4, "编辑后发送/立即发送/审批台/对话详情四处都要拦，少一处就是漏")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Views/AutopilotTabView.swift"), encoding: .utf8)
                .components(separatedBy: "ChatMonitor.unreadableConfigNotice").count - 1, 2,
            "同一句拒绝话术要出现在这一页的两个按钮上")
    }

    /// The ghost-branch hold used to be registered `if let ghost`, i.e. only when
    /// this process still had the row in memory — but `stop()` clears that copy,
    /// which is the whole reason the branch exists. The DB twin then survives a
    /// failed delete with nobody holding the gate.
    func testGhostHoldDoesNotDependOnTheMemoryCopy() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let branch = (source.components(separatedBy: "if sid != sessionId {").last ?? "")
            .components(separatedBy: "if entry.action == .skipped").first ?? ""
        XCTAssertFalse(branch.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertFalse(branch.contains("if let ghost {"),
                       "挂住这条不许以内存里还留着它为条件")
        XCTAssertTrue(branch.contains("chatUsername: ghost?.chatUsername ?? entry.chatUsername"),
                      "内存没有就用批次结果兜上，闸门不许读到 nil")
        XCTAssertTrue(branch.contains("replyText: ghost?.replyText ?? entry.generatedReply"),
                      "同上：文本也要有第二来源")
    }

    /// 「暂停」 and 「静音」 both answer 「这条还要不要自动发」, and both are blind to
    /// the one fact that decides it: whether a keystroke already went in.
    /// Send key lands → WeChat's WCDB flush is slow → three 500 ms polls fail
    /// (`"发送后未在微信数据库中确认"`) → the user pauses or mutes inside that
    /// 1.5 s. Re-queueing there keeps the draft automatically send-eligible with
    /// its original `scheduledSendTime`, so unmuting (or resuming) sends the peer
    /// the same text a second time. `manualOnlyReason` was the only thing
    /// preventing that, and neither withdrawal fact may overrule it.
    func testWithdrawalBranchesCannotOverruleALandedKeystroke() {
        let unverified = "发送后未在微信数据库中确认"
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: true, keystrokesMayHaveLanded: true,
                reason: unverified, retryableReason: false),
            .humanRequired(reason: "\(unverified)，已转为人工确认"),
            "静音不能把『键已按下、只是没确认』洗成『什么都没发』")
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: true, sessionOpen: true, rowStillQueued: true,
                conversationMuted: false, keystrokesMayHaveLanded: true,
                reason: unverified, retryableReason: false),
            .humanRequired(reason: "\(unverified)，已转为人工确认"),
            "暂停同理：这条在 §179 之前就有 manualOnlyReason 挡着重复发送")
        // Positive controls: nothing typed still withdraws, so the new gate
        // cannot pass by simply never re-queueing.
        XCTAssertEqual(
            AutopilotService.sendFailureDisposition(
                paused: false, sessionOpen: true, rowStillQueued: true,
                conversationMuted: true, keystrokesMayHaveLanded: false,
                reason: "发送前已撤回，微信没有收到。", retryableReason: false),
            .requeueUnchanged(reason: "这个对话已静音，这条没有发出，仍留在队列里。"))
    }

    /// Wiring for the landed-keystroke fact: it has to be reset per send and set
    /// at the one place that knows the keys went in.
    func testLandedKeystrokeFlagIsResetAndSetAtTheRightPlace() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let resets = source.components(
            separatedBy: "lastSendKeystrokesMayHaveLanded = false").count - 1
        XCTAssertGreaterThanOrEqual(resets, 1, "每次发送前必须清零，否则会沿用上一条的结论")
        let setTrue = source.range(of: "lastSendKeystrokesMayHaveLanded = true")
        let reset = source.range(of: "lastSendKeystrokesMayHaveLanded = false")
        XCTAssertNotNil(setTrue, "确认失败那一处必须把它设为 true")
        XCTAssertNotNil(reset)
        XCTAssertLessThan(reset!.lowerBound, setTrue!.lowerBound, "先清后置")
        // The rate limiter's own early refusals happen before serialSend runs, so
        // the reset must sit at the outer entry point too.
        let limiter = (source.components(separatedBy: "private func serialSendWithRateLimit(").last ?? "")
            .components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(limiter.contains("lastSendKeystrokesMayHaveLanded = false"),
                      "外层入口也要清零：限流拒绝根本没进过 serialSend")
    }

    /// The mute gate used to sit inside the launcher, after WeChat had already
    /// been activated, the search box opened and the conversation switched. A
    /// muted chat with a queued draft therefore stole the foreground once a
    /// minute for the ~10 minutes until staleness retired the draft — the user
    /// asked the assistant never to touch that conversation.
    func testExecuteSendRefusesAMutedChatBeforeNavigating() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = (source.components(separatedBy: "conversationIsMuted(item.chatUsername) {").last ?? "")
            .components(separatedBy: "let typingDelay").first ?? ""
        XCTAssertFalse(body.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertTrue(body.contains("pendingSendQueue.append(item)"),
                      "静音短路要把草稿放回队列，否则它凭空消失")
        XCTAssertTrue(body.contains("return .blocked"),
                      "短路必须真的返回，而不是记一笔继续往下走")
        XCTAssertFalse(body.contains("serialSend"),
                       "这一段的语义就是「一行都不许敲」")
    }

    /// 「没敲键」 and 「敲了但没确认」 were both printed as the latter on the approval
    /// board, so confirming a reply in a muted conversation told the user to go
    /// look at WeChat for a message that had never been typed.
    func testApprovalBoardDoesNotBlameWeChatForAMuteRefusal() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift")
        let view = try String(contentsOf: url, encoding: .utf8)
        let between = view.components(separatedBy: "func confirmSend() async {").last ?? ""
            .components(separatedBy: "approveAutopilotItem").first ?? ""
        XCTAssertTrue(between.contains("silencedConversations"),
                      "确认发送前要先知道这条对话被静音了")
        XCTAssertTrue(between.contains("return"), "静音时要给出自己的说法，别落到「结果待核对」")
        XCTAssertFalse(CompanionProductCopy.sendUncertain.contains("已静音"))
    }
    /// 「确认发送」 is the one send path a human drives, and its only idempotency
    /// credential was a synchronous 'pending' read whose row is not resolved until
    /// the send returns. `serialSend` releases `isSending` as soon as the keystrokes
    /// come back, i.e. *before* the resolve — so a second click (or a second surface
    /// showing the same row) could pass every guard here and type the same reply to
    /// the same person twice.
    func testApprovalClaimNeedsBothFactsAtOnce() {
        XCTAssertTrue(AutopilotService.mayStartApproval(rowPending: true, alreadyInFlight: false))
        XCTAssertFalse(AutopilotService.mayStartApproval(rowPending: false, alreadyInFlight: false),
                       "行已经不 pending 就不能再发")
        XCTAssertFalse(AutopilotService.mayStartApproval(rowPending: true, alreadyInFlight: true),
                       "同一条正在发送中 ⇒ 第二次必须被拒")
        XCTAssertFalse(AutopilotService.mayStartApproval(rowPending: false, alreadyInFlight: true))
    }

    /// Wiring, and the only part a unit test cannot reach: the claim has to be
    /// taken in the *same synchronous block* as the read that grants it. One
    /// `await` between them and the two facts can come from two different worlds.
    func testApprovalClaimIsTakenInSameBlockAsThePendingRead() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let block = (source.components(separatedBy: "let savedReply = store.autopilotLogPendingReply(id: logId)")
            .last ?? "").components(separatedBy: "inFlightApprovalLogIds.insert(logId)").first ?? ""
        XCTAssertFalse(block.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertFalse(block.contains("await"),
                       "读到 'pending' 与占位之间只要有一个 await，第二次点击就能挤进来")
        XCTAssertTrue(source.contains("defer { inFlightApprovalLogIds.remove(logId) }"),
                      "释放要挂在 defer 上，失败路径漏释放等于永久锁死这一条")
    }
}
