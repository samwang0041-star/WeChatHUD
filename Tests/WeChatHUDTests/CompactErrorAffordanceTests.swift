import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// The compact island's failure affordance.
///
/// Every island phase used to send the left wing to the inbox. With WeChat
/// unreachable that opens a page which has nothing to show and no route to the
/// 微信连接 settings that explain why, so the wing now goes straight there —
/// and the tooltip has to promise the same thing the click does.
@MainActor
final class CompactErrorAffordanceTests: XCTestCase {

    // MARK: - Phase → route

    func testConnectionProblemRoutesTheLeftWingToWeChatConnection() {
        let state = PanelState()
        var openedSettings = 0
        state.onShowSettings = { openedSettings += 1 }

        CompactWingRouter.activate(.openWeChatConnection, panelState: state)

        XCTAssertEqual(state.pendingSettingsTab, "system", "连接异常必须落到设置里的微信连接页")
        XCTAssertEqual(openedSettings, 1, "左翼必须真的打开设置")
        XCTAssertEqual(state.currentState, .compact, "连接异常时不该展开一个空收件箱")
    }

    func testEveryOtherRouteStillExpandsTheInbox() {
        let phases: [CompactIslandPhase] = [
            .quiet(sleepy: false),
            .quiet(sleepy: true),
            .notices(count: 2),
            .waiting(count: 1),
            .urgent(priority: .p1, count: 1),
            .urgent(priority: .p0, count: 3),
            .working(.analyzing)
        ]
        for phase in phases {
            let state = PanelState()
            var openedSettings = 0
            state.onShowSettings = { openedSettings += 1 }

            let route = CompactLeftWingRoute.resolve(phase)
            CompactWingRouter.activate(route, panelState: state)

            XCTAssertEqual(route, .openInbox, "\(phase) 必须保持原行为")
            XCTAssertEqual(state.currentState, .extended, "\(phase) 应当展开收件箱")
            XCTAssertEqual(openedSettings, 0, "\(phase) 不该打开设置")
            XCTAssertNil(state.pendingSettingsTab)
        }
    }

    func testPolicyPhasesResolveToTheSameRouteTheWingTakes() {
        for sync in [SyncStatus.waitingForWeChat, .accountSwitched, .error("db"), .stale] {
            let phase = CompactIslandPolicy.snapshot(input(sync: sync)).phase
            XCTAssertEqual(phase, .connectionProblem, "\(sync) 是连接异常")
            XCTAssertEqual(CompactLeftWingRoute.resolve(phase), .openWeChatConnection)
        }
        for sync in [SyncStatus.ok, .idle, .syncing] {
            let phase = CompactIslandPolicy.snapshot(input(sync: sync)).phase
            XCTAssertEqual(CompactLeftWingRoute.resolve(phase), .openInbox, "\(sync) 不该走连接设置")
        }
    }

    // MARK: - The promise the tooltip makes

    func testLeftWingCopyPromisesTheDestinationItActuallyUses() {
        let problem = CompactLeftWingCopy.make(phase: .connectionProblem, spoken: "微信还连不上。移入查看。")
        XCTAssertEqual(problem.route, .openWeChatConnection)
        XCTAssertTrue(problem.accessibilityLabel.contains("微信连接"), "AX 必须说出会打开微信连接，实际 \(problem.accessibilityLabel)")
        XCTAssertTrue(problem.help.contains("微信连接"), "tooltip 必须说出会打开微信连接，实际 \(problem.help)")
        XCTAssertTrue(problem.help.contains("设置"), "tooltip 必须说出会打开设置，实际 \(problem.help)")
        XCTAssertEqual(problem.spoken, "微信还连不上。移入查看。", "spoken 文案保持原样")

        let quiet = CompactLeftWingCopy.make(phase: .quiet(sleepy: false), spoken: "暂无待处理。移入查看。")
        XCTAssertEqual(quiet.route, .openInbox)
        XCTAssertEqual(quiet.accessibilityLabel, "打开聊天收件箱")
        XCTAssertTrue(quiet.help.hasPrefix("暂无待处理。"), "正常态 tooltip 仍以状态开头，实际 \(quiet.help)")
        XCTAssertTrue(quiet.help.contains("收件箱"))
    }

    // MARK: - The real click

    func testClickingTheLeftWingOnAConnectionProblemOpensWeChatConnection() {
        let state = PanelState()
        var openedSettings = 0
        state.onShowSettings = { openedSettings += 1 }
        let presentation = IslandPresentation()
        presentation.publish(IslandLiveInput(
            sync: .waitingForWeChat,
            actions: [],
            noticeCount: 0,
            autopilotActive: false,
            vipGlowTier: .none
        ))
        XCTAssertEqual(presentation.live.sync, .waitingForWeChat)
        let window = hostBar(panelState: state, presentation: presentation)
        defer { window.orderOut(nil) }

        clickLeftWing(window)

        XCTAssertEqual(state.pendingSettingsTab, "system", "点左翼必须去微信连接")
        XCTAssertEqual(openedSettings, 1)
        XCTAssertEqual(state.currentState, .compact, "点左翼不该展开收件箱")
    }

    func testClickingTheLeftWingOnAHealthyIslandStillExpandsTheInbox() {
        let state = PanelState()
        var openedSettings = 0
        state.onShowSettings = { openedSettings += 1 }
        let presentation = IslandPresentation()
        presentation.publish(IslandLiveInput(
            sync: .ok,
            actions: [],
            noticeCount: 0,
            autopilotActive: false,
            vipGlowTier: .none
        ))
        let window = hostBar(panelState: state, presentation: presentation)
        defer { window.orderOut(nil) }

        clickLeftWing(window)

        XCTAssertEqual(state.currentState, .extended, "正常态点左翼仍然是打开收件箱")
        XCTAssertEqual(openedSettings, 0)
        XCTAssertNil(state.pendingSettingsTab)
    }

    // MARK: - The anti-flicker rule the syncing branch used to contradict

    /// 1.2.3 made the island still: a background scan tick must not repaint the
    /// companion as working. The policy's `.working(.syncing)` phase was
    /// unreachable from both ends (stabilizing rewrites the status, and the
    /// phase function only ever produced `.analyzing`) and is gone; this pins
    /// the policy half of that contract.
    func testASyncTickIsNeverAWorkingPhase() {
        let snap = CompactIslandPolicy.snapshot(input(sync: .syncing))

        XCTAssertEqual(snap.phase, .quiet(sleepy: false))
        XCTAssertEqual(snap.mark, .dot(.quiet))
        XCTAssertNotEqual(snap.buddy, .scanning, "同步 tick 不能让伙伴进入扫描帧")
        XCTAssertEqual(snap.buddy, .idle)
    }

    // MARK: - Fixtures

    private let barHeight: CGFloat = 32
    private var barWidth: CGFloat { CompactInboxMetrics.wingWidth * 2 + 200 }

    private func input(
        sync: SyncStatus,
        actions: [CompactIslandAction] = [],
        noticeCount: Int = 0,
        aiActive: Bool = false
    ) -> CompactIslandInput {
        CompactIslandInput(
            sync: sync,
            actions: actions,
            noticeCount: noticeCount,
            aiActive: aiActive,
            autopilotActive: false,
            idleMinutes: 0,
            worstVIPTier: .none
        )
    }

    private func hostBar(panelState: PanelState, presentation: IslandPresentation) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: barHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = CompactInboxBar()
            .environmentObject(panelState)
            .environmentObject(presentation)
            .frame(width: barWidth, height: barHeight)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: barWidth, height: barHeight)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Centre of the left wing's own 56 × 32 frame. The wing keeps its trailing
    /// 6 pt as padding, so the control lives in x ∈ [0, 50].
    private func clickLeftWing(_ window: NSWindow) {
        let point = NSPoint(x: 25, y: barHeight / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                XCTFail("could not synthesise a mouse event")
                return
            }
            window.sendEvent(event)
            pump(0.03)
        }
        pump()
    }
}
