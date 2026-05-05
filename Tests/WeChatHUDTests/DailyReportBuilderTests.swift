import Foundation
import XCTest
@testable import WeChatHUD

final class DailyReportBuilderTests: XCTestCase {

    // MARK: - ActionUrgency

    func testActionUrgencyComparable() {
        XCTAssertTrue(ActionUrgency.critical < ActionUrgency.high)
        XCTAssertTrue(ActionUrgency.high < ActionUrgency.medium)
        XCTAssertTrue(ActionUrgency.medium < ActionUrgency.low)
    }

    func testRiskSeverityComparable() {
        XCTAssertTrue(RiskSeverity.high < RiskSeverity.medium)
        XCTAssertTrue(RiskSeverity.medium < RiskSeverity.low)
    }

    // MARK: - DailyReport model

    func testDailyReportModelCreation() {
        let now = Date()
        let metrics = DailyReportMetrics(
            unreadMessageCount: 5,
            pendingTodoCount: 2,
            pendingAskCount: 1,
            pendingCommitmentCount: 3,
            overdueCommitmentCount: 1,
            replyDebtCount: 4,
            recalledMessageCount: 0,
            highlightCount: 2,
            analyzedChatCount: 10
        )

        let report = DailyReport(
            date: now,
            dateRange: (start: now, end: now),
            generatedAt: now,
            metrics: metrics,
            highlights: [],
            actions: [],
            risks: [],
            pendingAsks: [],
            narrative: nil,
            tomorrowFocus: nil,
            wechatDraft: nil
        )

        XCTAssertEqual(report.metrics.unreadMessageCount, 5)
        XCTAssertEqual(report.metrics.pendingTodoCount, 2)
        XCTAssertEqual(report.metrics.pendingCommitmentCount, 3)
        XCTAssertEqual(report.metrics.overdueCommitmentCount, 1)
        XCTAssertTrue(report.highlights.isEmpty)
    }

    func testDailyReportHighlightCreation() {
        let highlight = DailyReportHighlight(
            summary: "Test decision",
            category: .decision,
            sourceChatName: "Team Chat",
            sourceChatUsername: "wxid_123",
            date: Date(),
            confidence: 0.92,
            quotedSnippet: "Let's go with option A",
            involved: ["Alice", "Bob"]
        )

        XCTAssertEqual(highlight.summary, "Test decision")
        XCTAssertEqual(highlight.category, .decision)
        XCTAssertEqual(highlight.confidence, 0.92, accuracy: 0.01)
    }

    func testDailyReportActionCreation() {
        let action = DailyReportAction(
            content: "Follow up with client",
            type: .todo,
            urgency: .high,
            deadline: Date().addingTimeInterval(3600),
            sourceChatName: "Client Chat",
            sourceChatUsername: "wxid_client",
            relatedID: "123"
        )

        XCTAssertEqual(action.type, .todo)
        XCTAssertEqual(action.urgency, .high)
        XCTAssertNotNil(action.deadline)
    }

    func testDailyReportRiskCreation() {
        let risk = DailyReportRisk(
            type: .overdueCommitment,
            description: "Promise overdue",
            severity: .high,
            sourceChatName: "Boss",
            sourceChatUsername: "wxid_boss"
        )

        XCTAssertEqual(risk.type, .overdueCommitment)
        XCTAssertEqual(risk.severity, .high)
    }

    // MARK: - Sendable conformance (compile-time check)

    func testSendableConformance() {
        // These should compile only if all types are Sendable
        let _: any Sendable = DailyReportMetrics(
            unreadMessageCount: 0, pendingTodoCount: 0,
            pendingAskCount: 0, pendingCommitmentCount: 0,
            overdueCommitmentCount: 0, replyDebtCount: 0,
            recalledMessageCount: 0, highlightCount: 0,
            analyzedChatCount: 0
        )
        let _: any Sendable = DailyReportHighlight(
            summary: "", category: .discussion,
            sourceChatName: "", sourceChatUsername: "",
            date: Date(), confidence: 0, quotedSnippet: nil, involved: []
        )
        let _: any Sendable = DailyReportAction(
            content: "", type: .todo, urgency: .low,
            deadline: nil, sourceChatName: "",
            sourceChatUsername: "", relatedID: ""
        )
        let _: any Sendable = DailyReportRisk(
            type: .recalledMessage, description: "",
            severity: .low, sourceChatName: nil, sourceChatUsername: nil
        )
    }
}
