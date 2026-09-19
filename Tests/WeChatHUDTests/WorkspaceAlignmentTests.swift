import XCTest
import SwiftUI
@testable import WeChatHUD

/// Gates for the one page frame every sidebar entry shares.
///
/// The bug these lock: each page used to spell its own geometry (1180 / 960 /
/// 920 / a 20pt side padding) and the page header was sized from a *separate*
/// hardcoded list of tabs. Switching entries moved the title block and the
/// content onto different edges — 待确认回复 had a 960pt header over an 1180pt
/// body, 关系雷达 had a 1180pt header over a full-bleed body. Nothing failed;
/// it just looked wrong. These assert the wiring, and the source scans stop a
/// future page from going back to a private literal.
final class WorkspaceAlignmentTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
    }

    private func swiftFiles(under relative: String) throws -> [(name: String, path: String, text: String)] {
        let root = sourcesRoot().appendingPathComponent(relative)
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "no Swift files under \(relative)")
        return try files.map {
            (name: $0.lastPathComponent, path: $0.path, text: try String(contentsOf: $0, encoding: .utf8))
        }
    }

    /// Both families are real and they are the only two.
    func testEveryTabPicksOneOfTwoPageFamilies() {
        for tab in SettingsView.Tab.allCases {
            let width = tab.pageWidth
            XCTAssertTrue(
                width == WorkspacePage.wideWidth || width == WorkspacePage.narrowWidth,
                "\(tab.rawValue) invented a third page width: \(width)"
            )
        }
        for tab: SettingsView.Tab in [.today, .tasks, .commitments, .drafts, .contacts,
                                      .insight, .relationshipRadar, .autopilotDashboard] {
            XCTAssertEqual(tab.pageWidth, WorkspacePage.wideWidth, "\(tab.rawValue) is a two-pane page")
        }
        for tab: SettingsView.Tab in [.aiButler, .notifications, .aiService, .autopilot,
                                      .system, .preferences, .localData, .dailyReport, .guide] {
            XCTAssertEqual(tab.pageWidth, WorkspacePage.narrowWidth, "\(tab.rawValue) is a single-column page")
        }
    }

    /// The header is introduced by the page it sits on — same width, same
    /// inset — so the title block and the body always share a left edge.
    func testPageHeaderReadsThePageWidthInsteadOfItsOwnList() throws {
        let file = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            file.contains("private var headerWidth: CGFloat { selectedTab.pageWidth }"),
            "the page header must take its width from the tab, not from a second list of literals"
        )
        // The header must read the shared tokens, not repeat their values.
        // Pinning the literal `28`/`12` here (as this test first did) is what
        // let `WorkspacePage.headerGap` sit declared, asserted and unused.
        XCTAssertTrue(
            file.contains("""
                .padding(.horizontal, WorkspacePage.inset)
                        .padding(.top, WorkspacePage.selfHeadedTopGap)
                        .padding(.bottom, WorkspacePage.headerGap)
                """),
            "the header must read WorkspacePage's inset/gaps so it cannot drift off the body it introduces"
        )
    }

    /// Every page body goes through the shared modifier.
    func testEveryPageBodyUsesTheSharedPageFrame() throws {
        let file = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let usages = file.components(separatedBy: ".workspacePage(").count - 1
        XCTAssertGreaterThanOrEqual(usages, 9, "the workspace should route every page through one frame; found \(usages)")
    }

    /// No page may reintroduce a private page-level width or side inset.
    ///
    /// Allowed exceptions are deliberate and narrow: the token file itself,
    /// and views whose width is an inner card/list column rather than a page.
    /// No page may go back to a private page-level width.
    ///
    /// Proven to fail: adding `.frame(maxWidth: 960)` to `CommitmentTabView`
    /// trips this.
    func testNoPageHardcodesAPageWidth() throws {
        let allowed: Set<String> = ["WorkspacePageLayout.swift"]
        let needles = ["frame(maxWidth: 1180", "frame(maxWidth: 960", "frame(maxWidth: 920"]
        for file in try swiftFiles(under: "Views") where !allowed.contains(file.name) {
            for needle in needles where file.text.contains(needle) {
                XCTFail("\(file.name) hardcodes a page width (\(needle)); use WorkspacePage + .workspacePage(_:)")
            }
        }
    }

    /// Narrower pin: the two toolbars that used to inset themselves by 20pt on
    /// top of the page frame must not go back to it.
    ///
    /// Deliberately *not* a blanket ban on `padding(.horizontal, 20)`. That
    /// number is legitimate elsewhere — `ChatInsightDetailView` uses it to inset
    /// content inside a split-view column, which is a column inset, not a page
    /// one. The earlier version of this test tried to express the general rule
    /// as a pattern match on one exact literal (".padding(.horizontal, 20)"
    /// followed by ".padding(.vertical, 12)") and would only ever have caught
    /// that one spelling while reading as a general guarantee. Naming the two
    /// call sites is honest about what is actually checked.
    func testTheTwoFixedToolbarsDoNotDoubleInset() throws {
        for name in ["RelationshipRadarView.swift", "DailyReportTabView.swift"] {
            let file = try swiftFiles(under: "Views").first { $0.name == name }
            let text = try XCTUnwrap(file?.text, "\(name) not found")
            XCTAssertFalse(
                text.contains(".padding(.horizontal, 20)"),
                "\(name) insets a page-level toolbar; the page frame already supplies the page inset"
            )
        }
    }

    /// The shared numbers themselves: a page must be wider than the window's
    /// sidebar and narrower than the window, the inset must match the header's,
    /// and the vertical gaps must stay finite and small.
    func testSharedPageNumbersStayInRange() {
        XCTAssertGreaterThan(WorkspacePage.narrowWidth, 600, "a form column narrower than ~600pt starts wrapping labels")
        XCTAssertLessThan(WorkspacePage.narrowWidth, WorkspacePage.wideWidth)
        XCTAssertLessThanOrEqual(WorkspacePage.wideWidth, 1200, "beyond ~1200pt a text line stops being readable")
        XCTAssertEqual(WorkspacePage.inset, 28, "the page header hardcodes 28") 
        XCTAssertGreaterThan(WorkspacePage.headerGap, 0)
        XCTAssertLessThanOrEqual(WorkspacePage.headerGap, 24)
        XCTAssertGreaterThan(WorkspacePage.bottomGap, 0)
        XCTAssertLessThanOrEqual(WorkspacePage.bottomGap, 32)
    }

    /// One ground for every page.
    ///
    /// Three were in use — the warm `CompanionPalette.canvas`, the cooler
    /// system `windowBackgroundColor`, and (in 草稿) nothing at all, letting the
    /// window's tinted backdrop show through. Switching sections flipped the
    /// room from warm to cold to transparent for no reason the user could see.
    /// The page-level `windowBackgroundColor` fills are the defect this locks.
    /// (Card-level uses of the system colour, e.g. chips, are untouched.)
    func testNoPagePaintsItselfTheSystemGround() throws {
        // Files where the system colour is a control's fill, not the page's.
        let allowed: Set<String> = [
            "CompanionStyle.swift",      // CompanionDialog's own surface
            "InsightSidebarView.swift",  // a list column inside the split view
            "SettingsView.swift",        // the sidebar column
            "ContactsSettingsView.swift",// sub-pane fills behind cards
        ]
        for file in try swiftFiles(under: "Views") where !allowed.contains(file.name) {
            XCTAssertFalse(
                file.text.contains(".background(Color(nsColor: .windowBackgroundColor))"),
                "\(file.name) paints a page in the system grey; use WorkspacePage.ground so every page shares one ground"
            )
        }
    }
}
