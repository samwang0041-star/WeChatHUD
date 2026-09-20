import XCTest
@testable import WeChatHUD

/// The late-night guardrail asks one question — 「这个人夜里回不回消息」 — and an
/// unreadable history is not an answer. Before this round `ReplyTimingProfile
/// .lateNightReplyRate` was a plain `Double` that `loadReplyTimingProfile`
/// rebuilt from the `silent_at_night` bit as 0.0 / 1.0, so a transient read
/// failure looked like a measured 0% (holding sends for 24 h and telling the
/// user 「回复率0%」) and a real 0.35 became 1.0 after a restart (silently
/// un-arming the 3 a.m. hold the moment the threshold was raised).
///
/// Each assertion below is written so the OLD loader fails it, and the pairs are
/// deliberate: 0.0 and nil must stay distinguishable in both directions.
final class LateNightRateHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!

    override func setUpWithError() throws {
        tmpPath = NSTemporaryDirectory() + "hud_latenight_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try store.open()
    }

    override func tearDown() { store.close() }

    private func profile(rate: Double?, silent: Bool = true, username: String = "wxid_peer") -> ReplyTimingProfile {
        ReplyTimingProfile(
            chatUsername: username,
            workHours: .zero, evening: .zero, weekend: .zero, lateNight: .zero,
            silentAtNight: silent,
            lateNightReplyRate: rate,
            sampleCount: 12,
            lastUpdated: Date()
        )
    }

    // MARK: - Persistence keeps 「没测到」 apart from 「测到 0」

    func testMeasuredRateSurvivesTheRoundTrip() throws {
        try store.upsertReplyTimingProfile(profile(rate: 0.35))
        let loaded = try XCTUnwrap(store.loadReplyTimingProfile(chatUsername: "wxid_peer"))
        XCTAssertEqual(loaded.lateNightReplyRate ?? -1, 0.35, accuracy: 0.0001)
    }

    func testMeasuredZeroIsNotRewrittenAsUnmeasured() throws {
        try store.upsertReplyTimingProfile(profile(rate: 0.0, silent: true))
        let loaded = try XCTUnwrap(store.loadReplyTimingProfile(chatUsername: "wxid_peer"))
        XCTAssertEqual(loaded.lateNightReplyRate, 0.0,
                       "a measured 0% is the case the guardrail exists for; losing it disarms the hold")
    }

    func testUnmeasuredRateIsNotRewrittenAsZero() throws {
        try store.upsertReplyTimingProfile(profile(rate: nil, silent: false))
        let loaded = try XCTUnwrap(store.loadReplyTimingProfile(chatUsername: "wxid_peer"))
        XCTAssertNil(loaded.lateNightReplyRate,
                     "notSilent used to be read back as a measured 100%, which un-armed the hold")
    }

    /// A row written before the column existed carries the sentinel, not a
    /// measurement. This is the exact shape the old loader answered with 0.0.
    func testLegacyRowLoadsAsUnmeasuredInBothSilentStates() throws {
        for silent in [0, 1] {
            try store.exec("""
                INSERT INTO reply_timing_profiles(chat_username, silent_at_night, sample_count, last_updated)
                VALUES('wxid_legacy', \(silent), 3, 1)
            """)
            let loaded = try XCTUnwrap(store.loadReplyTimingProfile(chatUsername: "wxid_legacy"))
            XCTAssertNil(loaded.lateNightReplyRate, "silent_at_night=\(silent) is not a rate")
            XCTAssertEqual(loaded.silentAtNight, silent == 1)
            XCTAssertEqual(loaded.sampleCount, 3, "the column shift must not re-read the rate as the sample count")
            try store.exec("DELETE FROM reply_timing_profiles WHERE chat_username='wxid_legacy'")
        }
    }

    // MARK: - The hold itself never prints an unmeasured value as a percentage

    func testLateNightHoldTruthTable() {
        let unmeasured = AutopilotService.lateNightHold(rate: nil, threshold: 0.2)
        XCTAssertTrue(unmeasured.holds, "an unmeasured rate must not auto-send at 3 a.m.")
        XCTAssertFalse(unmeasured.reason.contains("%"),
                       "「\(unmeasured.reason)」 would show a percentage that was never measured")
        XCTAssertTrue(unmeasured.reason.contains("读不到") || unmeasured.reason.contains("没有测量值"))

        let silent = AutopilotService.lateNightHold(rate: 0.0, threshold: 0.2)
        XCTAssertTrue(silent.holds)
        XCTAssertTrue(silent.reason.contains("0%"))

        let talkative = AutopilotService.lateNightHold(rate: 0.35, threshold: 0.2)
        XCTAssertFalse(talkative.holds)

        // Positive control for the comparison direction: at the threshold it sends.
        XCTAssertFalse(AutopilotService.lateNightHold(rate: 0.2, threshold: 0.2).holds)
    }

    /// `unmeasuredTimingProfile` is what the caller gets when the history read
    /// throws. It must not smuggle a fabricated rate back in through the default.
    func testUnmeasuredProfileCarriesNoRate() {
        let p = StyleProfiler.unmeasuredTimingProfile(chatUsername: "wxid_peer")
        XCTAssertNil(p.lateNightReplyRate)
        XCTAssertEqual(p.sampleCount, 0)
    }

    // MARK: - A write that did not land must not raise the 待确认 badge

    private var reader: WeChatReader!
    private var service: AutopilotService!

    private func makeService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    private func transfer(_ uid: String) -> AutopilotService.InboundMessage {
        AutopilotService.InboundMessage(
            msgUID: uid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            text: "[转账]", isGroup: false, isAtMention: false,
            attentionLevel: .whitelist, contactRole: .colleague,
            timestamp: Int(Date().timeIntervalSince1970), messageType: 49, appType: 2000
        )
    }

    /// `sessionPending` is only ever decremented by resolving a row, and
    /// `persistSessionCounts` writes it for `start()` to read back — so the
    /// +1 a failed insert used to raise became a badge no user could clear.
    func testFailedAuditWriteDoesNotRaiseThePendingCount() async throws {
        try makeService()
        try await service.start()
        try store.exec("""
            CREATE TRIGGER audit_write_denied BEFORE INSERT ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)
        var config = AutopilotConfig()
        config.autoSendEnabled = true
        let result = await service.handleNewMessages([transfer("t-1")], config: config, myUsername: "me")

        // Shown once, never counted: 转账/红包 is the one class where a failed
        // write must not silently swallow the alert.
        XCTAssertEqual(result.logEntries.count, 1)
        XCTAssertEqual(result.logEntries.first?.action, .pending)
        XCTAssertEqual(result.totalPending, 0)
        XCTAssertEqual(store.currentAutopilotSession()?.totalPending ?? 0, 0,
                       "the phantom +1 was persisted and restored across restarts")
        XCTAssertEqual(result.ackedMsgUIDs, ["t-1"],
                       "still acked: re-feeding a message whose audit cannot be written spends another AI call every scan")
        let queue = await service.pendingSendQueue
        XCTAssertTrue(queue.isEmpty)
        try? await service.stop()
    }

    /// Positive control — the same test with a working database must raise the
    /// count, or the assertion above passes for the wrong reason.
    func testSuccessfulAuditWriteDoesRaiseThePendingCount() async throws {
        try makeService()
        try await service.start()
        var config = AutopilotConfig()
        config.autoSendEnabled = true
        let result = await service.handleNewMessages([transfer("t-2")], config: config, myUsername: "me")
        XCTAssertEqual(result.logEntries.count, 1)
        XCTAssertEqual(result.totalPending, 1)
        XCTAssertEqual(store.currentAutopilotSession()?.totalPending, 1)
        try? await service.stop()
    }

    /// The batch path's credential is the queue row (a 取消 deletes it, so a
    /// missing row means "stop"). A manual 确认发送's credential is the 'pending'
    /// audit row, and its queue twin can be legitimately absent — an enqueue
    /// whose `upsertPendingSend` hit SQLITE_BUSY still inserts the audit row.
    /// Requiring it there made the card permanently unapprovable.
    /// 「queue_id present but the row is gone」 is the durable shape of a cancel,
    /// and 「queue_id NULL」 is the shape of a reply that never had a twin. They
    /// have to read differently: collapsing them is what made a card either
    /// permanently unapprovable or sendable-after-cancel, depending on which way
    /// the gate was bent.
    func testQueueAxisReadsGoneTwinAndNoTwinDifferently() {
        XCTAssertFalse(
            AutopilotService.mayStillDeliver(
                paused: false, sessionOpen: true, conversationMuted: false,
                queueRowLive: false, approvalRowPending: true),
            "a deleted twin IS the user's 取消 — the keystrokes must stop")
        XCTAssertTrue(
            AutopilotService.mayStillDeliver(
                paused: false, sessionOpen: true, conversationMuted: false,
                queueRowLive: nil, approvalRowPending: true),
            "no twin claim at all must not lock the card")
        // The holds that are not about the row's state at all.
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: true, sessionOpen: true, queueRowLive: nil, approvalRowPending: true))
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, conversationMuted: true,
            queueRowLive: nil, approvalRowPending: true))
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: nil, approvalRowPending: true,
            alreadySentHere: true),
            "a keystroke that may have landed must never be re-delivered")
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: nil, approvalRowPending: true,
            queueHeldHere: true))
        XCTAssertFalse(AutopilotService.mayStillDeliver(
            paused: false, sessionOpen: true, queueRowLive: nil, approvalRowPending: false))
    }

    /// The user-visible half: a 取消 whose audit-row write failed must not leave a
    /// row that a later 确认发送 can send. Flipping the audit row first is what
    /// makes 「still pending」 mean 「the cancel never happened」, so the queue row
    /// is kept beside it instead of being deleted on its own.
    func testCancelThatCannotFlipTheAuditRowKeepsTheQueueRow() async throws {
        try makeService()
        try await service.start()
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我稍后回你", confidence: 0.9, risk: .low, reasoning: "test",
            styleScore: 60, scheduledSendTime: Date().addingTimeInterval(60),
            createdAt: Date()
        )
        await service.testingEnqueue(item)
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        try store.upsertPendingSend(item, sessionId: sid)
        let entry = AutopilotLogEntry(
            id: 0, sessionId: store.currentAutopilotSession()?.id ?? 0,
            chatUsername: "wxid_peer", chatName: "同事", senderUsername: "", senderName: "同事",
            triggerMsgUID: "m-1", triggerText: "在吗", generatedReply: "我稍后回你",
            confidence: 0.9, riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: item.id.uuidString
        )
        try store.insertAutopilotLog(entry)
        XCTAssertTrue(store.hasPendingSend(id: item.id))
        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)

        _ = await service.cancelPendingSend(id: item.id)

        XCTAssertTrue(store.hasPendingSend(id: item.id),
                      "the durable cancel is the audit row; deleting the queue twin alone leaves a sendable shape with no owner")
        let row = try XCTUnwrap(store.loadAutopilotLog(sessionId: sid).first)
        XCTAssertEqual(row.action, .pending, "the trigger proved the flip did not land")
        let inSessionPermitted = await service.deliveryStillPermitted(
            queueId: item.id, logId: row.id, chatUsername: nil)
        XCTAssertFalse(inSessionPermitted,
                       "in-session the memory hold still refuses")
        try? await service.stop()
    }

    /// A cancel that fully lands must still refuse after a process restart, where
    /// every in-memory hold is gone. This is the shape the previous round's
    /// `requiresQueueRow: false` let through.
    func testLandedCancelStillRefusesAfterRestart() async throws {
        try makeService()
        try await service.start()
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我稍后回你", confidence: 0.9, risk: .low, reasoning: "test",
            styleScore: 60, scheduledSendTime: Date().addingTimeInterval(60),
            createdAt: Date()
        )
        await service.testingEnqueue(item)
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        try store.upsertPendingSend(item, sessionId: sid)
        let entry = AutopilotLogEntry(
            id: 0, sessionId: store.currentAutopilotSession()?.id ?? 0,
            chatUsername: "wxid_peer", chatName: "同事", senderUsername: "", senderName: "同事",
            triggerMsgUID: "m-2", triggerText: "在吗", generatedReply: "我稍后回你",
            confidence: 0.9, riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: item.id.uuidString
        )
        try store.insertAutopilotLog(entry)
        let rowId = try XCTUnwrap(store.loadAutopilotLog(sessionId: sid).first { $0.action == .pending }).id
        _ = await service.cancelPendingSend(id: item.id)
        try? await service.stop()

        XCTAssertFalse(store.hasPendingSend(id: item.id), "the delete landed")
        XCTAssertNotNil(store.loadAutopilotLog(sessionId: sid).first { $0.id == rowId && $0.action == .skipped })

        let revived = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await revived.start()
        let rehydratedRow = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: sid).first { $0.id == rowId })
        // The flip landed, so the approval axis alone refuses it; the queue axis
        // agrees. Both have to hold, because a stale `queue_id` on a row that is
        // no longer there is the only thing distinguishing this from a reply
        // that never had a twin.
        let afterRestart = await revived.deliveryStillPermitted(
            queueId: item.id, logId: rehydratedRow.id, chatUsername: "wxid_peer")
        XCTAssertFalse(afterRestart,
                       "a landed cancel must stay refused once the in-memory holds are gone")
        try? await revived.stop()
    }

    /// The fail-closed side of the same axis, written straight into the database
    /// so it does not depend on which code path produced it: a 'pending' audit
    /// row that claims a queue twin which is gone is refused. Relaxing the gate
    /// for manual approval (the previous round's `requiresQueueRow: false`) let
    /// this row through, and that is the shape an old-code cancel left behind —
    /// hence the enqueue now refuses to make a twin claim it cannot honour.
    func testAPendingRowClaimingAGoneTwinIsRefused() async throws {
        try makeService()
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let goneTwin = UUID()
        let entry = AutopilotLogEntry(
            id: 0, sessionId: sid,
            chatUsername: "wxid_peer", chatName: "同事", senderUsername: "", senderName: "同事",
            triggerMsgUID: "m-3", triggerText: "在吗", generatedReply: "我看看",
            confidence: 0.9, riskLevel: .low, action: .pending,
            aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: goneTwin.uuidString
        )
        try store.insertAutopilotLog(entry)
        let rowId = try XCTUnwrap(store.loadAutopilotLog(sessionId: sid).first).id
        XCTAssertFalse(store.hasPendingSend(id: goneTwin))
        try? await service.stop()

        let revived = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await revived.start()
        let permitted = await revived.deliveryStillPermitted(
            queueId: goneTwin, logId: rowId, chatUsername: "wxid_peer")
        XCTAssertFalse(permitted,
                       "a twin that is gone is the only durable trace of the user's 取消")
        try? await revived.stop()
    }

    /// The producer half. `processBatch` owns both facts — whether the queue twin
    /// write landed, and whether the audit row claims that twin — and a `try?`
    /// between them is what made the claim false. The consumer side above is
    /// behaviour-tested; this pins the one line that decides the shape.
    func testTheTwinClaimIsDerivedFromTheWriteThatLanded() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        guard let start = src.range(of: "let twinLanded: Bool"),
              let end = src.range(of: "private func searchNames",
                                  range: start.upperBound..<src.endIndex) else {
            XCTFail("the enqueue block moved — this guard would be reading nothing")
            return
        }
        let region = String(src[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(region.isEmpty, "empty slice means the anchors are wrong")
        XCTAssertTrue(region.contains("twinLanded = (try? store.upsertPendingSend"),
                      "the twin write has to be what decides `twinLanded`")
        XCTAssertTrue(region.contains("queueId: twinLanded ? pendingItem.id.uuidString : nil"),
                      "queue_id may only be claimed when the twin landed: \(region.prefix(200))")
    }
}

/// `ClipboardGuard.restore` can only clear the pasteboard when it knows what was
/// pasted: it compares the current contents against the pasted string and skips
/// the `clearContents()` when the user has typed over it. `pastedText` defaults
/// to nil, and the round-3 fix was applied at one of three sites — a restore
/// with no `pastedText` silently reverts to the leaking branch.
final class ClipboardRestoreWiringTests: XCTestCase {
    private func sources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let fm = FileManager.default
        var out: [(String, String)] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("cannot enumerate \(root.path)")
            return []
        }
        for case let url as URL in en where url.pathExtension == "swift" {
            out.append((url.path, (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return out
    }

    func testEveryRestoreNamesWhatItPasted() throws {
        var found = 0
        var offenders: [String] = []
        for (path, text) in try sources() {
            for line in text.components(separatedBy: "\n") where line.contains("ClipboardGuard.restore(") {
                found += 1
                if !line.contains("pastedText:") {
                    offenders.append((path as NSString).lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        // Coverage floor: a gate that scanned nothing looks exactly like a gate
        // that found nothing.
        XCTAssertGreaterThanOrEqual(found, 3, "expected the known restore sites, found \(found) — did the call pattern change?")
        XCTAssertTrue(offenders.isEmpty, "restore without pastedText re-enables the leak: \(offenders)")
    }
}
