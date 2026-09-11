import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Offscreen layout harness for the island notification banner.
///
/// The reported bug: `AppDelegate.panelSize(for: .notification)` sizes the
/// NSPanel as `notchHeight + IslandChrome.notificationBaseBelowNotch`
/// (32 + 168 = 200 pt), so any banner content that renders taller than that
/// static budget is clipped by the panel's bottom edge — the user's
/// screenshot shows the "看看什么事 / 稍后提醒" row cut in half.
///
/// These tests render the real `NotificationBannerView` offscreen at the
/// real banner width (580 pt) and measure its natural height, so the static
/// budget can be compared against what SwiftUI actually lays out.
@MainActor
final class NotificationBannerLayoutTests: XCTestCase {

    /// Width the panel gives the banner: the shared
    /// `IslandNotificationLayout.panelWidth` with a 200 pt notch
    /// placeholder. Using the same source the view and AppDelegate read
    /// keeps this harness honest if the formula ever changes.
    private let bannerWidth: CGFloat = IslandNotificationLayout.panelWidth(notchWidth: 200)

    /// What the pre-fix `panelSize(for: .notification)` budgeted below the
    /// notch before any measurement was plumbed through.
    private var legacyStaticBudget: CGFloat { 32 + IslandChrome.notificationBaseBelowNotch }

    // MARK: - Fixture plumbing

    private struct Fixture {
        let store: HUDStore
        let monitor: ChatMonitor
        let panelState: PanelState
        let root: String
    }

    private func makeFixture() throws -> Fixture {
        let root = NSTemporaryDirectory() + "notification-banner-layout-\(UUID().uuidString)"
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

    private func banner(_ notification: HUDNotification, in fixture: Fixture) -> some View {
        NotificationBannerView(notification: notification)
            .environmentObject(fixture.monitor)
            .environmentObject(fixture.panelState)
    }

    // MARK: - Offscreen measurement

    /// Render `view` in a real AppKit hosting view at `width` and ask AppKit
    /// for its natural (ideal) height. `.intrinsicContentSize` is the value
    /// that answers a nil height proposal, i.e. exactly the layout the panel
    /// would need to avoid clipping. The other two candidates are printed
    /// for evidence only — a `.frame(maxHeight: .infinity)` root makes
    /// `sizeThatFits(in:)` echo the proposed height on some builds.
    private struct Measurement {
        let intrinsic: CGSize
        let fitting: CGSize
        let sizeThatFits: CGSize
    }

    private func measure(_ view: some View, width: CGFloat) -> Measurement {
        let controller = NSHostingController(rootView: view.frame(width: width))
        controller.sizingOptions = [.intrinsicContentSize]
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        host.layoutSubtreeIfNeeded()
        host.updateConstraintsForSubtreeIfNeeded()
        return Measurement(
            intrinsic: host.intrinsicContentSize,
            fitting: host.fittingSize,
            sizeThatFits: controller.sizeThatFits(in: NSSize(width: width, height: 4000))
        )
    }

    /// Measure, print the diagnostics, and return the intrinsic height.
    @discardableResult
    private func measuredHeight(
        of view: some View,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        let result = measure(view, width: bannerWidth)
        print("[banner-layout] \(label): intrinsic=\(fmt(result.intrinsic)) fitting=\(fmt(result.fitting)) sizeThatFits=\(fmt(result.sizeThatFits)) legacyBudget=\(legacyStaticBudget)")
        XCTAssertTrue(
            result.intrinsic.height.isFinite && result.intrinsic.height > 0,
            "\(label): intrinsic height must be a sane non-zero number, got \(fmt(result.intrinsic))",
            file: file, line: line
        )
        return result.intrinsic.height
    }

    private func fmt(_ size: CGSize) -> String {
        "\(size.width.rounded())×\(size.height.rounded())"
    }

    // MARK: - Fixture 1: short preview-style notification

    /// The exact notification `PreviewRuntime.simulateNotification` shows.
    private func previewStyleNotification() -> HUDNotification {
        let text = "@我 明天下午评审，能否确认待办责任人的展示方案？"
        return HUDNotification(
            chatUsername: "preview-project",
            chatName: "项目协作群",
            senderUsername: "preview-peer",
            senderName: "林晓",
            attentionLevel: .vip,
            messageID: "preview-notification-\(UUID().uuidString)",
            rawText: text,
            snippet: text,
            isAtMention: true,
            timestamp: Date(),
            kind: .groupAt
        )
    }

    func testShortPreviewNotificationNaturalHeight() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let notification = previewStyleNotification()
        fixture.panelState.showNotification(duration: 3)
        let height = measuredHeight(of: banner(notification, in: fixture), label: "short-preview")
        XCTAssertGreaterThan(height, 0)
    }

    // MARK: - Fixture 2: long realistic group @ (the reported screenshot)

    private func longGroupAtNotification() -> (HUDNotification, String) {
        let snippet = "@v_chuygwang 老师您好，目前公众号正在做年审，之前行业是金融类-银行，目前在公众号后台没有找到这个类型，麻烦看下可以使用哪个类型吗？另外年审截止时间是本周五，如果需要补充材料请提前告诉我，谢谢老师。"
        let notification = HUDNotification(
            chatUsername: "wxid-miniprogram-biz",
            chatName: "行业合作-小程序业务交流群",
            senderUsername: "wxid-anami",
            senderName: "周然",
            attentionLevel: .watch,
            messageID: "synthetic-long-\(UUID().uuidString)",
            rawText: snippet,
            snippet: snippet,
            isAtMention: true,
            timestamp: Date(),
            kind: .groupAt
        )
        return (notification, snippet)
    }

    func testLongRealisticGroupAtNaturalHeight() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let (notification, snippet) = longGroupAtNotification()
        XCTAssertGreaterThanOrEqual(snippet.count, 90, "fixture must mirror the long screenshot case")
        fixture.panelState.showNotification(duration: 3)
        let height = measuredHeight(of: banner(notification, in: fixture), label: "long-group-at")
        print("[banner-layout] long-group-at snippet chars=\(snippet.count) exceedsLegacyBudget=\(height > legacyStaticBudget)")
    }

    // MARK: - Fixture 3: briefing expanded

    func testBriefingExpandedNaturalHeight() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let (notification, _) = longGroupAtNotification()
        fixture.monitor.groupContextStates[notification.briefingKey] = GroupContextBriefingLoadState(
            briefing: GroupContextBriefing(
                situation: "大家正在确认今天下午的评审安排，公众号年审材料也在同步收集中。",
                whyMentioned: "周然需要你确认年审行业类目该选哪一个。",
                currentStatus: "还在等你回复。",
                nextStep: "确认类目后在群里回复，并给出截止时间。",
                participants: ["周然"],
                confidence: 0.9,
                source: .ai,
                generatedAt: Date()
            ),
            isLoading: false,
            errorMessage: nil,
            updatedAt: Date()
        )
        fixture.panelState.showNotification(duration: 3)
        fixture.panelState.setBriefingExpanded(true)
        XCTAssertTrue(fixture.panelState.briefingExpanded)
        let height = measuredHeight(of: banner(notification, in: fixture), label: "briefing-expanded")
        XCTAssertGreaterThan(height, 0)
    }

    // MARK: - Fixture 4: snooze menu open

    /// `NotificationBannerView.showSnooze` is a private `@State`, so the open
    /// menu cannot be toggled from the outside without restructuring the view
    /// (out of scope). Measure the two real pieces instead: the banner's
    /// natural height and `IslandSnoozeMenu` on its own; the banner's own
    /// `VStack(spacing: 10)` stacks them, so banner + 10 + menu is the height
    /// the panel must hold while 稍后提醒 is open.
    func testSnoozeMenuNaturalHeight() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let (notification, _) = longGroupAtNotification()
        fixture.panelState.showNotification(duration: 3)
        let bannerHeight = measuredHeight(of: banner(notification, in: fixture), label: "long-group-at-for-snooze")
        let menuHeight = measuredHeight(of: IslandSnoozeMenu { _ in }, label: "snooze-menu-standalone")
        let estimated = bannerHeight + 10 + menuHeight
        print("[banner-layout] snooze-open-estimate=\(estimated.rounded()) (banner \(bannerHeight.rounded()) + spacing 10 + menu \(menuHeight.rounded())) exceedsLegacyBudget=\(estimated > legacyStaticBudget)")
    }

    // MARK: - Phase 2: regression pins for the measured-height contract

    /// The reported screenshot case (long group name + three-line snippet)
    /// must fit inside the panel height the app derives from the banner's
    /// own measurement. The banner was slimmed down after the static-budget
    /// clipping bug was fixed, so the pin is now "panel ≥ measured", not
    /// "measured > the historical budget".
    func testLegacyStaticBudgetProvablyClippedTheScreenshotCase() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let (notification, snippet) = longGroupAtNotification()
        fixture.panelState.showNotification(duration: 3)
        let natural = measuredHeight(of: banner(notification, in: fixture), label: "screenshot-case")
        let panelHeight = IslandNotificationLayout.panelHeight(
            measuredContentHeight: natural,
            notchHeight: 32,
            fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
        )
        XCTAssertGreaterThanOrEqual(
            panelHeight, natural,
            "regression: \(snippet.count)-char `.groupAt` banner measures \(natural.rounded()) pt but the derived panel is only \(panelHeight.rounded()) pt"
        )
    }

    /// The pane height SwiftUI must be given so nothing is clipped:
    /// `IslandNotificationLayout.panelHeight` has to return at least the
    /// banner's own natural height for every fixture.
    func testPanelHeightNeverClipsAnyMeasuredFixture() throws {
        func assertFits(
            label: String,
            notification: HUDNotification,
            configure: (Fixture, HUDNotification) -> Void
        ) throws {
            let fixture = try makeFixture()
            defer { cleanUp(fixture) }
            configure(fixture, notification)
            let natural = measuredHeight(of: banner(notification, in: fixture), label: label)
            let panelHeight = IslandNotificationLayout.panelHeight(
                measuredContentHeight: natural,
                notchHeight: 32,
                fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
            )
            XCTAssertGreaterThanOrEqual(
                panelHeight, natural,
                "\(label): panelHeight(\(panelHeight.rounded())) < measured content (\(natural.rounded())) — the bottom of the banner would be clipped"
            )
        }

        try assertFits(label: "panel-fit-short", notification: previewStyleNotification()) { fixture, _ in
            fixture.panelState.showNotification(duration: 3)
        }
        try assertFits(label: "panel-fit-long", notification: longGroupAtNotification().0) { fixture, _ in
            fixture.panelState.showNotification(duration: 3)
        }
        try assertFits(label: "panel-fit-briefing", notification: longGroupAtNotification().0) { fixture, notification in
            fixture.monitor.groupContextStates[notification.briefingKey] = Self.previewBriefingState()
            fixture.panelState.showNotification(duration: 3)
            fixture.panelState.setBriefingExpanded(true)
        }
    }

    /// The screenshot case measured 247 pt before the banner was slimmed —
    /// inside the floor/ceiling window then, so the measured height was used
    /// verbatim. Today's slimmer banner sits below the 168pt floor; the pin
    /// is that a real measurement still drives the panel without being
    /// clipped, and a tall measurement is still used verbatim.
    func testMeasuredHeightIsUsedVerbatimInsideTheClampWindow() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let (notification, _) = longGroupAtNotification()
        fixture.panelState.showNotification(duration: 3)
        let natural = measuredHeight(of: banner(notification, in: fixture), label: "verbatim")
        let panelHeight = IslandNotificationLayout.panelHeight(
            measuredContentHeight: natural,
            notchHeight: 32,
            fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
        )
        XCTAssertEqual(
            panelHeight,
            max(natural, 32 + IslandNotificationLayout.minBelowNotch),
            accuracy: 0.5,
            "measured height must be used verbatim or floored at the minimum useful height — never shrunk"
        )
        // A measurement above the floor is still used verbatim.
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(
                measuredContentHeight: 300, notchHeight: 32,
                fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
            ),
            300, accuracy: 0.5
        )
    }

    /// No measurement yet → historical static estimate; tiny/bogus
    /// measurements are clamped so they can never produce a sliver window;
    /// absurd ones are capped.
    func testPanelHeightFallsBackAndClamps() {
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(measuredContentHeight: 0, notchHeight: 32, fallbackBelowNotch: 168),
            200, accuracy: 0.001,
            "no measurement must fall back to notchHeight + fallbackBelowNotch"
        )
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(measuredContentHeight: 1, notchHeight: 32, fallbackBelowNotch: 168),
            200, accuracy: 0.001,
            "a 1 pt measurement is still 'no measurement' (guard is > 1)"
        )
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(measuredContentHeight: 12, notchHeight: 32, fallbackBelowNotch: 168),
            32 + IslandNotificationLayout.minBelowNotch, accuracy: 0.001,
            "clamp floor: a bogus short measurement must not shrink the panel below the static budget"
        )
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(measuredContentHeight: 10, notchHeight: 32, fallbackBelowNotch: 168),
            200, accuracy: 0.001,
            "clamp floor: 10 pt is a real (if absurd) measurement and clamps up to 200 pt"
        )
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(measuredContentHeight: 100_000, notchHeight: 32, fallbackBelowNotch: 168),
            32 + IslandNotificationLayout.maxBelowNotch, accuracy: 0.001,
            "clamp ceiling: runaway measurements are capped"
        )
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(measuredContentHeight: 10_000, notchHeight: 32, fallbackBelowNotch: 168),
            592, accuracy: 0.001,
            "clamp ceiling: 10_000 pt clamps to notchHeight + maxBelowNotch = 592 pt"
        )
        XCTAssertEqual(
            IslandNotificationLayout.panelHeight(
                measuredContentHeight: 0, notchHeight: 32,
                fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
            ),
            legacyStaticBudget, accuracy: 0.001,
            "the fallback AppDelegate passes must reproduce the pre-fix 200 pt budget"
        )
        XCTAssertEqual(
            IslandNotificationLayout.minBelowNotch, IslandChrome.notificationBaseBelowNotch, accuracy: 0.001,
            "the clamp floor is documented as the historical static budget"
        )
    }

    /// `panelWidth` is the single source for both the NSPanel's frame and
    /// the banner's own layout width — pin the contract so the two can
    /// never drift apart again (that drift was the first-frame re-wrap).
    func testPanelWidthHonoursFloorAndNotch() {
        XCTAssertEqual(IslandNotificationLayout.panelWidth(notchWidth: 200), 580)
        XCTAssertEqual(IslandNotificationLayout.panelWidth(notchWidth: 0), IslandChrome.notificationMinWidth)
        XCTAssertEqual(IslandNotificationLayout.panelWidth(notchWidth: 500), 740,
                       "a wide notch grows the banner past the minimum")
    }

    /// End-to-end version of the same pin: host the banner the way
    /// `HUDRootView` does, let it publish `SizePreferenceKey`, and check the
    /// height the app would derive from that report.
    func testBannerReportDrivesAPanelTallEnoughForIt() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let (notification, _) = longGroupAtNotification()
        fixture.panelState.showNotification(duration: 3)
        XCTAssertEqual(fixture.panelState.measuredNotificationSize, .zero, "a fresh banner starts with no measurement")

        let panelState = fixture.panelState
        let controller = NSHostingController(rootView: AnyView(
            banner(notification, in: fixture)
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    MainActor.assumeIsolated { panelState.reportNotificationSize(size) }
                }
                .frame(width: bannerWidth)
        ))
        controller.sizingOptions = [.intrinsicContentSize]
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: bannerWidth, height: 2000)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let reported = fixture.panelState.measuredNotificationSize
        print("[banner-layout] preference-reported=\(fmt(reported)) legacyBudget=\(legacyStaticBudget)")
        XCTAssertGreaterThan(
            reported.height, 1,
            "the banner must report its real height — a zero report means the preference pipe broke"
        )
        let panelHeight = IslandNotificationLayout.panelHeight(
            measuredContentHeight: reported.height,
            notchHeight: 32,
            fallbackBelowNotch: IslandChrome.notificationBaseBelowNotch
        )
        XCTAssertGreaterThanOrEqual(
            panelHeight, reported.height,
            "panelHeight(\(panelHeight.rounded())) < banner-reported height (\(reported.height.rounded()))"
        )

        panelState.invalidateNotificationSize()
        XCTAssertEqual(panelState.measuredNotificationSize, .zero, "a new banner must not reuse the previous height")
    }

    private static func previewBriefingState() -> GroupContextBriefingLoadState {
        GroupContextBriefingLoadState(
            briefing: GroupContextBriefing(
                situation: "大家正在确认今天下午的评审安排，公众号年审材料也在同步收集中。",
                whyMentioned: "周然需要你确认年审行业类目该选哪一个。",
                currentStatus: "还在等你回复。",
                nextStep: "确认类目后在群里回复，并给出截止时间。",
                participants: ["周然"],
                confidence: 0.9,
                source: .ai,
                generatedAt: Date()
            ),
            isLoading: false,
            errorMessage: nil,
            updatedAt: Date()
        )
    }
}
