import XCTest
@testable import WeChatHUD

/// The preview harness has to be able to hold a surface on screen for a
/// screenshot without permanently changing the settings it borrows.
///
/// `--preview-notification` used to raise the stored notification duration to
/// 900 seconds and restore it afterwards. Killing the preview between the two
/// writes — which a QA run does constantly — left the long duration behind, and
/// later launches looked as if the banner ignored further clicks. The hold is
/// now passed to the presentation call and never touches stored settings.
final class PreviewHarnessHygieneTests: XCTestCase {

    private func previewSources() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/App/AppDelegate.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/App/PreviewRuntime.swift"),
            encoding: .utf8
        )
        return delegate + runtime
    }

    func testNotificationHoldIsNotWrittenIntoStoredSettings() throws {
        let source = try previewSources()
        XCTAssertFalse(
            source.contains("cfg.durationSeconds = 900"),
            "the preview hold must not be persisted into the notification setting"
        )
    }

    func testNotificationSimulationAcceptsAnExplicitHold() throws {
        let source = try previewSources()
        XCTAssertTrue(source.contains("holdSeconds: TimeInterval? = nil"))
        XCTAssertTrue(source.contains("panelState.showNotification(duration: holdSeconds ?? TimeInterval(config.durationSeconds))")
        )
    }

    func testCaptureRestoresTheAutocollapseLatch() throws {
        // captureSurfaces latches the panel open so the snapshot can include
        // it. It must put the latch back: leaving popoverOpen true disables
        // hover-to-collapse for the rest of the session.
        let source = try previewSources()
        guard let start = source.range(of: "static func captureSurfaces") else {
            return XCTFail("captureSurfaces is gone; update this guard")
        }
        let body = source[start.lowerBound...].prefix(1400)
        XCTAssertTrue(body.contains("let wasPopoverOpen = panelState?.popoverOpen ?? false"))
        XCTAssertTrue(body.contains("panelState?.popoverOpen = wasPopoverOpen"))
    }

    func testSnapshotOverridesDoNotCollapseTheIsland() throws {
        // The snapshot flags exist so QA never has to move the operator's
        // pointer; holding the island open is what makes that possible.
        let source = try previewSources()
        XCTAssertTrue(source.contains("--preview-hold-island"))
        XCTAssertTrue(source.contains("--preview-disconnected"))
        XCTAssertTrue(source.contains("--preview-tab="))
    }
}
