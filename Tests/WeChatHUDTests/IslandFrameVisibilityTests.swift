import XCTest
import AppKit
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
}
