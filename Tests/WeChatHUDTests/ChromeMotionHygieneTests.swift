import XCTest
@testable import WeChatHUD

/// Source-scan gates for the shared motion/visual/copy language.
///
/// These drive the shipped files, not a re-implementation: a new unguarded
/// `withAnimation(` in Views, a 30pt page title, or a forbidden chrome word
/// in customer-facing labels fails here.
final class ChromeMotionHygieneTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
    }

    private func swiftFiles(under relative: String) throws -> [(name: String, text: String)] {
        let root = sourcesRoot().appendingPathComponent(relative)
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "no Swift files under \(relative)")
        return try files.map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testViewsDoNotCallUnguardedWithAnimation() throws {
        for file in try swiftFiles(under: "Views") {
            if file.name == "CompanionMotion.swift" {
                XCTAssertTrue(
                    file.text.contains("withAnimation(animation, body)"),
                    "the reduceMotion wrapper itself must be the only withAnimation call site"
                )
                let extras = file.text.components(separatedBy: "withAnimation(").count - 2
                XCTAssertEqual(extras, 0, "CompanionMotion.swift grew another withAnimation(")
                continue
            }
            for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
                guard line.contains("withAnimation(") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(
                    trimmed.contains("withAnimation(nil)"),
                    "\(file.name):\(index + 1) calls withAnimation outside the reduceMotion wrapper: \(trimmed)"
                )
            }
        }
    }

    func testIslandStateSwapUsesExplicitNilAnimation() throws {
        let root = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/HUDRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(root.contains(".animation(nil, value: panelState.presentedState)"))
    }

    func testAttachedPanelDoesNotTrapWhenTheIUOIsStillNil() {
        let app = AppDelegate()
        XCTAssertNil(app.attachedPanel)
    }

    func testIslandPillsUseTheSharedPressScale() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/IslandStyle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CompanionMotion.pressScale"))
        XCTAssertTrue(source.contains("CompanionMotion.press()"))
    }

    func testWorkspacePageTitleUsesNativeDisplayToken() throws {
        let source = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("companionFont(size: 30"), "page title must not be 30pt")
        XCTAssertTrue(source.contains("workspaceDisplay()"))
        XCTAssertTrue(source.contains("CompanionPressStyle()"))
    }

    func testCustomerFacingLabelsHaveNoForbiddenChrome() {
        let labels = [
            ReplyDebtReasonCode.whitelisted.label,
            WhitelistAttentionLevel.watch.label,
            WhitelistAttentionLevel.watch.shortLabel,
            AttentionLevel.whitelist.label,
            AttentionLevel.greylist.label,
            AttentionLevel.vip.label,
            AttentionLevel.stranger.label
        ]
        for label in labels {
            XCTAssertFalse(label.isEmpty)
            for word in CompanionProductCopy.forbiddenChrome {
                XCTAssertFalse(label.contains(word), "\(label) leaked \(word)")
            }
        }
        XCTAssertEqual(AttentionLevel.whitelist.label, "关注")
        XCTAssertEqual(WhitelistAttentionLevel.watch.label, "关注")
        XCTAssertEqual(ReplyDebtReasonCode.whitelisted.label, "已关注")
    }

    func testReadableChromeDoesNotGoBelowTenPoints() throws {
        for file in try swiftFiles(under: "Views") {
            if file.name == "PixelBuddyView.swift" { continue }
            for needle in [".font(.system(size: 6", ".font(.system(size: 7",
                           ".font(.system(size: 8", ".font(.system(size: 9"] {
                XCTAssertFalse(
                    file.text.contains(needle),
                    "\(file.name) still draws readable chrome below 10pt (\(needle))"
                )
            }
        }
    }

    func testTabSubtitlesStayShortAndConcrete() {
        // A page may drop the gloss entirely when the only candidate restated
        // the title (我答应的事 / 已答应的事) — but it may not fill the slot
        // with a sentence, an exclamation, or something the header can't fit.
        for tab in SettingsView.Tab.allCases {
            guard let subtitle = tab.subtitle else { continue }
            XCTAssertFalse(subtitle.isEmpty, tab.rawValue)
            XCTAssertLessThanOrEqual(
                subtitle.count, 12,
                "\(tab.rawValue) subtitle is too long: \(subtitle)"
            )
            XCTAssertFalse(subtitle.contains("！"))
            XCTAssertFalse(subtitle.contains("。"))
        }
        // Two pages carrying the same gloss is how 草稿 and 待确认回复 both
        // promised 确认后发送 while only one of them sends anything.
        let glosses = SettingsView.Tab.allCases.compactMap(\.subtitle)
        XCTAssertEqual(glosses.count, Set(glosses).count, "two pages share a gloss")
    }
}
