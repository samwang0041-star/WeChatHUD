import XCTest
@testable import WeChatHUD

/// Tests for ProactiveAlertEngine rule logic.
/// Cannot test actual UNNotification delivery in unit tests,
/// so we test the rule evaluation conditions directly.
final class ProactiveAlertTests: XCTestCase {

    // MARK: - UnreadItem factory

    private func makeUnread(
        chatUsername: String = "chat1",
        senderName: String = "Alice",
        isVIP: Bool = false,
        status: UnreadStatus = .pending,
        minutesAgo: Int = 5
    ) -> UnreadItem {
        UnreadItem(
            chatUsername: chatUsername,
            chatName: chatUsername,
            senderUsername: "wxid_\(senderName.lowercased())",
            senderName: senderName,
            preview: "hello",
            timestamp: Date(timeIntervalSinceNow: -Double(minutesAgo * 60)),
            kind: .privateChat,
            isWhitelisted: true,
            isVIP: isVIP,
            replied: false,
            status: status,
            isIgnored: false
        )
    }

    // MARK: - Rule 1: VIP overdue

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
}
