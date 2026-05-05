import Foundation
import XCTest
@testable import WeChatHUD

final class DailyReportPresentationPolicyTests: XCTestCase {

    func testEmptyReportShowsQuietDay() {
        let report = makeReport(actions: [], risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        XCTAssertTrue(vm.progress.isQuietDay)
        XCTAssertEqual(vm.progress.completionRatio, 1.0)
        XCTAssertTrue(vm.urgentActions.isEmpty)
        XCTAssertTrue(vm.activeActions.isEmpty)
        XCTAssertTrue(vm.completedActions.isEmpty)
    }

    func testUrgentActionsSortedFirst() {
        let actions = [
            makeAction(content: "Low", urgency: .low),
            makeAction(content: "Critical", urgency: .critical),
            makeAction(content: "High", urgency: .high),
        ]
        let report = makeReport(actions: actions, risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        XCTAssertEqual(vm.urgentActions.count, 2)
        XCTAssertEqual(vm.urgentActions[0].content, "Critical")
        XCTAssertEqual(vm.urgentActions[1].content, "High")
        XCTAssertEqual(vm.activeActions.count, 1)
        XCTAssertEqual(vm.activeActions[0].content, "Low")
    }

    func testCompletedActionsExcludedFromActive() {
        let action = makeAction(content: "Todo", urgency: .high)
        let report = makeReport(actions: [action], risks: [], highlights: [])
        let state = DailyReportCommandState(
            dateKey: report.date.dailyReportDateKey,
            itemID: action.id,
            state: .completed,
            completedAt: Date()
        )
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report, commandStates: [state])

        XCTAssertTrue(vm.urgentActions.isEmpty)
        XCTAssertTrue(vm.activeActions.isEmpty)
        XCTAssertEqual(vm.completedActions.count, 1)
        XCTAssertEqual(vm.progress.completedCount, 1)
        XCTAssertEqual(vm.progress.completionRatio, 1.0)
    }

    func testDismissedRisksHidden() {
        let risk = DailyReportRisk(type: .overdueCommitment, description: "Test", severity: .high)
        let report = makeReport(actions: [], risks: [risk], highlights: [])
        let state = DailyReportCommandState(
            dateKey: report.date.dailyReportDateKey,
            itemID: risk.id,
            state: .dismissed,
            dismissedAt: Date()
        )
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report, commandStates: [state])

        XCTAssertTrue(vm.activeRisks.isEmpty)
        XCTAssertEqual(vm.dismissedRisks.count, 1)
    }

    func testSnoozedActionsHidden() {
        let action = makeAction(content: "Snoozed", urgency: .medium)
        let report = makeReport(actions: [action], risks: [], highlights: [])
        let state = DailyReportCommandState(
            dateKey: report.date.dailyReportDateKey,
            itemID: action.id,
            state: .snoozed,
            snoozedUntil: Date().addingTimeInterval(3600)
        )
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report, commandStates: [state])

        XCTAssertTrue(vm.urgentActions.isEmpty)
        XCTAssertTrue(vm.activeActions.isEmpty)
        XCTAssertTrue(vm.completedActions.isEmpty)
    }

    func testProgressMetrics() {
        let actions = [
            makeAction(content: "A", urgency: .critical),
            makeAction(content: "B", urgency: .high),
            makeAction(content: "C", urgency: .medium),
        ]
        let report = makeReport(actions: actions, risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        XCTAssertEqual(vm.progress.totalCount, 3)
        XCTAssertEqual(vm.progress.activeCount, 3)
        XCTAssertEqual(vm.progress.completedCount, 0)
        XCTAssertEqual(vm.progress.urgentCount, 2)
    }

    func testMarkdownExport() {
        let action = makeAction(content: "Send report", urgency: .high)
        let highlight = DailyReportHighlight(
            summary: "Decision made",
            category: .decision,
            sourceChatName: "Team",
            sourceChatUsername: "wxid_team",
            date: Date(),
            confidence: 0.9
        )
        let report = makeReport(
            actions: [action],
            risks: [],
            highlights: [highlight],
            narrative: "Good day",
            tomorrowFocus: "Send report",
            wechatDraft: "Draft text"
        )
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)
        let md = DailyReportPresentationPolicy.markdown(for: report, viewModel: vm)

        XCTAssertTrue(md.contains("# 日报"))
        XCTAssertTrue(md.contains("Send report"))
        XCTAssertTrue(md.contains("Decision made"))
        XCTAssertTrue(md.contains("Good day"))
        XCTAssertTrue(md.contains("Draft text"))
    }

    private func makeReport(
        actions: [DailyReportAction],
        risks: [DailyReportRisk],
        highlights: [DailyReportHighlight],
        narrative: String? = nil,
        tomorrowFocus: String? = nil,
        wechatDraft: String? = nil
    ) -> DailyReport {
        DailyReport(
            date: Date(),
            dateRange: (start: Date(), end: Date()),
            generatedAt: Date(),
            metrics: DailyReportMetrics(
                unreadMessageCount: 0,
                pendingTodoCount: 0,
                pendingAskCount: 0,
                pendingCommitmentCount: 0,
                overdueCommitmentCount: 0,
                replyDebtCount: 0,
                recalledMessageCount: 0,
                highlightCount: highlights.count,
                analyzedChatCount: 0
            ),
            highlights: highlights,
            actions: actions,
            risks: risks,
            pendingAsks: [],
            narrative: narrative,
            tomorrowFocus: tomorrowFocus,
            wechatDraft: wechatDraft
        )
    }

    private func makeAction(content: String, urgency: ActionUrgency, deadline: Date? = nil) -> DailyReportAction {
        DailyReportAction(
            content: content,
            type: .todo,
            urgency: urgency,
            deadline: deadline,
            sourceChatName: "Test",
            sourceChatUsername: "wxid_test",
            relatedID: UUID().uuidString
        )
    }

    func testActiveActionsBucketedByDeadline() {
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))!
        let inThreeDays = cal.date(byAdding: .day, value: 3, to: now)!
        let inTwentyDays = cal.date(byAdding: .day, value: 20, to: now)!

        let actions = [
            makeAction(content: "Today",     urgency: .medium, deadline: endOfToday),
            makeAction(content: "ThisWeek",  urgency: .medium, deadline: inThreeDays),
            makeAction(content: "Later",     urgency: .medium, deadline: inTwentyDays),
            makeAction(content: "NoDate",    urgency: .low,    deadline: nil),
            makeAction(content: "BoundaryWeek", urgency: .medium, deadline: endOfWeek),
            makeAction(content: "AfterToday",   urgency: .medium, deadline: cal.date(byAdding: .second, value: 1, to: endOfToday)!),
        ]
        let report = makeReport(actions: actions, risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        XCTAssertEqual(vm.activeToday.map(\.content),    ["Today"])
        XCTAssertEqual(vm.activeThisWeek.map(\.content), ["AfterToday", "ThisWeek", "BoundaryWeek"])
        XCTAssertEqual(Set(vm.activeLater.map(\.content)), ["Later", "NoDate"])
    }

    func testActiveActionsBackwardCompatField() {
        let cal = Calendar.current
        let inOneDay = cal.date(byAdding: .day, value: 1, to: Date())!
        let actions = [makeAction(content: "X", urgency: .medium, deadline: inOneDay)]
        let report = makeReport(actions: actions, risks: [], highlights: [])
        let vm = DailyReportPresentationPolicy.buildViewModel(from: report)

        // Existing callers reading vm.activeActions must still see the union.
        XCTAssertEqual(vm.activeActions.count, 1)
    }
}
