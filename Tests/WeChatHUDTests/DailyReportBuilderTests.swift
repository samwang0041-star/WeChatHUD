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

    // MARK: - Build behavior

    func testBuildExcludesStaleRetrospectiveRunFromToday() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let yesterdayStart = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
        let yesterdayEnd = yesterdayStart.addingTimeInterval(3_600)
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: yesterdayStart, rangeEnd: yesterdayEnd, chatCount: 1))
        store.finalizeReviewRun(
            runID: runID,
            status: .completed,
            summaryTop3: [],
            summaryRisk: nil,
            summaryMissed: nil,
            msgCount: 1,
            failedChats: []
        )
        store.insertReviewHighlight(ReviewHighlight(
            id: 0,
            runID: runID,
            date: yesterdayEnd,
            summary: "昨天的项目高亮",
            quotedSnippet: nil,
            involved: [],
            sourceChatUsername: "wxid_old",
            sourceChatName: "旧会话",
            relation: .unknown,
            sourceMsgIDs: ["m1"],
            confidence: 0.9,
            category: .progress,
            flaggedUncertain: false
        ))
        store.insertReviewTodo(ReviewTodo(
            id: 0,
            originRunID: runID,
            lastRunID: runID,
            content: "昨天遗留的复盘待办",
            deadline: nil,
            direction: .mine,
            involved: [],
            sourceChatUsername: "wxid_old",
            sourceChatName: "旧会话",
            sourceMsgIDs: ["m2"],
            confidence: 0.9,
            status: .pending,
            createdAt: yesterdayEnd,
            completedAt: nil,
            snoozedTo: nil,
            delegatedTo: nil,
            carryCount: 0,
            lastUserActionAt: nil
        ))

        let report = DailyReportBuilder(store: store, replyDebtItems: [], stats: HUDStats()).build()

        XCTAssertNil(report.retrospectiveRunID)
        XCTAssertEqual(report.metrics.highlightCount, 0)
        XCTAssertEqual(report.metrics.pendingTodoCount, 0)
        XCTAssertTrue(report.highlights.isEmpty)
        XCTAssertFalse(report.actions.contains { $0.content.contains("昨天遗留") })
    }

    func testBuildUsesSameDayRetrospectiveRun() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: start, rangeEnd: now, chatCount: 2))
        store.finalizeReviewRun(
            runID: runID,
            status: .completed,
            summaryTop3: [],
            summaryRisk: nil,
            summaryMissed: nil,
            msgCount: 2,
            failedChats: []
        )
        store.insertReviewHighlight(ReviewHighlight(
            id: 0,
            runID: runID,
            date: now,
            summary: "今天确认上线窗口",
            quotedSnippet: "下午发版",
            involved: ["Alice"],
            sourceChatUsername: "wxid_today",
            sourceChatName: "项目群",
            relation: .peer,
            sourceMsgIDs: ["m3"],
            confidence: 0.91,
            category: .decision,
            flaggedUncertain: false
        ))
        store.insertReviewHighlight(ReviewHighlight(
            id: 0,
            runID: runID,
            date: start.addingTimeInterval(-60),
            summary: "昨天深夜的旧高亮",
            quotedSnippet: nil,
            involved: [],
            sourceChatUsername: "wxid_today",
            sourceChatName: "项目群",
            relation: .peer,
            sourceMsgIDs: ["m4"],
            confidence: 0.91,
            category: .progress,
            flaggedUncertain: false
        ))

        let report = DailyReportBuilder(store: store, replyDebtItems: [], stats: HUDStats()).build()

        XCTAssertEqual(report.retrospectiveRunID, runID)
        XCTAssertEqual(report.metrics.highlightCount, 1)
        XCTAssertEqual(report.highlights.first?.summary, "今天确认上线窗口")
        XCTAssertFalse(report.highlights.contains { $0.summary.contains("旧高亮") })
        XCTAssertTrue(report.narrative?.contains("今日高亮 1 条") == true)
    }

    func testBuildCreatesReadableLocalFallbackFromLocalSignals() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let now = Date()
        try store.upsertPendingAsk(PendingAsk(
            id: 0,
            msgUID: "ask-local-1",
            chatUsername: "wxid_boss",
            chatName: "林总",
            senderName: "林总",
            rawText: "今天把预算单发我",
            summary: "发送预算单",
            askType: .sendFile,
            deadlineAt: now.addingTimeInterval(3_600),
            confidence: 0.9,
            bucket: .main,
            status: .pending,
            promptVersion: "test",
            createdAt: now,
            updatedAt: now,
            senderLevel: nil,
            senderRole: nil,
            urgency: nil
        ))
        try store.upsertCommitment(
            msgUID: "commit-local-1",
            chatUsername: "wxid_pm",
            chatName: "PM",
            content: "补一版排期",
            commitTo: "PM",
            deadlineAt: now.addingTimeInterval(7_200),
            confidence: 0.92,
            promptVersion: "test"
        )
        var stats = HUDStats()
        stats.unreadCount = 3

        let report = DailyReportBuilder(store: store, replyDebtItems: [], stats: stats).build()

        XCTAssertEqual(report.status, .localOnly)
        XCTAssertEqual(report.metrics.unreadMessageCount, 3)
        XCTAssertEqual(report.metrics.pendingAskCount, 1)
        XCTAssertEqual(report.metrics.pendingCommitmentCount, 1)
        XCTAssertTrue(report.actions.contains { $0.type == .ask && $0.content == "发送预算单" })
        XCTAssertTrue(report.actions.contains { $0.type == .commitment && $0.content == "补一版排期" })
        XCTAssertFalse(report.narrative?.isEmpty ?? true)
        XCTAssertFalse(report.tomorrowFocus?.isEmpty ?? true)
        XCTAssertFalse(report.wechatDraft?.isEmpty ?? true)
        XCTAssertTrue(report.wechatDraft?.contains("工作小结") == true)
    }

    func testBuildCreatesQuietDayFallbackWhenNoSignalsExist() {
        let (store, path) = try! makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let report = DailyReportBuilder(store: store, replyDebtItems: [], stats: HUDStats()).build()

        XCTAssertEqual(report.status, .localOnly)
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(report.highlights.isEmpty)
        XCTAssertTrue(report.narrative?.contains("暂无需要处理") == true)
        XCTAssertTrue(report.wechatDraft?.contains("暂无待处理事项") == true)
    }

    private func makeTempStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "daily_report_builder_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }
}
