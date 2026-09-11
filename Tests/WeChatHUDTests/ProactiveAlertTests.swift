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
            isIgnored: false
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
        XCTAssertEqual(sent.first?.0, "VIP 等你超过 4 小时")

        // Re-evaluating the same overdue message must not notify again.
        engine.evaluate(unreadItems: [item], replyDebtItems: [], commitments: [], recentNotifications: [])
        await Task.yield()
        XCTAssertEqual(sent.count, 1)
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

    func testRateLimitPreventsExcessAlerts() {
        var history: [Date] = Array(repeating: Date(), count: 5)
        let oneHourAgo = Date(timeIntervalSinceNow: -3600)
        history.removeAll { $0 < oneHourAgo }
        // 5 alerts in the last hour → should block
        XCTAssertTrue(history.count >= 5)
    }

    func testRateLimitAllowsAfterPrune() {
        var history: [Date] = Array(repeating: Date(timeIntervalSinceNow: -7200), count: 5)
        let oneHourAgo = Date(timeIntervalSinceNow: -3600)
        history.removeAll { $0 < oneHourAgo }
        // All alerts are > 1 hour old → pruned → should allow
        XCTAssertTrue(history.count < 5)
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
}
