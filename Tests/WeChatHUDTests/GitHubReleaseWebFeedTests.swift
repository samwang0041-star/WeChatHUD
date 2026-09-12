import XCTest
@testable import WeChatHUD

/// A published app cannot depend on the REST API's per-IP quota: anonymous
/// callers get 60 requests an hour, shared by everyone behind the same NAT,
/// and the 403 that follows would look to the user like "no new version" or
/// "this repository is private". These tests pin the public web path that
/// replaces it.
final class GitHubReleaseWebFeedTests: XCTestCase {

    func testBuildsPublicReleaseURLs() {
        XCTAssertEqual(
            GitHubReleaseWebFeed.latestReleaseURL(repository: "owner/repo")?.absoluteString,
            "https://github.com/owner/repo/releases/latest"
        )
        XCTAssertEqual(
            GitHubReleaseWebFeed.expandedAssetsURL(repository: "owner/repo", tag: "v1.3.0")?.absoluteString,
            "https://github.com/owner/repo/releases/expanded_assets/v1.3.0"
        )
        XCTAssertEqual(
            GitHubReleaseWebFeed.downloadURL(repository: "owner/repo", tag: "v1.3.0", assetName: "WeChatHUD-1.3.0-macOS14-arm64.zip")?.absoluteString,
            "https://github.com/owner/repo/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip"
        )
    }

    func testTagWithASlashIsPathEncoded() {
        // Release branches and monorepo tags contain slashes; a raw one would
        // silently address a different path.
        XCTAssertEqual(
            GitHubReleaseWebFeed.expandedAssetsURL(repository: "owner/repo", tag: "pkg/v1.3.0")?.absoluteString,
            "https://github.com/owner/repo/releases/expanded_assets/pkg%2Fv1.3.0"
        )
        XCTAssertEqual(
            GitHubReleaseWebFeed.downloadURL(repository: "owner/repo", tag: "pkg/v1.3.0", assetName: "a.zip")?.absoluteString,
            "https://github.com/owner/repo/releases/download/pkg%2Fv1.3.0/a.zip"
        )
    }

    func testReadsTheTagOutOfTheResolvedLatestURL() {
        func tag(_ raw: String) -> String? {
            GitHubReleaseWebFeed.tag(fromResolvedLatestURL: URL(string: raw)!)
        }
        XCTAssertEqual(tag("https://github.com/owner/repo/releases/tag/v1.3.0"), "v1.3.0")
        XCTAssertEqual(tag("https://github.com/owner/repo/releases/tag/1.3.0"), "1.3.0")
        XCTAssertEqual(tag("https://github.com/owner/repo/releases/tag/pkg/v1.3.0"), "pkg/v1.3.0")
        XCTAssertNil(tag("https://github.com/owner/repo/releases"))
    }

    func testParsesAssetNamesFromTheExpandedAssetsFragment() {
        let result = ExpandedAssetsParser.parse(Self.expandedAssetsHTML)
        XCTAssertTrue(result.names.contains("WeChatHUD-1.3.0-macOS14-arm64.zip"), "\(result.names)")
        XCTAssertTrue(result.names.contains("WeChatHUD-1.3.0-macOS14-arm64.zip.sha256"), "\(result.names)")
        XCTAssertEqual(result.ids["WeChatHUD-1.3.0-macOS14-arm64.zip"], 490123456)
    }

    func testIgnoresSourceArchivesAndNonAssetRows() {
        let result = ExpandedAssetsParser.parse(Self.expandedAssetsHTML)
        XCTAssertFalse(result.names.contains { $0.contains("Source code") }, "\(result.names)")
        XCTAssertEqual(result.names.count, 2, "only the two uploaded installers are assets: \(result.names)")
    }

    func testPageWithoutAssetIDsStillYieldsNames() {
        // The page is also served without an API session; names must survive.
        // Strip every id, not just the first row's.
        let html = Self.expandedAssetsHTML.replacingOccurrences(of: "/releases/download/49012345", with: "/releases/download/v1.3.0")
        let result = ExpandedAssetsParser.parse(html)
        XCTAssertEqual(result.ids.count, 0)
        XCTAssertTrue(result.names.contains("WeChatHUD-1.3.0-macOS14-arm64.zip"))
    }

    func testRestyledPageFindsNoAssetsRatherThanTheWrongOnes() {
        let result = ExpandedAssetsParser.parse("<html><body>nothing to see</body></html>")
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertTrue(result.ids.isEmpty)
    }
}

private extension GitHubReleaseWebFeedTests {
    /// Shape of the real fragment: a Box-row per uploaded file, the name in a
    /// span, the id inside the download link, and a separate source-code block
    /// that must not be mistaken for an installer.
    static let expandedAssetsHTML = """
    <div data-view-component="true" class="Box Box--condensed tmp-mt-3">
      <ul data-view-component="true">
        <li data-view-component="true" class="Box-row d-flex flex-column flex-md-row">
          <div class="col-12 col-lg-6"><span class="d-flex flex-items-start">
          <span data-view-component="true" class="Truncate">
            <span data-view-component="true" class="Truncate-text">WeChatHUD-1.3.0-macOS14-arm64.zip</span>
          </span></span></div>
          <a href="/owner/repo/releases/download/490123456/WeChatHUD-1.3.0-macOS14-arm64.zip">Download</a>
        </li>
        <li data-view-component="true" class="Box-row d-flex flex-column flex-md-row">
          <div class="col-12 col-lg-6"><span class="d-flex flex-items-start">
          <span data-view-component="true" class="Truncate">
            <span data-view-component="true" class="Truncate-text">WeChatHUD-1.3.0-macOS14-arm64.zip.sha256</span>
          </span></span></div>
          <a href="/owner/repo/releases/download/490123457/WeChatHUD-1.3.0-macOS14-arm64.zip.sha256">Download</a>
        </li>
      </ul>
    </div>
    <details><summary>Source code (zip)</summary></details>
    """
}
