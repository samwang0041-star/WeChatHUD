import XCTest
import AppKit
import Foundation
@testable import WeChatHUD

/// The island the user sees is a compositor mask inside a grow-only window, so
/// a frame spring that never runs is not a cosmetic problem — it parks the mask
/// on the rect the run started from and the panel paints as a black plate the
/// size of that rect.
///
/// This is the shape of the "点了 在微信中打开 之后页面就卡成一块黑板" report:
/// the WeChat hand-off orders the panel out, `collapseAndYield` swaps the state
/// to `.compact`, and the state sink answered with a frame spring. A spring on
/// an ordered-out panel cannot tick, so it froze at the *expanded* rect, and
/// `positionAtTop` re-anchored that same oversized island when the panel came
/// back. The inbox was still mounted inside it — a short list on a tall black
/// plate, exactly as the screenshot shows.
@MainActor
final class IslandFrameVisibilityTests: XCTestCase {

    // MARK: - The rule

    func testHiddenPanelLandsInsteadOfStartingASpring() {
        XCTAssertTrue(
            IslandMeasurement.landsWithoutMotion(
                reduceMotion: false,
                isDisplayable: false,
                from: CGSize(width: 560, height: 482),
                to: CGSize(width: 128, height: 32)
            ),
            "隐藏的面板不能起 spring：显示链接不会 fire，run 会冻在起始 rect 上"
        )
    }

    func testVisiblePanelStillAnimates() {
        XCTAssertFalse(
            IslandMeasurement.landsWithoutMotion(
                reduceMotion: false,
                isDisplayable: true,
                from: CGSize(width: 560, height: 482),
                to: CGSize(width: 128, height: 32)
            ),
            "可见的面板照常起 spring——修复的是隐藏路径，不是把动效关掉"
        )
    }

    func testReduceMotionAndZeroTravelStillLand() {
        let size = CGSize(width: 560, height: 482)
        XCTAssertTrue(IslandMeasurement.landsWithoutMotion(
            reduceMotion: true, isDisplayable: true, from: size, to: CGSize(width: 128, height: 32)
        ))
        XCTAssertTrue(IslandMeasurement.landsWithoutMotion(
            reduceMotion: false, isDisplayable: true, from: size, to: size
        ))
    }

    // MARK: - The panel

    /// Walks the hand-off the way the app does it: order out, collapse, then
    /// re-anchor on the way back in.
    ///
    /// The panel is never ordered *front* here. The mask is the thing under
    /// test and ordering front does not touch it, so the assertions are the
    /// same — and a test has no business putting a window on someone's screen.
    func testCollapseWhileHiddenLeavesTheIslandTheStateOwns() {
        let panel = FloatingPanel(contentView: NSView())
        defer { panel.orderOut(nil) }

        panel.setFrameInstantly(height: 482, width: 560)
        XCTAssertEqual(panel.visibleIslandFrame?.size, CGSize(width: 560, height: 482))

        panel.orderOut(nil)
        XCTAssertFalse(panel.canDisplayFrameAnimation)
        panel.animateHeight(to: 32, width: 128, caller: "IslandFrameVisibilityTests")

        XCTAssertFalse(
            panel.isFrameAnimationRunning,
            "隐藏时不能留下一个永远走不完的 run"
        )
        XCTAssertEqual(
            panel.visibleIslandFrame?.size, CGSize(width: 128, height: 32),
            "collapse 必须立刻落到 compact 岛上，否则恢复显示时 mask 还是旧的大矩形"
        )

        // What `restoreHUDAfterWeChatAutomation` does next. Before the fix this
        // re-anchored the frozen 560×482 rect and revealed the whole stage.
        panel.positionAtTop()
        XCTAssertEqual(
            panel.visibleIslandFrame?.size, CGSize(width: 128, height: 32),
            "重新贴顶不能把陈旧的大矩形重新anchoring成可见岛"
        )
    }

    /// The stage only ever grows, so the window frame is not the island. A
    /// collapse out of an expanded state has to shrink the mask even though the
    /// window keeps its size.
    func testCollapseShrinksTheMaskWithoutShrinkingTheStage() {
        let panel = FloatingPanel(contentView: NSView())
        defer { panel.orderOut(nil) }

        panel.setFrameInstantly(height: 482, width: 560)
        panel.orderOut(nil)
        panel.animateHeight(to: 32, width: 128, caller: "IslandFrameVisibilityTests")

        XCTAssertEqual(
            panel.visibleIslandFrame?.size, CGSize(width: 128, height: 32),
            "窗口可以留在 stage 尺寸，可见岛必须是 compact"
        )
        XCTAssertGreaterThanOrEqual(
            panel.frame.height, 482,
            "stage 是只增不减的：收起靠 mask，不靠缩窗口"
        )
    }

    /// `landsWithoutMotion` covers the panel that is ordered out. It cannot
    /// cover a panel that is on screen and still gets no vsync — an occluded
    /// stage, a sleeping display, a headless capture session. There the run
    /// starts, no tick ever arrives, and the wedge cap that ends runs lives
    /// *inside* the tick handler, so the mask stays on the pre-expand pill
    /// while the window sits at the covering stage: an expanded island with
    /// nothing visible in it. The deadline has to exist independently of frames.
    func testFrameRunHasAnExitThatDoesNotNeedFrames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/App/FloatingPanel.swift"),
            encoding: .utf8
        )

        // The definition itself contains that name, so "is it mentioned" is
        // vacuous. Exactly two sites: the declaration and the one call that arms
        // it for every run.
        let arms = source.components(separatedBy: "armFrameAnimationWatchdog()").count - 1
        XCTAssertEqual(arms, 2, "声明之外必须真的有一处调用，否则每次 run 没有挂上最后期限")
        let watchdog = source.range(of: "private func armFrameAnimationWatchdog")
            .map { String(source[$0.lowerBound...]) } ?? ""
        XCTAssertTrue(watchdog.contains("IslandMotion.maxRunDuration"),
                      "最后期限必须和楔死上限同源，不能各写一个时长")
        XCTAssertTrue(watchdog.contains("finishFrameAnimation()"),
                      "最后期限要真的把 run 收尾，而不是只清状态")
        let invalidations = source.components(separatedBy: "animationWatchdog?.invalidate()").count - 1
        // finishFrameAnimation + cancelFrameAnimation; the third is `arm`
        // clearing a previous run's deadline before it sets a new one.
        XCTAssertGreaterThanOrEqual(invalidations, 2, "两条出口（自然结束 / 取消）都要撤掉看门狗")
    }

    /// A display link that never ticks is not a slow animation, it is no
    /// animation. The deadline added above makes such a run *end*, but ending
    /// after 2.55 s of nothing is a dead pause, not a reveal: every capture
    /// session and every Mac with the display asleep ran the island that way.
    /// The run has to notice the starvation within a vsync pair and keep
    /// moving on the runloop clock.
    func testStarvedDisplayLinkIsSwitchedToADriverThatTicks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/App/FloatingPanel.swift"),
            encoding: .utf8
        )

        let arms = source.components(separatedBy: "armFrameDriverProbe()").count - 1
        XCTAssertEqual(arms, 2, "探针必须真的挂在每次起架上：声明之外还要有一处调用")

        let probe = source.range(of: "private func armFrameDriverProbe")
            .map { String(source[$0.lowerBound...].prefix(900)) } ?? ""
        XCTAssertTrue(probe.contains("ticksForCurrentRun == 0"),
                      "已经 tick 过的链接不能被撤下：那样会把正常的 120 Hz 动画降级成 timer")
        XCTAssertTrue(probe.contains("installTimerFrameDriver()"),
                      "降级要真的换一个会 fire 的驱动，而不是只记一条日志")

        // A live link has to disarm the probe, or a link that wakes up late
        // would run the timer and the link against the same spring.
        let linkTick = source.range(of: "private func stepFrameAnimation(_ link: CADisplayLink)")
            .map { String(source[$0.lowerBound...].prefix(700)) } ?? ""
        XCTAssertTrue(linkTick.contains("animationDriverProbe"),
                      "链接的第一帧必须撤掉降级探针")
        guard let probeOff = linkTick.range(of: "animationDriverProbe?.invalidate()"),
              let step = linkTick.range(of: "stepFrameAnimation(at:") else {
            XCTFail("链接步进里既找不到撤探针，也找不到步进调用")
            return
        }
        XCTAssertLessThan(probeOff.upperBound, step.lowerBound,
                          "撤探针要在步进之前：步进会改写本轮状态，晚撤等于让探针看见半帧")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "animationDriverProbe?.invalidate()").count - 1, 4,
            "起架、降级、结束、取消四条路都要撤探针"
        )
    }

    /// The frame samples run *through* a retarget — the spring keeps its
    /// velocity and the tick loop is never restarted — so a duration measured
    /// from the retarget clock describes a different span than the samples
    /// beside it. A hover reveal (pill widen, then bend to the inbox) reported
    /// 0.34 s carrying 0.67 s of frames, and `fps` disagreed with both.
    func testTickCountSeesTheFrameTheIntervalRecorderMisses() {
        IslandFrameTiming.begin()
        XCTAssertEqual(IslandFrameTiming.ticksForCurrentRun, 0)
        IslandFrameTiming.tick(uptime: 100)
        XCTAssertEqual(
            IslandFrameTiming.ticksForCurrentRun, 1,
            "第一帧只写下 previousUptime，还没有 interval；读 samples 会把「链接活着」当成饿死"
        )
        XCTAssertTrue(IslandFrameTiming.lastIntervals.isEmpty,
                      "一个 tick 不构成一个 interval")
        IslandFrameTiming.tick(uptime: 100.0166)
        XCTAssertEqual(IslandFrameTiming.ticksForCurrentRun, 2)
    }

    func testRunDurationIsMeasuredFromTheMotionNotTheLastLeg() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/App/FloatingPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("IslandFrameTiming.finish(duration: Date().timeIntervalSince(run.motionStartedWallClock))"),
            "上报时长必须从运动起点量，和样本同源"
        )
        XCTAssertTrue(
            source.contains("Date().timeIntervalSince(run.startedWallClock) > IslandMotion.maxRunDuration"),
            "楔死上限仍要按最后一段算，否则一次正常重定向就能把健康 run 掐断"
        )
        let retarget = source.range(of: "if var run = animationRun {")
            .map { String(source[$0.lowerBound...].prefix(900)) } ?? ""
        XCTAssertTrue(retarget.contains("run.startedWallClock = Date()"))
        XCTAssertFalse(retarget.contains("motionStartedWallClock ="),
                       "重定向段不许刷新运动起点：那正是这次测错的来源")
    }
}
