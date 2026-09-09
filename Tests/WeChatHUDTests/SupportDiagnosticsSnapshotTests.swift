import XCTest
@testable import WeChatHUD

final class SupportDiagnosticsSnapshotTests: XCTestCase {
    func testCurrentSnapshotUsesInjectedValuesAndExportsNoPath() {
        let bundle = Bundle(for: BundleMarker.self)
        let snapshot = SupportDiagnosticsSnapshot.current(
            bundle: bundle,
            bundleURL: URL(fileURLWithPath: "/Users/alice/Applications/WeChatHUD.app"),
            processIdentifier: 4242,
            accessibilityTrusted: false,
            previewMode: false,
            operatingSystemVersion: "macOS 27.0 (26A5425a)",
            applicationsRoots: [URL(fileURLWithPath: "/Users/alice/Applications", isDirectory: true)]
        )

        XCTAssertEqual(snapshot.osVersion, "macOS 27.0 (26A5425a)")
        XCTAssertEqual(snapshot.processIdentifier, 4242)
        XCTAssertFalse(snapshot.accessibilityTrusted)
        XCTAssertEqual(snapshot.bundleLocation, .installed)
        XCTAssertTrue(snapshot.exportLines.joined(separator: "\n").contains("AXIsProcessTrusted：false"))
        XCTAssertFalse(snapshot.exportLines.joined(separator: "\n").contains("/Users/alice"))
    }

    func testPreviewTakesPrecedenceOverBundlePath() {
        XCTAssertEqual(
            SupportDiagnosticsSnapshot.classifyBundleLocation(
                url: URL(fileURLWithPath: "/Applications/WeChatHUD.app"),
                preview: true
            ),
            .preview
        )
        XCTAssertEqual(
            SupportDiagnosticsSnapshot.classifyBundleLocation(
                url: URL(fileURLWithPath: "/tmp/WeChatHUD"),
                preview: false
            ),
            .other
        )
        XCTAssertEqual(
            SupportDiagnosticsSnapshot.classifyBundleLocation(
                url: URL(fileURLWithPath: "/Users/alice/Applications/WeChatHUD.app"),
                preview: false,
                applicationsRoots: [URL(fileURLWithPath: "/Users/alice/Applications", isDirectory: true)]
            ),
            .installed
        )
        XCTAssertEqual(
            SupportDiagnosticsSnapshot.classifyBundleLocation(
                url: URL(fileURLWithPath: "/tmp/Applications/WeChatHUD.app"),
                preview: false
            ),
            .other
        )
    }
}

private final class BundleMarker {}
