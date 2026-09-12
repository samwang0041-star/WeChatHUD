import XCTest
@testable import WeChatHUD

/// The disconnected-state banner used to read a doubled sync stamp:
/// `syncLabel(_:)` already appends the 同步 suffix, and the banner wrapped
/// it in another 上次同步 prefix, producing 上次同步 270 分钟前同步.
/// Live QA caught it in the running build.
///
/// This suite locks the split of responsibility: the suffixed helper owns
/// the 分钟前同步 form, the banner owns the 上次同步 wording, and neither
/// may produce the doubled suffix.
final class SyncStampWordingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let syncWord = "\u{4E0A}\u{6B21}\u{540C}\u{6B65}" // 上次同步

    func testSuffixedLabelStillCarriesTheSyncSuffix() {
        // The helper keeps its contract; the banner is the side that changed.
        let label = RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-270 * 60), suffix: "\u{540C}\u{6B65}", now: now)
        XCTAssertTrue(label.hasSuffix("\u{540C}\u{6B65}"), label)
        XCTAssertEqual(label.filter { $0 == "\u{540C}" }.count, 1, label)
    }

    func testBareLabelHasNoSyncSuffixToDoubleUp() {
        let bare = RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-270 * 60), now: now)
        XCTAssertEqual(bare, "4 \u{5C0F}\u{65F6}\u{524D}")
        XCTAssertFalse(bare.contains("\u{540C}\u{6B65}"), "the banner supplies its own prefix")
    }

    func testComposedBannerStampNamesSyncExactlyOnce() {
        // What the banner body renders for the disconnected state.
        let stamp = syncWord + " " + RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-270 * 60), now: now)
        XCTAssertEqual(stamp, "\u{4E0A}\u{6B21}\u{540C}\u{6B65} 4 \u{5C0F}\u{65F6}\u{524D}")
        XCTAssertEqual(stamp.filter { $0 == "\u{540C}" }.count, 1, stamp)
    }

    func testDisconnectedBannerSourceComposesTheBareLabel() throws {
        // The regression was a composition mistake, so a formatter-only test
        // would not have caught it. Read the view source and assert the
        // suffixed helper is not nested inside the banner's own prefix.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/InboxView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let nested = syncWord + " " + "\\" + "(syncLabel("
        XCTAssertFalse(source.contains(nested), "the banner must not nest the suffixed syncLabel in its own prefix")
        XCTAssertTrue(source.contains(syncWord), "the banner still owns the 上次同步 wording")
    }
}
