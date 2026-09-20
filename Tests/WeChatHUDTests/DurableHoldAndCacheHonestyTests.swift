import AppKit
import XCTest
@testable import WeChatHUD

/// Round 5: the holds that outlive the process, the caches that outlive the
/// clock, and the paste string the call site cannot name.
final class DurableHoldAndCacheHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUpWithError() throws {
        tmpPath = NSTemporaryDirectory() + "hud_durable_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    private func held(_ reason: String?) -> PendingSend {
        PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1),
            createdAt: Date(), manualOnlyReason: reason
        )
    }

    // MARK: - 立即发送 must not bypass a hold that says 「上一次的结果没人知道」

    /// `holdRowAcrossRestart` writes these two strings onto the queue row
    /// specifically so the fact survives a restart — but only the *automatic*
    /// path read it. 「立即发送」 is the button the approval workspace shows for
    /// exactly these rows, so the persisted warning was overwritten by a second
    /// delivery of text the peer may already have.
    func testSendNowRefusesBothDurableHolds() async throws {
        try await service.start()
        for (reason, fragment) in [
            (AutopilotService.unverifiedDeliveryHoldText, "很可能已经发出"),
            (AutopilotService.cancelNotLandedHoldText, "你已经取消了"),
        ] {
            let item = held(reason)
            await service.testingEnqueue(item)
            let outcome = await service.sendNow(id: item.id, config: AutopilotConfig())
            guard case .blocked(let message) = outcome else {
                return XCTFail("「\(reason.prefix(12))…」 must block 立即发送, got \(outcome)")
            }
            XCTAssertTrue(message.contains(fragment), message)
            let stillQueued = await service.pendingSendQueue
            XCTAssertTrue(stillQueued.contains { $0.id == item.id },
                          "refusing must not consume the row — the user still has to be able to see it")
        }
    }

    /// Positive control: an ordinary manual-only hold (敏感词、群聊、置信度不足) is
    /// a human's call, so 立即发送 still runs it. Without this the assertion above
    /// would pass by blocking everything.
    func testSendNowStillRunsAnOrdinaryManualHold() async throws {
        try await service.start()
        let item = held("包含敏感词，转人工")
        await service.testingEnqueue(item)
        let outcome = await service.sendNow(id: item.id, config: AutopilotConfig())
        if case .blocked(let message) = outcome {
            XCTAssertFalse(message.contains("很可能已经发出"), "wrong hold classified: \(message)")
            XCTAssertFalse(message.contains("你已经取消了"), "wrong hold classified: \(message)")
        }
        let stillQueued = await service.pendingSendQueue
        XCTAssertFalse(stillQueued.contains { $0.id == item.id },
                       "an ordinary hold must be consumable by 立即发送")
    }

    // MARK: - Cache age is only trusted in one direction

    func testBackwardsClockStepExpiresRatherThanFreezes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(StyleProfiler.isFresh(refreshedAt: now.addingTimeInterval(-60),
                                            window: 1800, now: now))
        XCTAssertFalse(StyleProfiler.isFresh(refreshedAt: now.addingTimeInterval(-7200),
                                             window: 1800, now: now))
        // A wall clock that stepped backwards puts every stamp "in the future".
        XCTAssertFalse(StyleProfiler.isFresh(refreshedAt: now.addingTimeInterval(3600),
                                             window: 1800, now: now),
                       "a negative age used to satisfy `< window` forever, freezing the profile that gates the 3 a.m. hold")
    }

    func testProfileCacheIsBoundedByAgeThenByCount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cache: [String: (profile: Int, refreshedAt: Date)] = [:]
        for i in 0..<200 {
            cache["k\(i)"] = (i, now.addingTimeInterval(TimeInterval(-i)))
        }
        cache["stale"] = (999, now.addingTimeInterval(-100_000))
        cache["future"] = (998, now.addingTimeInterval(+100_000))

        let pruned = StyleProfiler.pruning(cache, ttl: 1800, cap: 64, now: now)
        XCTAssertEqual(pruned.count, 64, "the exclusion-set key changes on every send, so an unbounded cache is a leak on a 24/7 process")
        XCTAssertNil(pruned["stale"])
        XCTAssertNil(pruned["future"], "「from the future」 is not fresh")
        XCTAssertNotNil(pruned["k0"], "the newest entries are the ones worth keeping")
        XCTAssertNil(pruned["k199"])
        // Coverage floor: a bound that pruned everything would also pass.
        XCTAssertGreaterThan(pruned.count, 0)
    }

    /// The key that grows: two calls that differ only by an excluded message uid
    /// must not be able to defeat the cap.
    func testCacheKeysDerivedFromExclusionSetsShareTheBound() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cache: [String: (profile: Int, refreshedAt: Date)] = [:]
        for i in 0..<500 { cache["chat#excl\(i)"] = (i, now) }
        XCTAssertEqual(StyleProfiler.pruning(cache, ttl: 1800, cap: 64, now: now).count, 64)
    }

    // MARK: - An unobserved night is not a measured 0%

    func testHistoryWithNoLateNightTrafficYieldsNoMeasurement() async throws {
        // `reader` points at an empty directory: nothing can be read, and the
        // old code answered that with a fabricated rate.
        let profiler = StyleProfiler(reader: reader, store: store)
        let profile = await profiler.getTimingProfile(chatUsername: "wxid_peer")
        XCTAssertNil(profile.lateNightReplyRate,
                     "0.0 here means 「never replies at night」 and locks the guardrail for 24 h")
        let stored = store.loadReplyTimingProfile(chatUsername: "wxid_peer")
        XCTAssertNil(stored?.lateNightReplyRate,
                     "a failed read must not be persisted as a measurement")
    }

    /// The pure bound passing is not the same as the bound being wired: dropping
    /// the `pruneProfileCache()` call from the write path left every assertion
    /// above green. Drive the real entry point and read the real dictionary.
    func testTheWritePathActuallyPrunes() async throws {
        let profiler = StyleProfiler(reader: reader, store: store)
        for i in 0..<(StyleProfiler.profileCacheCap + 40) {
            _ = await profiler.getProfile(chatUsername: "wxid_peer",
                                          excludeMsgUIDs: Set(["uid-\(i)"]))
        }
        let count = await profiler.testingProfileCacheCount()
        XCTAssertLessThanOrEqual(count, StyleProfiler.profileCacheCap,
                                 "the cache grew one entry per call: \(count)")
        XCTAssertGreaterThan(count, 0, "a cache pruned empty would also satisfy the bound")
    }
}

/// `navigateToChat` pastes each candidate search name in turn, so by the time
/// `restore` runs the string on the board is not necessarily one the caller can
/// name. A comparison against the wrong value skipped `clearContents()` and left
/// the contact's nickname on the general pasteboard.
final class ClipboardRecordedWriteTests: XCTestCase {
    /// The bodies run on the main actor (AppKit pasteboard) and report what the
    /// board held afterwards, so the assertions stay in the test itself. A
    /// `@MainActor` XCTestCase class is not collected at all — it reported
    /// "0 tests, 0 failures", which is what a passing suite looks like.
    @MainActor private func pasteThenRestore(naming pasted: String, callerNames: String,
                                             replacedBy: String?) -> String? {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.wechathud.qa.\(UUID().uuidString)"))
        pb.clearContents()
        let state = ClipboardGuard.SavedState(items: nil, changeCount: pb.changeCount - 1, hadContent: true)
        ClipboardGuard.noteWritten(pasted, on: pb)
        if let replacedBy {
            pb.clearContents()
            pb.setString(replacedBy, forType: .string)
        }
        ClipboardGuard.restore(state, pastedText: callerNames, on: pb)
        return pb.string(forType: .string)
    }

    func testRestoreClearsWhatTheGuardActuallyWrote() async {
        let left = await pasteThenRestore(naming: "张三", callerNames: "同事", replacedBy: nil)
        XCTAssertNil(left, "the name we pasted has to be erased even when the call site cannot name it")
    }

    func testRestoreLeavesSomeoneElsesContentAlone() async {
        let left = await pasteThenRestore(naming: "张三", callerNames: "同事",
                                          replacedBy: "用户自己刚复制的东西")
        XCTAssertEqual(left, "用户自己刚复制的东西", "content copied since then is not ours to destroy")
    }

    /// Positive control for the previous round's parameter: when the call site
    /// does name the string, that path still works on its own.
    func testCallerNamedTextStillClears() async {
        let left = await pasteThenRestore(naming: "张三", callerNames: "张三", replacedBy: nil)
        XCTAssertNil(left)
    }
}

/// Round 5's two P0s: the durable traces a withdrawal leaves behind were written
/// by one commit and read by nobody.
final class WithdrawalDurabilityTests: XCTestCase {
    private var store: HUDStore!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUpWithError() throws {
        let tmp = NSTemporaryDirectory() + "hud_withdrawal_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
    }

    private func twin(_ sid: Int64, reason: String?) throws -> PendingSend {
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "收到-\(UUID().uuidString.prefix(4))", confidence: 0.9, risk: .low,
            reasoning: "ok", styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(-1), manualOnlyReason: reason
        )
        try store.upsertPendingSend(item, sessionId: sid)
        return item
    }

    private func pendingLogRow(_ sid: Int64, for item: PendingSend) throws -> Int64 {
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-\(item.id)",
            triggerText: "在吗", generatedReply: item.replyText, confidence: 0.9,
            riskLevel: .low, action: .pending, aiReasoning: nil, sentAt: nil,
            createdAt: Date(), queueId: item.id.uuidString
        ))
        let rows = store.loadAutopilotLog(sessionId: sid).filter { $0.triggerMsgUID == "m-\(item.id)" }
        return try XCTUnwrap(rows.first?.id, "no log row written for \(item.id)")
    }

    /// `executeSend` re-inserts the queue row just before it types (its upsert is
    /// `ON CONFLICT DO UPDATE`, which re-creates a deleted row), so mid-send a
    /// 取消 leaves the queue axis reading 「live」 again — and the approval gate is
    /// called with `logId: nil` there, so nothing else was left to refuse.
    func testAResurrectedQueueRowStillReadsAsWithdrawn() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let item = try twin(sid, reason: nil)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-9", triggerText: "在吗",
            generatedReply: item.replyText, confidence: 0.9, riskLevel: .low,
            action: .skipped, aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: item.id.uuidString
        ))
        XCTAssertTrue(store.hasPendingSend(id: item.id))
        XCTAssertTrue(store.autopilotLogWithdrawnForQueue(queueId: item.id))
        let permitted = await service.deliveryStillPermitted(
            queueId: item.id, logId: nil, chatUsername: nil)
        XCTAssertFalse(permitted, "the row was re-created by the send path itself; the cancel has to win")
    }

    /// After a restart the in-memory holds are gone, and 确认发送 is exactly what
    /// a user reaches for when the card reappears. Ordinary manual-only reasons
    /// (敏感词 / 群聊 / 置信度) must stay approvable, or this becomes a new lockout.
    func testDurableHoldOnTheQueueRowRefusesApproval() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        for (reason, refuses) in [
            (AutopilotService.unverifiedDeliveryHoldText, true),
            (AutopilotService.cancelNotLandedHoldText, true),
            ("包含敏感词，转人工", false),
            (nil, false),
        ] {
            let item = try twin(sid, reason: reason)
            let rowId = try pendingLogRow(sid, for: item)
            let revived = AutopilotService(store: store, reader: reader, aiService: AIService())
            try await revived.start()
            let permitted = await revived.deliveryStillPermitted(
                queueId: item.id, logId: rowId, chatUsername: "wxid_peer",
                requiresQueueRow: false)
            XCTAssertEqual(permitted, !refuses,
                           "a row whose manual-only reason is a durable send-unknown hold must not send")
            try? await revived.stop()
        }
    }

    /// 「夜里没有往来」 is a completed measurement. Trusting the cached row only
    /// when the rate is non-nil re-read 500 messages per batch for most of the
    /// whitelist — the honesty fix must not have become a hot-path fix.
    func testACompletedMeasurementWithNoLateNightTrafficIsNotReMeasured() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unreadable = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        try store.upsertReplyTimingProfile(ReplyTimingProfile(
            chatUsername: "wxid_quiet", workHours: .zero, evening: .zero, weekend: .zero,
            lateNight: .zero, silentAtNight: true, lateNightReplyRate: nil,
            sampleCount: 40, lastUpdated: Date()
        ))
        let got = await StyleProfiler(reader: unreadable, store: store)
            .getTimingProfile(chatUsername: "wxid_quiet")
        XCTAssertEqual(got.sampleCount, 40,
                       "the stored measurement was ignored and the history re-read")
        XCTAssertNil(got.lateNightReplyRate, "still no fabricated rate for a quiet night")
    }
}

/// A refusal that tells the user to press something which does not exist is
/// worse than no refusal: it is the one instruction they cannot follow. This
/// copy once named 「编辑并发送」, whose service function has zero callers in
/// `Views`. Rather than trust review, name the controls the copy depends on and
/// require each of them to be a real label on screen.
final class ReferralCopyPointsAtRealControlsTests: XCTestCase {
    private func viewLabels() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("cannot enumerate \(root.path)"); return ""
        }
        var text = ""
        for case let url as URL in en where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        XCTAssertGreaterThan(text.count, 20_000, "the Views tree scanned nothing")
        return text
    }

    func testEveryControlNamedByTheCopyExistsOnScreen() throws {
        let labels = try viewLabels()
        var checked = 0
        for control in ["确认发送", "取消本条", "暂停"] {
            XCTAssertTrue(labels.contains(control),
                          "回执文案让用户去按「\(control)」，但 Views 里没有这个名字")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "coverage floor: a scan that checked nothing passes")
        XCTAssertFalse(labels.isEmpty)
    }

    /// And the copy must stop naming the one that does not exist.
    func testThePhantomControlNameIsNotRevived() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift"), encoding: .utf8)
        // Only copy a user can read. A comment may name the missing button —
        // several of them exist precisely to warn the next reader about it.
        let code = src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.starts(with: "//") && !$0.starts(with: "*") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("编辑并发送"),
                       "editAndSend has no button; user copy may not point at it")
        XCTAssertFalse(code.contains("用「编辑并发送」"))
        XCTAssertFalse(code.isEmpty, "the scan stripped everything — it is asserting nothing")
    }
}

/// Round 6: the durable cancel marker was skipped for exactly the rows that
/// needed it, and one of the four send doors never read it at all.
final class DurableHoldCoverageTests: XCTestCase {
    private var store: HUDStore!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUpWithError() throws {
        let tmp = NSTemporaryDirectory() + "hud_holdcov_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
    }

    /// A row that already awaits a human is the row the card offers 「立即发送」
    /// for. When the cancel's audit flip fails on such a row, the old
    /// `manualOnlyReason == nil` guard meant the cancel marker was never written
    /// — so the durable record still said only 「不能自动发」, and after a restart
    /// the same text went out to a real person.
    func testCancelUpgradesAnOrdinaryHoldToTheDurableCancelMarker() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1),
            manualOnlyReason: "已达到本次会话发送上限，转人工确认"
        )
        await service.testingEnqueue(item)
        try store.upsertPendingSend(item, sessionId: sid)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-hold",
            triggerText: "在吗", generatedReply: item.replyText, confidence: 0.9,
            riskLevel: .low, action: .pending, aiReasoning: nil, sentAt: nil,
            createdAt: Date(), queueId: item.id.uuidString
        ))
        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)
        await service.cancelPendingSend(id: item.id)

        let stored = try XCTUnwrap(store.loadPendingSends(sessionId: sid).first { $0.id == item.id })
        XCTAssertEqual(stored.manualOnlyReason, AutopilotService.cancelNotLandedHoldText,
                       "撤回没能落库时，耐久标记必须盖过那个更弱的原因")
        let revived = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await revived.start()
        let rowId = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: sid).first { $0.triggerMsgUID == "m-hold" }?.id)
        let permitted = await revived.deliveryStillPermitted(
            queueId: item.id, logId: rowId, chatUsername: "wxid_peer", requiresQueueRow: false)
        XCTAssertFalse(permitted, "重启后「立即发送/确认发送」都不该把用户撤回的话发出去")
        try? await revived.stop()
    }

    /// One predicate, four doors: 编辑并发送 is a send too, and an edited text
    /// does not make an unknown previous outcome known.
    func testEditAndSendRefusesTheDurableHolds() async throws {
        try await service.start()
        for reason in [AutopilotService.unverifiedDeliveryHoldText,
                       AutopilotService.cancelNotLandedHoldText] {
            let item = PendingSend(
                id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
                replyText: "原来那句", confidence: 0.9, risk: .low, reasoning: "ok",
                styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1),
                manualOnlyReason: reason
            )
            await service.testingEnqueue(item)
            let outcome = await service.editAndSend(id: item.id, newText: "改后的那句",
                                                    config: AutopilotConfig())
            guard case .blocked(let message) = outcome else {
                return XCTFail("编辑并发送 must refuse a row whose last outcome is unknown")
            }
            XCTAssertTrue(message.contains("核对"), message)
            let queue = await service.pendingSendQueue
            XCTAssertTrue(queue.contains { $0.id == item.id }, "refusing must not consume the row")
            XCTAssertTrue(queue.first { $0.id == item.id }?.replyText == "原来那句",
                          "a refusal must not leave the edited text queued in place of the original")
        }
        // Positive control: an ordinary manual-only row is the human's to rewrite.
        let ordinary = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "原来那句", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1),
            manualOnlyReason: "命中敏感词，转人工"
        )
        await service.testingEnqueue(ordinary)
        let outcome = await service.editAndSend(id: ordinary.id, newText: "改掉敏感词之后的那句",
                                                config: AutopilotConfig())
        if case .blocked(let message) = outcome {
            XCTAssertFalse(message.contains("没能确认"), "wrong hold classified: \(message)")
        }
    }
}

/// 「已取消」 is a claim about the durable record, not about the button press.
final class CancelReceiptHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUpWithError() throws {
        let tmp = NSTemporaryDirectory() + "hud_cancelreceipt_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
    }

    private func queued(_ sid: Int64) async throws -> PendingSend {
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1)
        )
        await service.testingEnqueue(item)
        try store.upsertPendingSend(item, sessionId: sid)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-\(item.id)",
            triggerText: "在吗", generatedReply: item.replyText, confidence: 0.9,
            riskLevel: .low, action: .pending, aiReasoning: nil, sentAt: nil,
            createdAt: Date(), queueId: item.id.uuidString
        ))
        return item
    }

    func testCancelOutcomeFollowsTheWrites() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)

        // Nothing queued at all is a withdrawal, not a failure to withdraw.
        let absent = await service.cancelPendingSend(id: UUID())
        XCTAssertEqual(absent, .withdrawn)

        let clean = try await queued(sid)
        let cleanOutcome = await service.cancelPendingSend(id: clean.id)
        XCTAssertEqual(cleanOutcome, .withdrawn)
        XCTAssertFalse(store.hasPendingSend(id: clean.id))

        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)
        let stuck = try await queued(sid)
        let outcome = await service.cancelPendingSend(id: stuck.id)
        guard case .held(let reason) = outcome else {
            return XCTFail("取消没落库时不能回报 .withdrawn，界面会打印「已取消」")
        }
        XCTAssertTrue(store.hasPendingSend(id: stuck.id))
        XCTAssertTrue(reason.contains("仍然待发"), reason)
        try? await service.stop()
    }

    /// The two View halves cannot be unit-tested without a window, so pin the
    /// wiring with a floor that fails if either guard is deleted.
    func testViewsStillCarryTheTwoWiringGuards() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let workspace = try String(contentsOf: root
            .appendingPathComponent("Views/ApprovalWorkspaceView.swift"), encoding: .utf8)
        let change = workspace.range(of: "onChange(of: selected?.id)")
        let window = try XCTUnwrap(change?.lowerBound)
        let after = workspace[window...].prefix(600)
        XCTAssertTrue(after.contains("receipt = nil"),
                      "换一条队列项时旧回执必须消失：A 的成功回执挂在 B 下面是确定地报错")
        XCTAssertTrue(workspace.contains("case .held(let reason)"),
                      "取消的回执必须读 cancelPendingSend 的结果")
        XCTAssertFalse(workspace.contains("receipt = .done(\"已取消即将发送的回复\")\n    }"),
                       "无条件打印「已取消」的写法回来了")

        let settings = try String(contentsOf: root
            .appendingPathComponent("Views/Settings/AutopilotSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains(".disabled(loadError != nil)"),
                      "读不到配置时这张页仍是可交互表单：滑块会动、保存被静默挡住")
    }
}

/// The other door: the 待确认 card's own 「取消本条」 goes through
/// `rejectPending(logId:)`, not `cancelPendingSend(id:)`.
final class RejectDoorDurabilityTests: XCTestCase {
    private var store: HUDStore!
    private var reader: WeChatReader!
    private var service: AutopilotService!

    override func setUpWithError() throws {
        let tmp = NSTemporaryDirectory() + "hud_reject_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
        service = AutopilotService(store: store, reader: reader, aiService: AIService())
    }

    override func tearDown() async throws {
        try? await service.stop()
        store.close()
    }

    private func staged() async throws -> (PendingSend, Int64, Int64) {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1)
        )
        await service.testingEnqueue(item)
        try store.upsertPendingSend(item, sessionId: sid)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-rej", triggerText: "在吗",
            generatedReply: item.replyText, confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: item.id.uuidString
        ))
        let logId = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: sid).first { $0.triggerMsgUID == "m-rej" }?.id)
        return (item, logId, sid)
    }

    /// A reject whose audit flip failed used to delete the queue twin anyway,
    /// producing 「审计行 pending + 孪生没了」 — after a restart that is
    /// indistinguishable from a reply nobody withdrew.
    func testRejectWithFailedFlipHoldsTheTwinInsteadOfDeletingIt() async throws {
        let (item, logId, sid) = try await staged()
        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)
        let outcome = await service.rejectPending(
            logId: logId, chatUsername: "wxid_peer", replyText: item.replyText)
        guard case .held = outcome else {
            return XCTFail("翻转写失败时不能回报 .withdrawn —— 界面正读这个值")
        }
        XCTAssertTrue(store.hasPendingSend(id: item.id), "孪生行必须留着当耐久载体")
        let held = try XCTUnwrap(store.loadPendingSends(sessionId: sid).first { $0.id == item.id })
        XCTAssertEqual(held.manualOnlyReason, AutopilotService.cancelNotLandedHoldText)
        // The reject door used to take the row out of the memory mirror and
        // leave it only on disk, so the page said 「gone」 until the next launch
        // said 「held, awaiting a human」 — and `sendNow` read the mirror, which
        // had nothing to refuse with.
        let mirror = await service.pendingSendQueue
        let mirrored = try XCTUnwrap(mirror.first { $0.id == item.id })
        XCTAssertEqual(mirrored.manualOnlyReason, AutopilotService.cancelNotLandedHoldText,
                       "reject 这一扇门放回的行也得带耐久标记")

        let revived = AutopilotService(store: store, reader: reader, aiService: AIService())
        try await revived.start()
        let permitted = await revived.deliveryStillPermitted(
            queueId: item.id, logId: logId, chatUsername: "wxid_peer", requiresQueueRow: false)
        XCTAssertFalse(permitted, "重启后确认发送仍必须拒绝这条被撤回过的回复")
        try? await revived.stop()
    }

    /// 「请再按一次取消」 has to point at a card that is still on screen: the list
    /// mirrors `pendingSendQueue`, so dropping the in-memory copy along with a
    /// failed delete erased the very button the sentence names.
    func testACancelThatDidNotLandKeepsItsCardVisible() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        let item = PendingSend(
            id: UUID(), chatUsername: "wxid_peer", chatName: "同事", senderName: "同事",
            replyText: "我下午给你结论", confidence: 0.9, risk: .low, reasoning: "ok",
            styleScore: 80, scheduledSendTime: Date().addingTimeInterval(-1)
        )
        await service.testingEnqueue(item)
        try store.upsertPendingSend(item, sessionId: sid)
        // A cancel with no audit twin has nothing to flip, so it legitimately
        // lands — the trigger below needs a row to abort on.
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-card", triggerText: "在吗",
            generatedReply: item.replyText, confidence: 0.9, riskLevel: .low,
            action: .pending, aiReasoning: nil, sentAt: nil, createdAt: Date(),
            queueId: item.id.uuidString
        ))
        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)
        let outcome = await service.cancelPendingSend(id: item.id)
        guard case .held(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("再按一次取消"), reason)
        let queue = await service.pendingSendQueue
        XCTAssertTrue(queue.contains { $0.id == item.id },
                      "提示让用户再按一次，就不能先把那颗按钮拿掉")
        // Visibility alone was not enough: the copy put back was the pre-cancel
        // snapshot, so the row the queue page and 「立即发送」 actually read carried
        // no hold, and the next upsert wrote the disk marker back to its old
        // value — the durable hold survived a restart only if nobody touched it.
        let mirrored = try XCTUnwrap(queue.first { $0.id == item.id })
        XCTAssertEqual(mirrored.manualOnlyReason, AutopilotService.cancelNotLandedHoldText,
                       "放回内存镜像的必须是带耐久标记的那一份，sendNow 读的就是这里")
        let sendOutcome = await service.sendNow(id: item.id, config: AutopilotConfig())
        guard case .blocked(let why) = sendOutcome else {
            return XCTFail("内存副本不带标记时「立即发送」会放行: \(sendOutcome)")
        }
        XCTAssertTrue(why.contains("撤回") || why.contains("核对"), why)
        let afterBlockedSend = try XCTUnwrap(
            store.loadPendingSends(sessionId: sid).first { $0.id == item.id })
        XCTAssertEqual(afterBlockedSend.manualOnlyReason, AutopilotService.cancelNotLandedHoldText,
                       "被拦下的这次「立即发送」不能顺手把耐久标记覆写回旧值")
        try? await service.stop()
    }    /// §229-1: with no queue twin to hold, the reject leaves no durable trace at
    /// all — yet the receipt promised 「已经按住，不会自动发出」. A promise the
    /// producer cannot honour is worse than a failure, because the user stops
    /// checking.
    func testRejectWithNothingToHoldDoesNotPromiseItIsHeld() async throws {
        try await service.start()
        let sid = try XCTUnwrap(store.currentAutopilotSession()?.id)
        try store.insertAutopilotLog(AutopilotLogEntry(
            id: 0, sessionId: sid, chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "", senderName: "同事", triggerMsgUID: "m-lonely",
            triggerText: "在吗", generatedReply: "我看看再回你", confidence: 0.9,
            riskLevel: .low, action: .pending, aiReasoning: nil, sentAt: nil,
            createdAt: Date(), queueId: nil
        ))
        let logId = try XCTUnwrap(
            store.loadAutopilotLog(sessionId: sid).first { $0.triggerMsgUID == "m-lonely" }?.id)
        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)

        let outcome = await service.rejectPending(
            logId: logId, chatUsername: "wxid_peer", replyText: "我看看再回你")
        guard case .held(let reason) = outcome else {
            return XCTFail("翻转写失败时不能回报 .withdrawn: \(outcome)")
        }
        XCTAssertFalse(reason.contains("已经按住"),
                       "没有任何耐久载体时不能说「已经按住」： \(reason)")
        XCTAssertTrue(reason.contains("再按一次") || reason.contains("核对"),
                      "必须把用户下一步能做的事说出来: \(reason)")
        try? await service.stop()
    }

    /// The other branch still earns its stronger promise — otherwise the fix is
    /// just two copies of one generic warning.
    func testRejectWithAHeldTwinStillSaysItIsHeld() async throws {
        let (item, logId, _) = try await staged()
        try store.exec("""
            CREATE TRIGGER flip_denied BEFORE UPDATE ON autopilot_log
            BEGIN SELECT RAISE(ABORT, 'disk i/o error'); END
        """)
        let outcome = await service.rejectPending(
            logId: logId, chatUsername: "wxid_peer", replyText: item.replyText)
        guard case .held(let reason) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertTrue(reason.contains("已经按住"), reason)
    }
}
