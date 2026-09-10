import XCTest
@testable import WeChatHUD

final class CompactIslandPolicyTests: XCTestCase {
    func testConnectionProblemBeatsInboxAndAI() {
        let snap = CompactIslandPolicy.snapshot(input(
            sync: .waitingForWeChat,
            actions: [item(priority: .p0)],
            aiActive: true
        ))
        XCTAssertEqual(snap.phase, .connectionProblem)
        XCTAssertEqual(snap.mark, .warning)
        XCTAssertEqual(snap.buddy, .error)
        XCTAssertNil(snap.badge)
        XCTAssertEqual(snap.glow, .none)
    }

    func testP0UrgentBeatsAIAndShowsCountWithoutSparkles() {
        let snap = CompactIslandPolicy.snapshot(input(
            actions: [item(priority: .p0), item(priority: .p1), item(priority: .p2)],
            aiActive: true
        ))
        XCTAssertEqual(snap.phase, .urgent(priority: .p0, count: 3))
        XCTAssertEqual(snap.mark, .dot(.urgentP0))
        XCTAssertEqual(snap.badge, "3")
        XCTAssertEqual(snap.buddy, .urgent)
        if case .dot(.urgentP0) = snap.mark { } else {
            XCTFail("urgent P0 must be a single red dot, not a stacked mark")
        }
    }

    func testP1IsAmberWaitingBuddyNotJumping() {
        let snap = CompactIslandPolicy.snapshot(input(actions: [item(priority: .p1)]))
        XCTAssertEqual(snap.phase, .urgent(priority: .p1, count: 1))
        XCTAssertEqual(snap.mark, .dot(.urgentP1))
        XCTAssertNil(snap.badge)
        XCTAssertEqual(snap.buddy, .pending)
    }

    func testAIWorkReplacesPendingDotAndSparkleStack() {
        let snap = CompactIslandPolicy.snapshot(input(
            actions: [item(priority: .p2)],
            aiActive: true
        ))
        XCTAssertEqual(snap.phase, .working(.analyzing))
        XCTAssertEqual(snap.mark, .dot(.working))
        XCTAssertNil(snap.badge)
        XCTAssertEqual(snap.buddy, .analyzing)
    }

    func testSyncingDoesNotHideWaitingCount() {
        let snap = CompactIslandPolicy.snapshot(input(
            sync: .syncing,
            actions: [item(priority: .p2), item(priority: .p2)]
        ))
        XCTAssertEqual(snap.phase, .waiting(count: 2))
        XCTAssertEqual(snap.mark, .dot(.waiting))
        XCTAssertEqual(snap.badge, "2")
        XCTAssertEqual(snap.buddy, .pending)
    }

    func testWaitingShowsOneMutedDotAndCount() {
        let snap = CompactIslandPolicy.snapshot(input(
            actions: [item(priority: .p2), item(priority: .p2)]
        ))
        XCTAssertEqual(snap.phase, .waiting(count: 2))
        XCTAssertEqual(snap.mark, .dot(.waiting))
        XCTAssertEqual(snap.badge, "2")
        XCTAssertEqual(snap.buddy, .pending)
    }

    func testNoticesStayQuieterThanWaiting() {
        let snap = CompactIslandPolicy.snapshot(input(noticeCount: 2))
        XCTAssertEqual(snap.phase, .notices(count: 2))
        XCTAssertEqual(snap.mark, .dot(.notices))
        XCTAssertEqual(snap.badge, "2")
        XCTAssertEqual(snap.buddy, .idle)
    }

    func testQuietSleepyAndAutopilotOnlyChangeTheBuddy() {
        let quiet = CompactIslandPolicy.snapshot(input())
        XCTAssertEqual(quiet.phase, .quiet(sleepy: false))
        XCTAssertEqual(quiet.mark, .dot(.quiet))
        XCTAssertEqual(quiet.buddy, .idle)

        let sleepy = CompactIslandPolicy.snapshot(input(idleMinutes: 5))
        XCTAssertEqual(sleepy.phase, .quiet(sleepy: true))
        XCTAssertEqual(sleepy.buddy, .sleepy)
        XCTAssertEqual(sleepy.mark, .dot(.quiet))

        let auto = CompactIslandPolicy.snapshot(input(autopilotActive: true, idleMinutes: 5))
        XCTAssertEqual(auto.phase, .quiet(sleepy: true))
        XCTAssertEqual(auto.buddy, .autopiloting)
        XCTAssertEqual(auto.mark, .dot(.quiet))
    }

    func testAutopilotDoesNotHideWaitingCount() {
        let snap = CompactIslandPolicy.snapshot(input(
            actions: [item(priority: .p2)],
            autopilotActive: true
        ))
        XCTAssertEqual(snap.phase, .waiting(count: 1))
        XCTAssertEqual(snap.mark, .dot(.waiting))
        XCTAssertEqual(snap.buddy, .autopiloting)
    }

    func testVIPGlowOnlyOnUrgentAction() {
        let urgent = CompactIslandPolicy.snapshot(input(
            actions: [item(priority: .p0, isVIP: true, isOverdue: true)],
            worstVIPTier: .t3
        ))
        XCTAssertEqual(urgent.glow, .critical)

        let waiting = CompactIslandPolicy.snapshot(input(
            actions: [item(priority: .p2, isVIP: true)],
            worstVIPTier: .t3
        ))
        XCTAssertEqual(waiting.glow, .none)
    }

    func testSpokenLineNamesTheDominantFact() {
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(sync: .error("x"))).spoken.contains("连不上"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p0)])).spoken.contains("尽快"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(aiActive: true)).spoken.contains("AI"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p2), item(priority: .p2)])).spoken.contains("2"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input()).spoken.contains("暂无"))
    }

    private func input(
        sync: SyncStatus = .ok,
        actions: [CompactIslandAction] = [],
        noticeCount: Int = 0,
        aiActive: Bool = false,
        autopilotActive: Bool = false,
        idleMinutes: Int = 0,
        worstVIPTier: VIPAlertTier = .none
    ) -> CompactIslandInput {
        CompactIslandInput(
            sync: sync,
            actions: actions,
            noticeCount: noticeCount,
            aiActive: aiActive,
            autopilotActive: autopilotActive,
            idleMinutes: idleMinutes,
            worstVIPTier: worstVIPTier
        )
    }

    private func item(
        priority: InboxPriority,
        isVIP: Bool = false,
        isOverdue: Bool = false
    ) -> CompactIslandAction {
        CompactIslandAction(priority: priority, isVIP: isVIP, isOverdue: isOverdue)
    }
}
