import XCTest
@testable import WeChatHUD

/// The batch window, the hourly send cap, and the axis they are measured on.
///
/// All three are elapsed time between events this process observed, so they
/// run on `MonotonicClock.seconds()` rather than `Date()`: a system clock the
/// user can move would otherwise either erase the window (a forward jump ages
/// every send out of the rolling hour, disarming the cap for a second full
/// round of unattended sends) or make it unreachable (a backward jump leaves
/// the batch deadline in the future for the length of the jump, and the
/// messages sit in the buffer being re-fed on every scan).
final class AutopilotBatchWindowTests: XCTestCase {
    /// Seconds-since-boot shaped, not epoch shaped: that gap is what makes the
    /// service-level test below able to tell the two clocks apart.
    private let firstArrival: TimeInterval = 1_000

    // MARK: - Batch deadline arithmetic

    func testConfiguredWindowIsUsedForFirstMessage() {
        let fiveSecond = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival,
            window: 5,
            existingDeadline: nil
        )
        let tenSecond = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival,
            window: 10,
            existingDeadline: nil
        )

        XCTAssertEqual(fiveSecond, firstArrival + 5)
        XCTAssertEqual(tenSecond, firstArrival + 10)
    }

    func testContinuousMessageExtendsByTenSeconds() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival + 15,
            window: 10,
            existingDeadline: firstArrival + 10
        )

        XCTAssertEqual(deadline, firstArrival + 25)
    }

    func testContinuousMessageNeverShortensExistingDeadline() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival + 2,
            window: 30,
            existingDeadline: firstArrival + 30
        )

        XCTAssertEqual(deadline, firstArrival + 30)
    }

    func testContinuousMessageIsCappedAtSixtySecondsFromFirstArrival() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival + 55,
            window: 30,
            existingDeadline: firstArrival + 50
        )

        XCTAssertEqual(deadline, firstArrival + 60)
    }

    func testInitialWindowAlsoHonorsSixtySecondCap() {
        let deadline = AutopilotService.batchDeadline(
            firstArrival: firstArrival,
            now: firstArrival,
            window: 90,
            existingDeadline: nil
        )

        XCTAssertEqual(deadline, firstArrival + 60)
    }

    // MARK: - Hourly send cap

    func testCapBlocksAtTheLimitAndAllowsBelowIt() {
        let sends: [TimeInterval] = [100, 200, 300]
        XCTAssertFalse(AutopilotService.rollingSendHour(
            sendTimes: sends, now: 400, limit: 4
        ).blocked)
        XCTAssertTrue(AutopilotService.rollingSendHour(
            sendTimes: sends, now: 400, limit: 3
        ).blocked)
    }

    /// `<= 0` is unlimited. A plain `count >= limit` would block every send at
    /// 0, which is how `maxSendsPerSession` was already documented to behave.
    func testCapOfZeroMeansUnlimitedNotAlwaysBlocked() {
        let outcome = AutopilotService.rollingSendHour(
            sendTimes: [100, 200, 300, 400, 500], now: 500, limit: 0
        )
        XCTAssertFalse(outcome.blocked)
        XCTAssertEqual(outcome.retained.count, 5)
    }

    /// The retained array is what gets counted, so the number in the log line
    /// and the number compared against the limit cannot drift apart.
    func testCapCountsTheSameArrayItKeeps() {
        let outcome = AutopilotService.rollingSendHour(
            sendTimes: [0, 10, 3_601, 3_700], now: 3_700, limit: 5
        )
        XCTAssertEqual(outcome.retained, [3_601, 3_700])
        XCTAssertFalse(outcome.blocked)
    }

    // MARK: - Which clock the windows run on

    /// Behaviour proof, not a grep: with the clock injected at a
    /// seconds-since-boot magnitude, a batch only flushes when *that* axis
    /// crosses the deadline. Measured against `Date()` the deadline is
    /// ~1.77 billion and this advance changes nothing, which is the whole
    /// defect — and the reason the assertion below fails on the old code.
    @MainActor
    func testBatchWindowIsMeasuredOnTheInjectedAxis() async throws {
        let clock = MonotonicTestClock(1_000)
        let (service, teardown) = try await makeService(monotonic: { clock.seconds })
        defer { teardown() }
        var config = AutopilotConfig()
        config.batchWindowSeconds = 10

        let message = inbound(uid: "clock-1", text: "在吗", timestamp: Date())
        let buffered = await service.handleNewMessages([message], config: config, myUsername: "me")
        XCTAssertTrue(buffered.logEntries.isEmpty, "the window has not elapsed on this axis yet")

        clock.advance(by: 11)
        let flushed = await service.handleNewMessages([], config: config, myUsername: "me")
        XCTAssertEqual(flushed.logEntries.count, 1, "advancing the clock the window is measured on must flush the batch")
        XCTAssertEqual(flushed.ackedMsgUIDs, ["clock-1"])
    }

    /// A message older than the horizon must never enter a batch: it reaches
    /// this path from the durable inbound queue on every scan until it is
    /// acknowledged, so a session started after the app sat closed for a week
    /// used to answer that week.
    @MainActor
    func testMessagePastTheHorizonIsDroppedAndAcknowledged() async throws {
        let (service, teardown) = try await makeService(monotonic: { MonotonicClock.seconds() })
        defer { teardown() }
        var config = AutopilotConfig()
        config.batchWindowSeconds = 10

        let old = inbound(uid: "old-1", text: "在吗", timestamp: Date().addingTimeInterval(-3_600))
        let result = await service.handleNewMessages([old], config: config, myUsername: "me")

        XCTAssertEqual(result.logEntries.count, 1, "a drop has to leave an audit row, not just silence")
        XCTAssertEqual(result.logEntries.first?.action, .skipped)
        XCTAssertTrue(result.logEntries.first?.aiReasoning?.contains("不再回复") == true,
                      "\(result.logEntries.first?.aiReasoning ?? "nil")")
        XCTAssertEqual(result.ackedMsgUIDs, ["old-1"], "unacknowledged rows are fed again on every scan")
        let pendingAfterDrop = await service.hasPendingBatches
        XCTAssertFalse(pendingAfterDrop, "nothing may stay buffered behind a dropped message")
    }

    /// The paused half of the same defect: `allExpired` is forced empty while
    /// paused and each buffered row is already in `processedMsgUIDs`, so no
    /// later feed removes it either. A day of 暂停 was a day of backlog that
    /// got answered on resume.
    @MainActor
    func testBufferedBacklogAgesOutInsteadOfReplaying() async throws {
        let (service, teardown) = try await makeService(monotonic: { MonotonicClock.seconds() })
        defer { teardown() }
        var config = AutopilotConfig()
        config.batchWindowSeconds = 10

        // Young when it arrives, so it is buffered — and stays buffered.
        let fresh = inbound(uid: "fresh-1", text: "在吗", timestamp: Date())
        let buffered = await service.handleNewMessages([fresh], config: config, myUsername: "me")
        XCTAssertTrue(buffered.logEntries.isEmpty)
        let bufferedFlag = await service.hasPendingBatches
        XCTAssertTrue(bufferedFlag)

        let aged = await service.ageOutBufferedMessages(
            now: Date().addingTimeInterval(601), horizon: AutopilotService.batchReplyHorizon
        )
        XCTAssertEqual(aged.entries.count, 1)
        XCTAssertTrue(aged.entries.first?.aiReasoning?.contains("暂停期间积压") == true,
                      "\(aged.entries.first?.aiReasoning ?? "nil")")
        XCTAssertEqual(aged.ackedMsgUIDs, ["fresh-1"])
        let stillPending = await service.hasPendingBatches
        XCTAssertFalse(stillPending, "the aged-out batch must not survive to be answered")

        // Nothing is left for the resume path to replay.
        let afterResume = await service.handleNewMessages([], config: config, myUsername: "me")
        XCTAssertTrue(afterResume.logEntries.isEmpty)
    }

    /// One-sided on purpose: a peer whose clock runs ahead cannot mute its own
    /// chat by sending a future-dated message.
    func testFutureTimestampsStayEligible() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AutopilotService.isPastReplyHorizon(
            timestamp: 1_000 + 3_600, now: now, horizon: 600
        ))
        XCTAssertTrue(AutopilotService.isPastReplyHorizon(
            timestamp: 1_000 - 601, now: now, horizon: 600
        ))
        XCTAssertFalse(AutopilotService.isPastReplyHorizon(
            timestamp: 1_000 - 599, now: now, horizon: 600
        ))
    }

    // MARK: - Harness

    @MainActor
    private func makeService(
        monotonic: @escaping MonotonicSeconds
    ) async throws -> (AutopilotService, @MainActor () -> Void) {
        let tmpPath = NSTemporaryDirectory()
            + "hud_autopilot_clock_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: tmpPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = AutopilotService(
            store: store,
            reader: WeChatReader(dbDir: root.path, cacheStrategy: .memory),
            aiService: AIService(),
            monotonic: monotonic
        )
        try await service.start()
        let teardown: @MainActor () -> Void = {
            store.close()
            try? FileManager.default.removeItem(atPath: tmpPath)
            try? FileManager.default.removeItem(at: root)
        }
        return (service, teardown)
    }

    private func inbound(uid: String, text: String, timestamp: Date) -> AutopilotService.InboundMessage {
        AutopilotService.InboundMessage(
            msgUID: uid,
            chatUsername: "wxid_peer", chatName: "同事",
            senderUsername: "wxid_peer", senderName: "同事",
            text: text, isGroup: false, isAtMention: false,
            attentionLevel: .whitelist, contactRole: .colleague,
            timestamp: Int(timestamp.timeIntervalSince1970),
            messageType: 1, appType: 0
        )
    }

    /// Wiring for the two halves the pure functions cannot pin: the store is
    /// monotonic-typed, and the send path reads the monotonic clock. A second
    /// `Date()`-based reading of the same window anywhere in that body would
    /// make the cap jumpable again while every unit test stayed green.
    func testSendCapAndStallWindowReadTheMonotonicAxis() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("private var globalSendTimestamps: [TimeInterval]"),
                      "滚动小时的时间戳必须落在不可被用户拨动的轴上")
        XCTAssertTrue(source.contains("private var recentStallByContact: [String: (text: String, timestamp: TimeInterval)]"))
        XCTAssertTrue(source.contains("private var batchTimers: [String: TimeInterval]"))

        let body = try XCTUnwrap(
            Self.body(of: "private func serialSendWithRateLimit", in: source),
            "闸门函数改名了，这条判据就先失效，别让它悄悄变成零命中"
        )
        XCTAssertTrue(body.contains("monotonic()"))
        XCTAssertFalse(body.contains("Date()"), "每小时上限一旦改回墙钟就能被拨表绕过")
        XCTAssertFalse(body.contains("3600"), "窗口只在 rollingSendHour 里算一次")
    }

    /// The age-out sweep is behaviour-tested on its own, so the only thing
    /// left unproven is that `handleNewMessages` runs it *and uses what it
    /// returns*: deleting the call, or calling it and dropping the rows and
    /// the ids on the floor, both leave a paused engine replaying the backlog.
    func testFeedPathRunsTheAgeOutSweepAndKeepsItsResult() throws {
        let source = try readServiceSource()
        let body = try XCTUnwrap(
            Self.body(of: "func handleNewMessages", in: source),
            "喂入函数改名了，这条判据就先失效"
        )
        let calls = body.range(of: "ageOutBufferedMessages(")
        XCTAssertNotNil(calls, "暂停期间没有任何东西会排空缓冲区，这一趟是唯一的机会")
        let tail = body[calls!.lowerBound...]
        XCTAssertTrue(tail.contains("horizon: Self.batchReplyHorizon"),
                      "调用点必须用生产阈值，否则这条链路可以在测试之外被改成永不淘汰")
        XCTAssertTrue(tail.contains("immediateEntries.append(contentsOf: aged"))
        XCTAssertTrue(tail.contains("ackedMsgUIDs.append(contentsOf: aged"))
    }

    private func readServiceSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift"),
            encoding: .utf8
        )
    }

    /// The function body, from its signature to the next member at the same
    /// indentation — a fixed character window read a missing gate the first
    /// time a comment was added above the call.
    private static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}

/// Mutable monotonic instant shared between the test and the actor's closure.
private final class MonotonicTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }

    var seconds: TimeInterval {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}
