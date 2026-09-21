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

    func testGlanceIsShortAndHasNoHoverHint() {
        XCTAssertEqual(CompactIslandPolicy.snapshot(input(sync: .error("x"))).glance, "微信连不上")
        XCTAssertEqual(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p0)])).glance, "1 条急事")
        XCTAssertEqual(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p1)])).glance, "1 条待回")
        XCTAssertEqual(CompactIslandPolicy.snapshot(input(aiActive: true)).glance, "AI 在整理")
        XCTAssertEqual(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p2), item(priority: .p2)])).glance, "2 条待处理")
        XCTAssertEqual(CompactIslandPolicy.snapshot(input(noticeCount: 2)).glance, "2 条群消息")
        XCTAssertEqual(CompactIslandPolicy.snapshot(input()).glance, "没有待处理")
        XCTAssertFalse(CompactIslandPolicy.snapshot(input()).glance.contains("移入"))
    }

    /// The peek pill is 78 pt wide with 20 pt of padding, and `islandMicro()`
    /// is 10.5 pt: "9+ 条群消息" measures ~56 pt, and anything longer only
    /// fits by shrinking, which reads as a different control. The count
    /// phases also share one shape (`N 条X`): a number after a separator
    /// ("紧急 · 1") is a label code, a number before a classifier is a
    /// sentence, and mixing the two across states reads as two products.
    func testGlanceFitsThePeekSlotAndSharesOneCountShape() {
        let cases: [CompactIslandInput] = [
            input(sync: .error("x")),
            input(actions: [item(priority: .p0)]),
            input(actions: [item(priority: .p1), item(priority: .p1)]),
            input(aiActive: true),
            input(actions: [item(priority: .p2)]),
            input(noticeCount: 12),
            input(),
        ]
        for subject in cases {
            let glance = CompactIslandPolicy.snapshot(subject).glance
            XCTAssertLessThanOrEqual(glance.count, 7, "\(glance) 超出 peek 槽的字数预算")
            XCTAssertFalse(glance.contains("·"), "\(glance) 用了分隔符而不是句子")
        }
        for subject in [input(actions: [item(priority: .p0)]), input(actions: [item(priority: .p1)]),
                        input(actions: [item(priority: .p2)]), input(noticeCount: 3)] {
            let glance = CompactIslandPolicy.snapshot(subject).glance
            XCTAssertTrue(glance.hasPrefix("1 ") || glance.hasPrefix("2 ") || glance.hasPrefix("3 ")
                          || glance.hasPrefix("9+"), "\(glance) 应以数量开头")
            XCTAssertTrue(glance.contains("条"), "\(glance) 应带量词「条」")
        }
    }

    func testSpokenLineNamesTheDominantFact() {
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(sync: .error("x"))).spoken.contains("连不上"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p0)])).spoken.contains("急事"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(aiActive: true)).spoken.contains("AI"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input(actions: [item(priority: .p2), item(priority: .p2)])).spoken.contains("2"))
        XCTAssertTrue(CompactIslandPolicy.snapshot(input()).spoken.contains("没有要处理"))
    }

    /// `spoken` is a VoiceOver value on a button whose label already says
    /// what the click does — it must not also carry pointer instructions or
    /// the collapsed state of a disclosure control.
    func testSpokenLineCarriesNoPointerInstructionsOrDisclosureWords() {
        let cases: [CompactIslandInput] = [
            input(sync: .error("x")),
            input(actions: [item(priority: .p0)]),
            input(actions: [item(priority: .p1)]),
            input(aiActive: true),
            input(actions: [item(priority: .p2)]),
            input(noticeCount: 3),
            input(),
        ]
        for subject in cases {
            let spoken = CompactIslandPolicy.snapshot(subject).spoken
            for leaked in ["移入", "悬停", "收起", "工作台", "项待处理"] {
                XCTAssertFalse(spoken.contains(leaked), "\(spoken) 泄漏了 \(leaked)")
            }
            XCTAssertTrue(spoken.hasSuffix("。"), "\(spoken) 应是完整一句")
        }
    }

    func testSpokenCountCapsAtNinePlusLikeTheBadge() {
        let snap = CompactIslandPolicy.snapshot(input(
            actions: Array(repeating: item(priority: .p0), count: 21)
        ))
        XCTAssertEqual(snap.badge, "9+")
        XCTAssertTrue(snap.spoken.contains("9+"))
        XCTAssertFalse(snap.spoken.contains("10"))
        XCTAssertFalse(snap.spoken.contains("21"))
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
