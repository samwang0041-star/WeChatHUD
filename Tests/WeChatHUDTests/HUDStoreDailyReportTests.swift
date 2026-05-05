import Foundation
import XCTest
@testable import WeChatHUD

final class HUDStoreDailyReportTests: XCTestCase {

    func testCommandStatePersistence() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let state = DailyReportCommandState(
            dateKey: "2026-05-05",
            itemID: "action-1",
            state: .completed,
            completedAt: Date()
        )
        try store.upsertDailyReportCommandState(state)

        let loaded = store.loadDailyReportCommandStates(dateKey: "2026-05-05")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].itemID, "action-1")
        XCTAssertEqual(loaded[0].state, .completed)
        XCTAssertNotNil(loaded[0].completedAt)
    }

    func testCommandStateOverwrite() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        try store.upsertDailyReportCommandState(DailyReportCommandState(
            dateKey: "2026-05-05", itemID: "x", state: .completed, completedAt: Date()
        ))
        try store.upsertDailyReportCommandState(DailyReportCommandState(
            dateKey: "2026-05-05", itemID: "x", state: .dismissed, dismissedAt: Date()
        ))

        let loaded = store.loadDailyReportCommandStates(dateKey: "2026-05-05")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].state, .dismissed)
    }

    func testClearCommandState() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        try store.upsertDailyReportCommandState(DailyReportCommandState(
            dateKey: "2026-05-05", itemID: "x", state: .completed
        ))
        try store.clearDailyReportCommandState(dateKey: "2026-05-05", itemID: "x")

        let loaded = store.loadDailyReportCommandStates(dateKey: "2026-05-05")
        XCTAssertTrue(loaded.isEmpty)
    }

    func testSnapshotSaveLoad() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let snapshot = DailyReportSnapshot(
            dateKey: "2026-05-05",
            dateStart: Date(),
            dateEnd: Date(),
            generatedAt: Date(),
            metrics: .init(
                unreadMessageCount: 5,
                pendingTodoCount: 2,
                pendingAskCount: 1,
                pendingCommitmentCount: 3,
                overdueCommitmentCount: 0,
                replyDebtCount: 4,
                recalledMessageCount: 0,
                highlightCount: 2,
                analyzedChatCount: 10
            ),
            highlightCount: 2,
            actionCount: 8,
            riskCount: 1,
            hasAIEnhancement: true,
            narrativePreview: "Good day",
            wechatDraftPreview: "Draft"
        )
        try store.saveDailyReportSnapshot(snapshot)

        let loaded = store.loadDailyReportSnapshot(dateKey: "2026-05-05")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.metrics.unreadMessageCount, 5)
        XCTAssertEqual(loaded?.hasAIEnhancement, true)
    }

    func testRecentSnapshotsOrdering() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        for day in ["2026-05-03", "2026-05-04", "2026-05-05"] {
            let snapshot = DailyReportSnapshot(
                dateKey: day,
                dateStart: Date(),
                dateEnd: Date(),
                generatedAt: Date(),
                metrics: .init(unreadMessageCount: 0, pendingTodoCount: 0, pendingAskCount: 0, pendingCommitmentCount: 0, overdueCommitmentCount: 0, replyDebtCount: 0, recalledMessageCount: 0, highlightCount: 0, analyzedChatCount: 0),
                highlightCount: 0,
                actionCount: 0,
                riskCount: 0,
                hasAIEnhancement: false,
                narrativePreview: nil,
                wechatDraftPreview: nil
            )
            try store.saveDailyReportSnapshot(snapshot)
        }

        let recent = store.recentDailyReportSnapshots(limit: 2)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].dateKey, "2026-05-05")
        XCTAssertEqual(recent[1].dateKey, "2026-05-04")
    }

    func testActionInsightRoundTrip() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let insight = DailyReportActionInsight(
            dateKey: "2026-05-05",
            actionID: "todo-42",
            reason: "客户今天 18 点要答复",
            nextStep: "回复确认时间并同步内部",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(insight)

        let loaded = store.loadActionInsights(dateKey: "2026-05-05")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].dateKey, insight.dateKey)
        XCTAssertEqual(loaded[0].actionID, insight.actionID)
        XCTAssertEqual(loaded[0].reason, insight.reason)
        XCTAssertEqual(loaded[0].nextStep, insight.nextStep)
        XCTAssertEqual(loaded[0].modelVersion, insight.modelVersion)
        XCTAssertEqual(Int(loaded[0].generatedAt.timeIntervalSince1970), Int(insight.generatedAt.timeIntervalSince1970))
    }

    func testActionInsightOverwrite() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        let v1 = DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "todo-1",
            reason: "old", nextStep: "old",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(v1)
        let v2 = DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "todo-1",
            reason: "new", nextStep: "new",
            modelVersion: "daily_report_action_insights_v1",
            generatedAt: Date()
        )
        try store.upsertActionInsight(v2)

        let loaded = store.loadActionInsights(dateKey: "2026-05-05")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].reason, "new")
    }

    func testActionInsightCrossDateIsolation() throws {
        let (store, path) = try makeTempStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        try store.upsertActionInsight(DailyReportActionInsight(
            dateKey: "2026-05-05", actionID: "x",
            reason: "a", nextStep: "b",
            modelVersion: "v1", generatedAt: Date()
        ))
        try store.upsertActionInsight(DailyReportActionInsight(
            dateKey: "2026-05-06", actionID: "x",
            reason: "c", nextStep: "d",
            modelVersion: "v1", generatedAt: Date()
        ))

        XCTAssertEqual(store.loadActionInsights(dateKey: "2026-05-05").count, 1)
        XCTAssertEqual(store.loadActionInsights(dateKey: "2026-05-06").count, 1)
        XCTAssertEqual(store.loadActionInsights(dateKey: "2026-05-07").count, 0)
    }

    private func makeTempStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "hud_store_dr_\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }
}
