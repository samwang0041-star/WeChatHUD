import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// The context-briefing card's failure state.
///
/// The AI call behind the card fails on its own (no endpoint, rate limit, a
/// timeout), and the monitor has always been able to re-ask with
/// `forceRefresh: true` — but nothing on screen called it, so the error card
/// was a paragraph with no way forward.
@MainActor
final class BriefingRetryTests: XCTestCase {

    /// The stale-briefing case the retry button actually renders in: a briefing
    /// is cached *and* the last refresh failed. A plain load refuses to do
    /// anything here, which is exactly why the button has to force.
    func testRetryAsksAgainEvenThoughAPlainLoadIsRefusedWhileABriefingIsCached() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = groupNotification()
        fixture.monitor.groupContextStates[notification.briefingKey] = GroupContextBriefingLoadState(
            briefing: Self.staleBriefing(),
            isLoading: false,
            errorMessage: "上次没取到",
            updatedAt: Date()
        )

        fixture.monitor.loadGroupContextBriefing(for: notification)
        let refused = fixture.monitor.groupContextState(for: notification)
        XCTAssertFalse(refused.isLoading, "缓存还在时普通 load 必须是 no-op")
        XCTAssertEqual(refused.errorMessage, "上次没取到", "no-op 不该清掉上次的错误")

        BriefingRetryAction.perform(fixture.monitor, notification: notification)

        let retrying = fixture.monitor.groupContextState(for: notification)
        XCTAssertTrue(retrying.isLoading, "重试必须真的再问一次 AI")
        XCTAssertNotNil(retrying.briefing, "刷新期间旧简报继续显示，卡片不能空掉")
        XCTAssertEqual(retrying.briefing?.situation, Self.staleBriefing().situation)
    }

    /// The card's error branch only renders when a briefing exists, so the button
    /// has to be reachable in that state — and its label is the word the user
    /// reads.
    func testRetryAffordanceIsTheWordTheCardShows() {
        XCTAssertEqual(BriefingRetryAction.label, "重试")
    }

    func testTheErrorCardStillRendersWithItsRetryAffordance() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = groupNotification()
        fixture.monitor.groupContextStates[notification.briefingKey] = GroupContextBriefingLoadState(
            briefing: Self.staleBriefing(),
            isLoading: false,
            errorMessage: "上次没取到",
            updatedAt: Date()
        )
        let card = GroupContextBriefingCard(notification: notification)
            .environmentObject(fixture.monitor)
            .environmentObject(fixture.panelState)

        let height = measuredHeight(of: card, width: 552)

        XCTAssertGreaterThan(height, 0, "错误态也要真的画出内容")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: HUDStore
        let monitor: ChatMonitor
        let panelState: PanelState
        let root: String
    }

    private func makeFixture() throws -> Fixture {
        let root = NSTemporaryDirectory() + "briefing-retry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        return Fixture(store: store, monitor: monitor, panelState: PanelState(), root: root)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.store.close()
        try? FileManager.default.removeItem(atPath: fixture.root)
    }

    private func groupNotification() -> HUDNotification {
        HUDNotification(
            chatUsername: "wxid-briefing-retry",
            chatName: "项目协作群",
            senderUsername: "wxid-peer",
            senderName: "林晓",
            attentionLevel: .vip,
            messageID: "briefing-retry-\(UUID().uuidString)",
            rawText: "@我 明天下午评审能否确认责任人的展示方案？",
            snippet: "明天下午评审能否确认责任人的展示方案？",
            isAtMention: true,
            timestamp: Date(),
            kind: .groupAt
        )
    }

    private static func staleBriefing() -> GroupContextBriefing {
        GroupContextBriefing(
            situation: "大家在确认评审安排。",
            whyMentioned: "需要你确认责任人展示方案。",
            currentStatus: "还在等你回复。",
            nextStep: "在群里确认方案。",
            participants: ["林晓"],
            confidence: 0.8,
            source: .ai,
            generatedAt: Date()
        )
    }

    @discardableResult
    private func measuredHeight(of view: some View, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.frame(width: width))
        controller.sizingOptions = [.intrinsicContentSize]
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        host.layoutSubtreeIfNeeded()
        host.updateConstraintsForSubtreeIfNeeded()
        let height = host.intrinsicContentSize.height
        XCTAssertTrue(height.isFinite, "错误卡片的高度必须是有限值，实际 \(height)")
        return height
    }
}
