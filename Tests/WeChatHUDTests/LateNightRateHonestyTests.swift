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

        XCTAssertTrue(result.logEntries.isEmpty,
                      "the surface re-reads the log each scan, so an unwritten row would appear once and vanish")
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

    // MARK: - 确认发送 must not require a queue row it never owned

    /// The batch path's credential is the queue row (a 取消 deletes it, so a
    /// missing row means "stop"). A manual 确认发送's credential is the 'pending'
    /// audit row, and its queue twin can be legitimately absent — an enqueue
    /// whose `upsertPendingSend` hit SQLITE_BUSY still inserts the audit row.
    /// Requiring it there made the card permanently unapprovable.
    func testQueueAxisIsOptionalOnlyForManualApproval() {
        // Queue row absent + audit row pending: approvable for 确认发送, refused for the batch path.
        XCTAssertTrue(
            AutopilotService.mayStillDeliver(
                paused: false, sessionOpen: true, conversationMuted: false,
                queueRowLive: nil, approvalRowPending: true),
            "an audit row with no queue twin used to be unapprovable forever")
        XCTAssertFalse(
            AutopilotService.mayStillDeliver(
                paused: false, sessionOpen: true, conversationMuted: false,
                queueRowLive: false, approvalRowPending: true),
            "for the batch path a deleted queue row IS the cancel")

        // The holds that apply to both axes still hold.
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

    /// The pure helper passing is not enough: `requiresQueueRow` can be ignored
    /// by the actor method and every assertion above still goes green. Drive the
    /// real gate against a real 'pending' audit row that has no queue twin — the
    /// shape an enqueue produces when `upsertPendingSend` hits SQLITE_BUSY.
    func testManualApprovalGateIgnoresTheMissingQueueTwin() async throws {
        try makeService()
        try await service.start()
        var config = AutopilotConfig()
        config.autoSendEnabled = true
        // 转账 goes to a 'pending' audit row and deliberately never enters the queue.
        _ = await service.handleNewMessages([transfer("t-3")], config: config, myUsername: "me")
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let row = try XCTUnwrap(store.loadAutopilotLog(sessionId: sid).first)
        XCTAssertEqual(row.action, .pending)
        let ghostQueueId = UUID()
        XCTAssertFalse(store.hasPendingSend(id: ghostQueueId))

        let approvable = await service.deliveryStillPermitted(
            queueId: ghostQueueId, logId: row.id, chatUsername: nil, requiresQueueRow: false)
        XCTAssertTrue(approvable, "确认发送 was locked out by a queue row it never owned")

        let refused = await service.deliveryStillPermitted(
            queueId: ghostQueueId, logId: row.id, chatUsername: nil)
        XCTAssertFalse(refused, "the batch path's default must stay: there the missing row IS the cancel")
        try? await service.stop()
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
