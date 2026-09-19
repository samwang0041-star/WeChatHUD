import XCTest
@testable import WeChatHUD

/// Tests for ProactiveAlertEngine rule logic and injected delivery state.
/// The sender is injected so these tests never request macOS notification
/// permission or enqueue a real UNNotification.
final class ProactiveAlertTests: XCTestCase {

    private struct TestError: Error {}

    // MARK: - UnreadItem factory

    private func makeUnread(
        chatUsername: String = "chat1",
        senderName: String = "Alice",
        isVIP: Bool = false,
        status: UnreadStatus = .pending,
        replied: Bool = false,
        minutesAgo: Int = 5,
        timestamp: Date? = nil
    ) -> UnreadItem {
        UnreadItem(
            chatUsername: chatUsername,
            chatName: chatUsername,
            senderUsername: "wxid_\(senderName.lowercased())",
            senderName: senderName,
            preview: "hello",
            timestamp: timestamp ?? Date(timeIntervalSinceNow: -Double(minutesAgo * 60)),
            kind: .privateChat,
            isWhitelisted: true,
            isVIP: isVIP,
            replied: replied,
            status: status,
            isIgnored: false,
            unansweredInboundCount: 1
        )
    }

    // MARK: - ReplyDebtItem factory

    private func makeDebt(
        chatUsername: String,
        chatName: String = "Chat",
        priority: ReplyDebtPriority,
        minutesOld: Int,
        now: Date
    ) -> ReplyDebtItem {
        ReplyDebtItem(
            id: chatUsername,
            chatUsername: chatUsername,
            chatName: chatName,
            senderName: chatName,
            preview: "方案你定了吗？",
            latestOutboundPreview: nil,
            timestamp: now.addingTimeInterval(-Double(minutesOld * 60)),
            priority: priority,
            score: 9,
            unreadCount: 1,
            isGroup: false,
            isWhitelisted: true,
            isVIP: false,
            isAtMention: false,
            inboundCountSinceLastOutbound: 1,
            reasons: [],
            overdueThresholdMinutes: 120
        )
    }

    // MARK: - Rule 1: VIP overdue

    /// A tier advance is delivered as a macOS notification and nothing
    /// else. The engine used to also hand the advance to an in-panel
    /// escalation toast ("「名字」已等你 4h+ — 该回一下了"); that banner was
    /// removed as superseded UI, so this pins the remaining contract:
    /// exactly one notification per tier, with the tier's own wording.
    @MainActor
    func testTierAdvanceNotifiesOnceWithTierWording() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
        var sent: [(String, String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { title, body, _, completion in
                sent.append((title, body))
                completion(nil)
            }
        )
        // 4h+ overdue -> T4.
        let item = makeUnread(
            chatUsername: "vip-chat",
            senderName: "Alice",
            isVIP: true,
            timestamp: start.addingTimeInterval(-5 * 60 * 60)
        )

        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()
        XCTAssertEqual(engine.vipAlertTiers["vip-chat"], .t4)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "VIP 等你 4 小时了")

        // Re-evaluating the same overdue message must not notify again.
        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()
        XCTAssertEqual(sent.count, 1)
    }

    /// The first tier must not use the word 超时. 超时 is the per-contact,
    /// user-configurable 回复窗口 (关注谁 → 多久算超时), while this ladder is
    /// fixed milestones — the two are documented as independent, so a banner
    /// saying 「已超时未回复」 at 30 分钟 contradicted an inbox row that was
    /// correctly not 超时 for a contact with a 2 小时 window.
    @MainActor
    func testFirstTierClaimsTheWaitNotATimeout() async {
        let start = Date(timeIntervalSince1970: 3_100_000)
        var sent: [(String, String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { title, body, _, completion in
                sent.append((title, body))
                completion(nil)
            }
        )
        let item = makeUnread(
            chatUsername: "vip-chat", senderName: "Alice", isVIP: true,
            timestamp: start.addingTimeInterval(-45 * 60)
        )

        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()

        XCTAssertEqual(engine.vipAlertTiers["vip-chat"], .t1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "VIP 等你 30 分钟了")
        XCTAssertEqual(sent.first?.1, "Alice 的消息还没回")
        XCTAssertFalse(sent.contains { $0.0.contains("超时") || $0.1.contains("超时") },
                       "the ladder must not borrow the configurable 超时 word")
    }

    /// A VIP item you already answered must not escalate — before this
    /// fix, replied rows still fired "VIP 等你 2 小时了" OS alerts.
    @MainActor
    func testRepliedVIPItemDoesNotEscalate() async {
        var sent: [(String, String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: Date.init,
            sendNotification: { title, body, _, completion in
                sent.append((title, body))
                completion(nil)
            }
        )
        let item = makeUnread(
            chatUsername: "vip-chat",
            isVIP: true,
            replied: true,
            timestamp: Date().addingTimeInterval(-3 * 60 * 60)
        )

        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()
        XCTAssertTrue(engine.vipAlertTiers.isEmpty)
        XCTAssertTrue(sent.isEmpty)
    }

    /// A chat you're actively exchanging in must not escalate or burst —
    /// you are watching it; the alerts would be pure interruption.
    @MainActor
    func testActiveConversationSuppressesVIPAndBurstAlerts() async {
        var sent: [(String, String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: Date.init,
            sendNotification: { title, body, _, completion in
                sent.append((title, body))
                completion(nil)
            }
        )
        let vip = makeUnread(
            chatUsername: "live-chat",
            isVIP: true,
            timestamp: Date().addingTimeInterval(-3 * 60 * 60)
        )
        let burstItems = (0..<3).map { i in
            makeUnread(chatUsername: "live-chat-\(i)", senderName: "Bob")
        }

        engine.evaluate(
            unreadItems: [vip] + burstItems,
            replyDebtItems: [],
            commitments: [],
            recentNotifications: [],
            activeConversations: ["live-chat", "live-chat-0", "live-chat-1", "live-chat-2"]
        )
        await Task.yield()
        XCTAssertTrue(engine.vipAlertTiers.isEmpty)
        XCTAssertTrue(sent.isEmpty)
    }

    /// Rule 4 read the *first* element of the priority-sorted debt list and
    /// asked whether it was P0. When that one chat happened to be the one you
    /// were typing in, the whole rule went silent — a second P0 that had been
    /// waiting three hours behind it never alerted.
    @MainActor
    func testP0BehindAnActiveConversationStillAlerts() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
        var sent: [(String, String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { title, body, _, completion in
                sent.append((title, body))
                completion(nil)
            }
        )

        engine.evaluate(
            unreadItems: [],
            replyDebtItems: [
                makeDebt(chatUsername: "live-chat", chatName: "在聊的", priority: .p0, minutesOld: 45, now: start),
                makeDebt(chatUsername: "buried-chat", chatName: "老板", priority: .p0, minutesOld: 180, now: start)
            ],
            commitments: [],
            recentNotifications: [],
            activeConversations: ["live-chat"]
        )
        await Task.yield()

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "紧急待回复")
        XCTAssertEqual(sent.first?.1, "老板: 方案你定了吗？")
    }

    /// The P0 path skips the rate budget, so one evaluation must not fan out
    /// across every P0 in the list.
    @MainActor
    func testP0AlertFiresAtMostOncePerEvaluation() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
        var sent: [(String, String)] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { title, body, _, completion in
                sent.append((title, body))
                completion(nil)
            }
        )

        engine.evaluate(
            unreadItems: [],
            replyDebtItems: (0..<4).map {
                makeDebt(chatUsername: "p0-\($0)", priority: .p0, minutesOld: 60, now: start)
            },
            commitments: [],
            recentNotifications: []
        )
        await Task.yield()

        XCTAssertEqual(sent.count, 1)
    }

    func testVIPOverdueTriggersAlert() {
        let items = [makeUnread(isVIP: true, status: .overdue)]
        let overdueVIPs = items.filter { $0.isVIP && $0.status == .overdue }
        XCTAssertEqual(overdueVIPs.count, 1)
    }

    func testNonVIPOverdueDoesNotTrigger() {
        let items = [makeUnread(isVIP: false, status: .overdue)]
        let overdueVIPs = items.filter { $0.isVIP && $0.status == .overdue }
        XCTAssertEqual(overdueVIPs.count, 0)
    }

    func testVIPPendingDoesNotTrigger() {
        let items = [makeUnread(isVIP: true, status: .pending)]
        let overdueVIPs = items.filter { $0.isVIP && $0.status == .overdue }
        XCTAssertEqual(overdueVIPs.count, 0)
    }

    // MARK: - Rule 2: Commitment deadline

    func testCommitmentDeadlineApproachingTriggersAlert() {
        let c = Commitment(
            id: 1, msgUID: "m1", chatUsername: "c1", chatName: "C1",
            content: "发报告", commitTo: "Boss",
            deadlineAt: Date(timeIntervalSinceNow: 1800),  // 30 min from now
            confidence: 0.9, status: .pending,
            promptVersion: "v1", createdAt: Date(), updatedAt: Date()
        )
        let remaining = c.deadlineAt!.timeIntervalSince(Date())
        XCTAssertTrue(remaining > 0 && remaining < 3600)
    }

    func testCommitmentFarFutureDoesNotTrigger() {
        let c = Commitment(
            id: 1, msgUID: "m1", chatUsername: "c1", chatName: "C1",
            content: "发报告", commitTo: "Boss",
            deadlineAt: Date(timeIntervalSinceNow: 86400),  // 1 day from now
            confidence: 0.9, status: .pending,
            promptVersion: "v1", createdAt: Date(), updatedAt: Date()
        )
        let remaining = c.deadlineAt!.timeIntervalSince(Date())
        XCTAssertFalse(remaining > 0 && remaining < 3600)
    }

    @MainActor
    func testCommitmentCrossingDeadlineAlertsOncePerPhase() {
        let start = Date(timeIntervalSince1970: 4_000_000)
        var current = start
        var titles: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"), now: { current },
            monotonic: { current.timeIntervalSince1970 },
            sendNotification: { title, _, _, _ in titles.append(title) }
        )
        let commitment = Commitment(
            id: 1, msgUID: "due", chatUsername: "chat", chatName: "聊天",
            content: "发报告", commitTo: "同事", deadlineAt: start.addingTimeInterval(60),
            confidence: 0.9, status: .pending, promptVersion: "v1", createdAt: start, updatedAt: start
        )
        engine.evaluate(unreadItems: [], replyDebtItems: [], commitments: [commitment], recentNotifications: [])
        current = start.addingTimeInterval(60)
        engine.evaluate(unreadItems: [], replyDebtItems: [], commitments: [commitment], recentNotifications: [])
        engine.evaluate(unreadItems: [], replyDebtItems: [], commitments: [commitment], recentNotifications: [])
        XCTAssertEqual(titles, ["承诺即将到期", "承诺已到期"])
    }

    @MainActor
    func testOverdueCommitmentAfterAbsenceAlertsButResolvedDoesNot() {
        let current = Date(timeIntervalSince1970: 4_000_000)
        var titles: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"), now: { current },
            monotonic: { current.timeIntervalSince1970 },
            sendNotification: { title, _, _, _ in titles.append(title) }
        )
        func commitment(_ status: CommitmentStatus, id: String) -> Commitment {
            Commitment(id: 1, msgUID: id, chatUsername: "chat", chatName: "聊天",
                       content: "发报告", commitTo: "同事", deadlineAt: current.addingTimeInterval(-7200),
                       confidence: 0.9, status: status, promptVersion: "v1", createdAt: current, updatedAt: current)
        }
        engine.evaluate(unreadItems: [], replyDebtItems: [], commitments: [
            commitment(.overdue, id: "overdue"), commitment(.fulfilled, id: "done"),
            commitment(.cancelled, id: "cancelled")
        ], recentNotifications: [])
        XCTAssertEqual(titles, ["承诺已到期"])
    }

    @MainActor
    func testStandaloneDeadlineTickAlertsOverdueAndSkipsResolved() async {
        let now = Date(timeIntervalSince1970: 4_500_000)
        var titles: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"), now: { now },
            sendNotification: { title, _, _, completion in
                titles.append(title)
                completion(nil)
            }
        )
        func make(_ status: CommitmentStatus, _ id: String) -> Commitment {
            Commitment(id: 1, msgUID: id, chatUsername: "chat", chatName: "聊天",
                       content: "发报告", commitTo: "同事", deadlineAt: now.addingTimeInterval(-60),
                       confidence: 0.9, status: status, promptVersion: "v1", createdAt: now, updatedAt: now)
        }

        engine.evaluateCommitmentDeadlines(commitments: [make(.overdue, "late"), make(.fulfilled, "done"), make(.cancelled, "cancelled")])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"])
    }

    @MainActor
    func testFullScanAndStandaloneTickShareCommitmentDedup() async {
        let now = Date(timeIntervalSince1970: 4_600_000)
        var sends = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"), now: { now },
            sendNotification: { _, _, _, completion in
                sends += 1
                completion(nil)
            }
        )
        let commitment = Commitment(id: 1, msgUID: "same", chatUsername: "chat", chatName: "聊天",
                                    content: "发报告", commitTo: "同事", deadlineAt: now.addingTimeInterval(-60),
                                    confidence: 0.9, status: .overdue, promptVersion: "v1", createdAt: now, updatedAt: now)

        engine.evaluate(unreadItems: [], replyDebtItems: [], commitments: [commitment], recentNotifications: [])
        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(sends, 1)
    }

    /// An overdue commitment stays overdue until the user resolves it, so its
    /// alert needs its own quiet period: with the one-hour default it re-fired
    /// every hour, forever, and consumed the shared 5/hour budget that the P0
    /// and VIP rules need for new signals.
    @MainActor
    func testOverdueCommitmentDoesNotReAlertEveryHour() async {
        let start = Date(timeIntervalSince1970: 5_000_000)
        var current = start
        var titles: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { current },
            monotonic: { current.timeIntervalSince1970 },
            sendNotification: { title, _, _, completion in
                titles.append(title)
                completion(nil)
            }
        )
        let commitment = Commitment(
            id: 1, msgUID: "late", chatUsername: "chat", chatName: "聊天",
            content: "发报告", commitTo: "同事",
            deadlineAt: start.addingTimeInterval(-3_600),
            confidence: 0.9, status: .overdue, promptVersion: "v1",
            createdAt: start, updatedAt: start
        )

        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"])

        current = start.addingTimeInterval(3_600)
        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"], "an unresolved commitment must not re-alert every hour")

        current = start.addingTimeInterval(24 * 3_600 + 1)
        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles.count, 2, "the daily reminder is still allowed")
    }

    // MARK: - Rule 3: Burst messages

    func testBurstDetection() {
        let items = [
            makeUnread(senderName: "Alice"),
            makeUnread(senderName: "Alice"),
            makeUnread(senderName: "Alice"),
            makeUnread(senderName: "Bob"),
        ]
        var senderCounts: [String: Int] = [:]
        for item in items { senderCounts[item.senderName, default: 0] += 1 }
        let bursts = senderCounts.filter { $0.value >= 3 }
        XCTAssertEqual(bursts.count, 1)
        XCTAssertEqual(bursts["Alice"], 3)
    }

    func testNoBurstBelowThreshold() {
        let items = [
            makeUnread(senderName: "Alice"),
            makeUnread(senderName: "Alice"),
            makeUnread(senderName: "Bob"),
        ]
        var senderCounts: [String: Int] = [:]
        for item in items { senderCounts[item.senderName, default: 0] += 1 }
        let bursts = senderCounts.filter { $0.value >= 3 }
        XCTAssertTrue(bursts.isEmpty)
    }

    // MARK: - Rate limit logic

    /// The hourly budget and the per-identifier cooldown are elapsed time
    /// between two events this process observed, so they are measured on the
    /// monotonic axis. Recorded against `Date` they could be erased — or made
    /// unreachable — by anyone setting the system clock: a forward jump aged
    /// every entry out of its hour, which re-fired an unresolved commitment
    /// alert immediately and refilled the 5-per-hour budget that the P0 rule
    /// depends on. The two assertions below are that jump, in one direction
    /// and then the other.
    @MainActor
    func testForwardWallClockJumpDoesNotRefireAnOverdueCommitment() async {
        let start = Date(timeIntervalSince1970: 5_000_000)
        var wall = start
        var mono: TimeInterval = 900_000
        var titles: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { wall },
            monotonic: { mono },
            sendNotification: { title, _, _, completion in
                titles.append(title)
                completion(nil)
            }
        )
        let commitment = Commitment(
            id: 1, msgUID: "late", chatUsername: "chat", chatName: "聊天",
            content: "发报告", commitTo: "同事",
            deadlineAt: start.addingTimeInterval(-3_600),
            confidence: 0.9, status: .overdue, promptVersion: "v1",
            createdAt: start, updatedAt: start
        )

        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"])

        // Three days of wall clock, one second of real elapsed time.
        wall = wall.addingTimeInterval(3 * 86_400)
        mono += 1
        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"], "墙钟跳格不能把 24 小时静默期清零")
    }

    @MainActor
    func testForwardWallClockJumpDoesNotRefillTheHourlyBudget() async {
        let start = Date(timeIntervalSince1970: 5_500_000)
        var wall = start
        var mono: TimeInterval = 910_000
        var sends = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { wall },
            monotonic: { mono },
            sendNotification: { _, _, _, completion in
                sends += 1
                completion(nil)
            }
        )

        for index in 0..<5 {
            engine.pushCrossGroupVIPAlert(
                vipName: "同事", vipUsername: "alice-\(index)",
                groupName: "群聊", groupUsername: "group-\(index)",
                preview: "hello", messageCount: 1
            )
        }
        await Task.yield()
        XCTAssertEqual(sends, 5)

        wall = wall.addingTimeInterval(3 * 86_400)
        mono += 1
        engine.pushCrossGroupVIPAlert(
            vipName: "同事", vipUsername: "alice-six",
            groupName: "群聊", groupUsername: "group-six",
            preview: "hello", messageCount: 1
        )
        await Task.yield()
        XCTAssertEqual(sends, 5, "墙钟跳格不能把每小时配额退回，P0 规则依赖这个上限")
    }

    /// The mirror image: measuring these windows on a clock the system owns
    /// could also make them unreachable rather than erasable. Pruning
    /// uptime-scaled entries against a seconds-since-1970 cutoff (or the other
    /// way round) leaves nothing eligible ever again, and 设置 still reads
    /// 「已开启提醒」. So a window that genuinely elapsed must still reopen —
    /// here the wall clock has only gone backwards.
    @MainActor
    func testBackwardWallClockJumpDoesNotMuteAlertsForever() async {
        let start = Date(timeIntervalSince1970: 6_000_000)
        var wall = start
        var mono: TimeInterval = 40_000
        var titles: [String] = []
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { wall },
            monotonic: { mono },
            sendNotification: { title, _, _, completion in
                titles.append(title)
                completion(nil)
            }
        )
        let commitment = Commitment(
            id: 1, msgUID: "late", chatUsername: "chat", chatName: "聊天",
            content: "发报告", commitTo: "同事",
            deadlineAt: start.addingTimeInterval(-3_600),
            confidence: 0.9, status: .overdue, promptVersion: "v1",
            createdAt: start, updatedAt: start
        )

        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"])

        // The quiet period has genuinely elapsed; the wall clock has gone the
        // other way (kept barely earlier, so the commitment is still overdue
        // and only the window axis is in question).
        mono += 24 * 3_600 + 1
        wall = wall.addingTimeInterval(-1)
        engine.evaluateCommitmentDeadlines(commitments: [commitment])
        await Task.yield()
        XCTAssertEqual(titles.count, 2, "静默期真的过了就要再提醒，哪怕墙钟倒退了")
    }

    // MARK: - Engine delivery state

    @MainActor
    func testIdentifierDedupExpiresAfterOneHour() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var current = start
        var sends = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { current },
            monotonic: { current.timeIntervalSince1970 },
            sendNotification: { _, _, _, completion in
                sends += 1
                completion(nil)
            }
        )

        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "hello", messageCount: 1
        )
        await Task.yield()
        XCTAssertEqual(sends, 1)

        current = start.addingTimeInterval(3599)
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "hello again", messageCount: 1
        )
        await Task.yield()
        XCTAssertEqual(sends, 1)

        current = start.addingTimeInterval(3600)
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "hello later", messageCount: 1
        )
        await Task.yield()
        XCTAssertEqual(sends, 2)
    }

    @MainActor
    func testHourlyBudgetIncludesInFlightAndReopensAfterWindow() async {
        let start = Date(timeIntervalSince1970: 2_000_000)
        var current = start
        var sends = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { current },
            monotonic: { current.timeIntervalSince1970 },
            sendNotification: { _, _, _, completion in
                sends += 1
                completion(nil)
            }
        )

        for index in 0..<5 {
            engine.pushCrossGroupVIPAlert(
                vipName: "Alice", vipUsername: "alice-\(index)",
                groupName: "群聊", groupUsername: "group-\(index)",
                preview: "hello", messageCount: 1
            )
        }
        // Completions are asynchronous from the engine's perspective. The
        // five in-flight reservations must already consume the budget.
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice-six",
            groupName: "群聊", groupUsername: "group-six",
            preview: "blocked", messageCount: 1
        )
        XCTAssertEqual(sends, 5)
        await Task.yield()

        current = start.addingTimeInterval(3599)
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice-six",
            groupName: "群聊", groupUsername: "group-six",
            preview: "still blocked", messageCount: 1
        )
        await Task.yield()
        XCTAssertEqual(sends, 5)

        current = start.addingTimeInterval(3601)
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice-six",
            groupName: "群聊", groupUsername: "group-six",
            preview: "allowed", messageCount: 1
        )
        await Task.yield()
        XCTAssertEqual(sends, 6)
    }

    @MainActor
    func testFailedSendDoesNotConsumeDedupOrBudget() async {
        var attempt = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: Date.init,
            sendNotification: { _, _, _, completion in
                attempt += 1
                completion(attempt == 1 ? TestError() : nil)
            }
        )

        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "first", messageCount: 1
        )
        await Task.yield()
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "retry", messageCount: 1
        )
        await Task.yield()

        XCTAssertEqual(attempt, 2)
    }

    @MainActor
    func testSameIdentifierCannotBeSubmittedConcurrently() async {
        var completions: [@Sendable (Error?) -> Void] = []
        var sends = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: Date.init,
            sendNotification: { _, _, _, completion in
                sends += 1
                completions.append(completion)
            }
        )

        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "first", messageCount: 1
        )
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "duplicate", messageCount: 1
        )
        XCTAssertEqual(sends, 1)

        completions[0](nil)
        await Task.yield()
        engine.pushCrossGroupVIPAlert(
            vipName: "Alice", vipUsername: "alice",
            groupName: "群聊", groupUsername: "group",
            preview: "after success", messageCount: 1
        )
        XCTAssertEqual(sends, 1)
    }

    @MainActor
    func testVIPTierRemainsVisibleAndRetriesAfterFailedSend() async {
        let start = Date(timeIntervalSince1970: 3_000_000)
        var attempt = 0
        let engine = ProactiveAlertEngine(
            store: HUDStore(dbPath: ":memory:"),
            now: { start },
            sendNotification: { _, _, _, completion in
                attempt += 1
                completion(attempt == 1 ? TestError() : nil)
            }
        )
        let item = makeUnread(
            chatUsername: "vip-chat",
            senderName: "Alice",
            isVIP: true,
            timestamp: start.addingTimeInterval(-40 * 60)
        )

        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        XCTAssertEqual(engine.vipAlertTiers["vip-chat"], .t1)
        await Task.yield()

        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()

        // The first submission failed, the retry succeeded.
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(engine.vipAlertTiers["vip-chat"], .t1)

        // The successful retry recorded the tier, so another scan must not
        // push the same escalation at the user twice.
        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(engine.vipAlertTiers["vip-chat"], .t1)
    }

    // MARK: - The mute list has to reach the commitment path too

    /// 「不想再看到谁的消息 — 选谁，就哪个对话都不再提醒——包括他所在的群」
    /// (`AdmissionSettingsView.swift:626`). The scan path honoured that through
    /// `AdmissionPolicy.isMuted`; the deadline path consulted no mute list at all,
    /// so a muted person's overdue promise kept waking the notification centre.
    @MainActor
    func testGloballyMutedPersonStaysSilentOnCommitmentDeadline() async throws {
        let now = Date(timeIntervalSince1970: 5_100_000)
        var titles: [String] = []
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        try store.ignoreSenderEverywhere(senderUsername: "", senderName: "同事")
        let engine = ProactiveAlertEngine(
            store: store, now: { now },
            sendNotification: { title, _, _, completion in
                titles.append(title)
                completion(nil)
            }
        )
        func make(_ id: String, to person: String) -> Commitment {
            Commitment(id: 1, msgUID: id, chatUsername: "chat", chatName: "聊天",
                       content: "发报告", commitTo: person, deadlineAt: now.addingTimeInterval(-60),
                       confidence: 0.9, status: .overdue, promptVersion: "v1", createdAt: now, updatedAt: now)
        }

        engine.evaluateCommitmentDeadlines(commitments: [make("muted", to: "同事")])
        await Task.yield()
        XCTAssertEqual(titles, [], "a muted person's deadline must stay silent")

        // Control: the identical alert still fires for a name the user did not
        // mute, so the silence above is the gate working, not a dead harness.
        engine.evaluateCommitmentDeadlines(commitments: [make("loud", to: "另一个人")])
        await Task.yield()
        XCTAssertEqual(titles, ["承诺已到期"])
    }

    /// A chat-scoped mute silences that conversation only — the same promise the
    /// scan path keeps, and the reason the gate needs the commitment's own chat.
    @MainActor
    func testChatScopedMuteSilencesOnlyThatChatsCommitment() async throws {
        let now = Date(timeIntervalSince1970: 5_200_000)
        var pushed: [String] = []
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        try store.ignoreSender(
            chatUsername: "chat-a", chatName: "A 群",
            senderUsername: "", senderName: "同事"
        )
        let engine = ProactiveAlertEngine(
            store: store, now: { now },
            sendNotification: { title, _, _, completion in
                pushed.append(title)
                completion(nil)
            }
        )
        func make(_ id: String, chat: String) -> Commitment {
            Commitment(id: 1, msgUID: id, chatUsername: chat, chatName: chat,
                       content: "发报告", commitTo: "同事", deadlineAt: now.addingTimeInterval(-60),
                       confidence: 0.9, status: .overdue, promptVersion: "v1", createdAt: now, updatedAt: now)
        }

        engine.evaluateCommitmentDeadlines(commitments: [
            make("in-a", chat: "chat-a"), make("in-b", chat: "chat-b"),
        ])
        await Task.yield()
        XCTAssertEqual(
            pushed, ["承诺已到期"],
            "chat-a is muted, chat-b is not — exactly one alert should survive"
        )
    }

    /// 设置 › 不再提醒某人 stores the person by wxid (`username:wxid…`), while a
    /// commitment carries only a model-extracted display name plus the chat it
    /// came from. The two identifier shapes never intersected, so the headline
    /// promise — 「选谁，就哪个对话都不再提醒」 — held for the inbox and not for
    /// that person's deadline alerts.
    @MainActor
    func testGlobalMuteByWxidSilencesThatPersonsCommitment() async throws {
        let now = Date(timeIntervalSince1970: 5_300_000)
        var titles: [String] = []
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        try store.ignoreSenderEverywhere(senderUsername: "wxid_tongshi", senderName: "同事")
        let engine = ProactiveAlertEngine(
            store: store, now: { now },
            sendNotification: { title, _, _, completion in
                titles.append(title)
                completion(nil)
            }
        )
        func make(_ id: String, chat: String, to person: String) -> Commitment {
            Commitment(id: 1, msgUID: id, chatUsername: chat, chatName: "聊天",
                       content: "发报告", commitTo: person, deadlineAt: now.addingTimeInterval(-60),
                       confidence: 0.9, status: .overdue, promptVersion: "v1", createdAt: now, updatedAt: now)
        }

        // commit_to is free text from the model, so it deliberately differs from
        // the contact name: only the conversation↔wxid bridge can match here.
        engine.evaluateCommitmentDeadlines(commitments: [make("muted", chat: "wxid_tongshi", to: "那位同事")])
        await Task.yield()
        XCTAssertEqual(titles, [], "a muted person's private-chat promise must stay silent")

        engine.evaluateCommitmentDeadlines(commitments: [make("loud", chat: "wxid_other", to: "那位同事")])
        await Task.yield()
        XCTAssertEqual(
            titles, ["承诺已到期"],
            "the same display name in a chat the user did not mute must still alert"
        )
    }

    func testCommitmentMuteMatcherNeedsBothSidesOfTheName() {
        func rule(_ username: String, _ name: String, global: Bool = true) -> IgnoredSenderRule {
            IgnoredSenderRule(
                chatUsername: global ? HUDStore.globalIgnoreScopeKey : "chat-a",
                chatName: "聊天",
                senderIdentifier: HUDStore.senderIdentifier(senderUsername: username, senderName: name),
                senderUsername: username, senderName: name,
                createdAt: Date(timeIntervalSince1970: 1),
                scope: global ? .global : .chat
            )
        }
        func commitment(_ chat: String, to person: String) -> Commitment {
            let when = Date(timeIntervalSince1970: 1_000)
            return Commitment(id: 1, msgUID: "m", chatUsername: chat, chatName: "聊天",
                              content: "发报告", commitTo: person, deadlineAt: when,
                              confidence: 0.9, status: .overdue, promptVersion: "v1",
                              createdAt: when, updatedAt: when)
        }

        // A nameless promise («给自己») must not be captured by a nameless rule.
        XCTAssertFalse(
            ProactiveAlertEngine.isMutedForCommitment(commitment("chat-b", to: ""), rules: [rule("", "")]),
            "empty == empty would mute every commitment off one malformed rule"
        )
        // Chat-scoped rules stay in their own conversation.
        XCTAssertFalse(ProactiveAlertEngine.isMutedForCommitment(
            commitment("chat-b", to: "同事"), rules: [rule("wxid_tongshi", "同事", global: false)]
        ))
        XCTAssertTrue(ProactiveAlertEngine.isMutedForCommitment(
            commitment("chat-a", to: "同事"), rules: [rule("wxid_tongshi", "同事", global: false)]
        ))
        // A commitment with neither a conversation nor a counterparty must not
        // be captured by a rule that has neither either: `senderIdentifier`
        // always prefixes, so both sides fold to the same sentinel.
        XCTAssertFalse(ProactiveAlertEngine.isMutedForCommitment(
            commitment("", to: ""), rules: [rule("", "")]
        ))
        XCTAssertFalse(ProactiveAlertEngine.isMutedForCommitment(
            commitment("", to: "同事"), rules: [rule("", "")]
        ))
    }
}
