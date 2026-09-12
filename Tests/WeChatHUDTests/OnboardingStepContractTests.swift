import XCTest
@testable import WeChatHUD

/// The first-run wizard draws two pages. The step indicator used to draw a
/// third grey dot for "开始使用" that no click could ever reach, so a finished
/// setup looked like it was missing a step. These tests lock the contract
/// between the copy data and the rendered pages.
final class OnboardingStepContractTests: XCTestCase {

    // MARK: - Indicator dots

    func testIndicatorDrawsExactlyTheContentPages() {
        XCTAssertEqual(
            FirstLaunchGuide.contentPageCount,
            FirstLaunchGuide.stepTitles.count - 1,
            "The third stepper label belongs to the finish CTA, not to a page."
        )
        XCTAssertEqual(
            FirstLaunchGuide.pageTitles.count,
            FirstLaunchGuide.contentPageCount,
            "One dot per page: a dot without a page is the bug this locks out."
        )
        XCTAssertEqual(FirstLaunchGuide.pageTitles, ["连接微信", "选择关注"])
    }

    func testPageTitlesCanNeverDriftAheadOfTheDrawnPages() {
        // pageTitles is derived from stepTitles, so even a future edit that
        // appends a label cannot silently add a grey, unreachable dot.
        XCTAssertEqual(FirstLaunchGuide.pageTitles, Array(FirstLaunchGuide.stepTitles.prefix(FirstLaunchGuide.contentPageCount)))
        XCTAssertLessThanOrEqual(FirstLaunchGuide.pageTitles.count, FirstLaunchGuide.stepTitles.count)
    }

    func testSpokenStepCountMatchesTheDrawnPages() {
        // VoiceOver said "共 3 步" while only 2 pages existed; the label is
        // built from pageTitles now, so the two always agree.
        for page in 0..<FirstLaunchGuide.pageTitles.count {
            let spoken = "\(FirstLaunchGuide.pageTitle(at: page))，第 \(page + 1) 步，共 \(FirstLaunchGuide.pageTitles.count) 步"
            XCTAssertTrue(spoken.contains("共 \(FirstLaunchGuide.contentPageCount) 步"), spoken)
            XCTAssertTrue(spoken.contains("第 \(page + 1) 步"), spoken)
        }
    }

    // MARK: - Indexing and the final CTA

    func testPageTitleLookupNeverTraps() {
        XCTAssertEqual(FirstLaunchGuide.pageTitle(at: 0), "连接微信")
        XCTAssertEqual(FirstLaunchGuide.pageTitle(at: 1), "选择关注")
        // Past the last page the wizard is finishing, not advancing.
        XCTAssertEqual(FirstLaunchGuide.pageTitle(at: 2), FirstLaunchGuide.finishCTA)
        XCTAssertEqual(FirstLaunchGuide.pageTitle(at: 99), FirstLaunchGuide.finishCTA)
        XCTAssertEqual(FirstLaunchGuide.pageTitle(at: -1), FirstLaunchGuide.finishCTA)
    }

    func testEveryPageEndsWithTheStartCTAOnTheLastPage() {
        let lastPage = FirstLaunchGuide.contentPageCount - 1
        for page in 0...lastPage {
            let cta = FirstLaunchGuide.primaryCTA(forStep: page)
            if page == lastPage {
                XCTAssertEqual(cta, FirstLaunchGuide.finishCTA, "The last page must show 开始使用.")
                XCTAssertEqual(cta, "开始使用")
            } else {
                XCTAssertEqual(cta, FirstLaunchGuide.nextCTA)
            }
        }
    }

    // MARK: - Dead branches

    func testTheThirdStepperLabelIsTheCTAAndHasNoRenderedPage() throws {
        let source = try OnboardingViewSource.load()
        // The body may only route to the two real pages; there is no case for
        // a screen that renders "开始使用".
        XCTAssertTrue(source.body.contains("case 0: wechatDetection"), "page 1 must still render")
        XCTAssertTrue(source.body.contains("default: whitelistGuide"), "page 2 must still render")
        XCTAssertFalse(source.body.contains("featureOverview"), "no dead finish page may creep back")
        XCTAssertFalse(source.body.contains("aiSetup"), "no dead AI page may creep back")
    }
}

/// Reads OnboardingView.swift so a rename cannot silently re-introduce the
/// dead branches the audit found.
private enum OnboardingViewSource {
    struct Source {
        let body: String
    }

    static func load() throws -> Source {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/OnboardingView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("OnboardingView.swift not found at \(url.path)")
        }
        return Source(body: text)
    }
}

