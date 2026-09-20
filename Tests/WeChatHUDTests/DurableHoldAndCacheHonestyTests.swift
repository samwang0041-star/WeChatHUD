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
