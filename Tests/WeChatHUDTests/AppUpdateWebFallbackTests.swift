import XCTest
@testable import WeChatHUD

/// The reported bug: 检查更新 did nothing while GitHub had in fact published a
/// new release. The API answered 403 "API rate limit exceeded for <ip>" —
/// anonymous callers share 60 requests an hour with everyone behind the same
/// NAT — and the app turned that into "private repository, configure a
/// token", which reads as "nothing was published".
///
/// These tests pin the correction: a quota failure is named as one, and the
/// check continues over the public release pages, which carry the same version
/// and installers without a quota.
final class AppUpdateWebFallbackTests: XCTestCase {

    func testRateLimitedAPIFallsBackToThePublicPages() async throws {
        let client = StubClient(stubs: [
            StubClient.rateLimitedAPI,
            StubClient.redirect(to: "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.3.0"),
            StubClient.html(Self.expandedAssetsHTML)
        ])
        let service = AppUpdateService(http: client, currentVersion: AppVersion("1.2.27")!)

        let result = try await service.check(repository: "samwang0041-star/WeChatHUD")

        XCTAssertEqual(result.offer?.version, AppVersion("1.3.0")!)
        XCTAssertEqual(result.offer?.asset.name, "WeChatHUD-1.3.0-macOS14-arm64.zip")
        XCTAssertEqual(
            result.offer?.asset.browserDownloadURL.absoluteString,
            "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip"
        )
        XCTAssertEqual(result.offer?.checksumAsset?.name, "WeChatHUD-1.3.0-macOS14-arm64.zip.sha256")
        XCTAssertEqual(client.requests.count, 3, "API attempt, then latest, then the asset list")
        XCTAssertFalse(
            client.requests[1].url?.absoluteString.contains("api.github.com") ?? true,
            "the fallback must not go back to the API"
        )
    }

    func testRateLimitedAPIIsNamedAsAQuotaNotAsAPrivateRepo() async {
        // Both the API and the pages are unavailable: the message must not send
        // the user looking for a token they do not need.
        let client = StubClient(stubs: [
            StubClient.rateLimitedAPI, StubClient.rateLimitedAPI, StubClient.rateLimitedAPI
        ])
        let service = AppUpdateService(http: client, currentVersion: AppVersion("1.2.27")!)
        do {
            _ = try await service.check(repository: "samwang0041-star/WeChatHUD")
            XCTFail("Expected a rate-limit failure")
        } catch let error as AppUpdateError {
            XCTAssertEqual(error, .rateLimited)
            XCTAssertEqual(error.userMessage, "GitHub 的查询次数暂时用完了（同一网络共用额度），请过几分钟再试。也可以到发布页手动下载。")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectedCredentialStillReportsUnauthorized() async {
        // A 401 is a real answer about the credential, so it must not be
        // papered over by the public path.
        let client = StubClient(stubs: [StubClient.status(401)])
        let service = AppUpdateService(
            http: client,
            currentVersion: AppVersion("1.2.27")!,
            tokenProvider: { "bad-token" }
        )
        do {
            _ = try await service.check(repository: "samwang0041-star/WeChatHUD")
            XCTFail("Expected unauthorized")
        } catch let error as AppUpdateError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertEqual(client.requests.count, 1, "no fallback for a rejected credential")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpToDateOnTheWebPathDoesNotOfferAnUpdate() async throws {
        let client = StubClient(stubs: [
            StubClient.rateLimitedAPI,
            StubClient.redirect(to: "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.3.0")
        ])
        let service = AppUpdateService(http: client, currentVersion: AppVersion("1.3.0")!)
        let result = try await service.check(repository: "samwang0041-star/WeChatHUD")
        XCTAssertNil(result.offer)
        XCTAssertNil(result.unpublishedInstaller)
        XCTAssertEqual(client.requests.count, 2, "no asset listing when there is nothing newer")
    }

    func testPublishedTagWithoutInstallerIsReportedAsSuch() async throws {
        let html = "<li class=\"Box-row\"><span class=\"Truncate-text\">notes.txt</span></li>"
        let client = StubClient(stubs: [
            StubClient.rateLimitedAPI,
            StubClient.redirect(to: "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.4.0"),
            StubClient.html(html)
        ])
        let service = AppUpdateService(http: client, currentVersion: AppVersion("1.3.0")!)
        let result = try await service.check(repository: "samwang0041-star/WeChatHUD")
        XCTAssertNil(result.offer)
        XCTAssertEqual(result.unpublishedInstaller, AppVersion("1.4.0")!)
    }

    func testQuotaIsDetectedFromHeadersAndFromTheBody() {
        let url = URL(string: "https://api.github.com/repos/o/r/releases")!
        func response(headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        XCTAssertTrue(AppUpdateService.isRateLimited(
            response: response(headers: ["x-ratelimit-remaining": "0"]), body: Data()
        ))
        XCTAssertTrue(AppUpdateService.isRateLimited(
            response: response(headers: ["retry-after": "60"]), body: Data()
        ))
        XCTAssertTrue(AppUpdateService.isRateLimited(
            response: response(headers: [:]),
            body: Data(#"{"message":"API rate limit exceeded for 1.2.3.4."}"#.utf8)
        ))
        XCTAssertFalse(AppUpdateService.isRateLimited(
            response: response(headers: ["x-ratelimit-remaining": "42"]),
            body: Data(#"{"message":"Bad credentials"}"#.utf8)
        ))
    }

    func testAPIFailureKindsThatFallBack() {
        XCTAssertTrue(AppUpdateService.shouldFallBackToWeb(.rateLimited))
        XCTAssertTrue(AppUpdateService.shouldFallBackToWeb(.httpStatus(500)))
        XCTAssertTrue(AppUpdateService.shouldFallBackToWeb(.privateOrMissingRelease))
        XCTAssertFalse(AppUpdateService.shouldFallBackToWeb(.unauthorized))
        XCTAssertFalse(AppUpdateService.shouldFallBackToWeb(.checksumMismatch))
    }

    func testInstallerChoiceMatchesTheAPIChannel() {
        let names = [
            "source.zip",
            "WeChatHUD-1.3.0-macOS14-arm64.zip.sha256",
            "WeChatHUD-1.3.0-macOS14-x86_64.zip",
            "WeChatHUD-1.3.0-macOS14-arm64.zip"
        ]
        XCTAssertEqual(AppUpdateService.preferredInstaller(from: names), "WeChatHUD-1.3.0-macOS14-arm64.zip")
        XCTAssertNil(AppUpdateService.preferredInstaller(from: ["source.zip", "notes.txt"]))
    }

    /// Guards the source-level shape of the fallback: the API attempt has to
    /// hand over on quota and miss failures rather than turning them into
    /// advice about tokens, because that is what made a published release look
    /// unpublished.
    func testCheckFallsBackBySourceContract() throws {
        let source = try Self.appUpdateServiceSource()
        XCTAssertTrue(source.contains("checkViaWeb"), "the public channel must exist")
        XCTAssertTrue(source.contains("case .rateLimited, .httpStatus, .privateOrMissingRelease:"))
        XCTAssertTrue(source.contains("isRateLimited(response:"), "403 must be classified before it is reported")
    }

    /// Live check against the real repository, opt-in like the project's other
    /// network gates: no token, no stubs, the path a published copy takes on a
    /// rate-limited network.
    func testLiveUpdateCheckFindsThePublishedRelease() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WCHUD_LIVE_UPDATE_CHECK"] == "1",
            "set WCHUD_LIVE_UPDATE_CHECK=1 to run the live update check"
        )
        let service = AppUpdateService(
            currentVersion: AppVersion("1.2.27")!,
            tokenProvider: { nil }
        )
        let result = try await service.check(repository: "samwang0041-star/WeChatHUD")
        let offer = try XCTUnwrap(result.offer, "the published release must be found without a token")
        XCTAssertGreaterThan(offer.version, AppVersion("1.2.27")!)
        XCTAssertTrue(offer.asset.name.hasSuffix(".zip"), offer.asset.name)
        XCTAssertEqual(offer.asset.browserDownloadURL.host, "github.com")
        XCTAssertEqual(offer.checksumAsset?.name, offer.asset.name + ".sha256")
    }

    static func appUpdateServiceSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/Services/AppUpdateService.swift"),
            encoding: .utf8
        )
    }

    static let expandedAssetsHTML = """
    <li class="Box-row"><span class="Truncate-text">WeChatHUD-1.3.0-macOS14-arm64.zip</span>
    <a href="/owner/repo/releases/download/490123456/WeChatHUD-1.3.0-macOS14-arm64.zip">Download</a></li>
    <li class="Box-row"><span class="Truncate-text">WeChatHUD-1.3.0-macOS14-arm64.zip.sha256</span>
    <a href="/owner/repo/releases/download/490123457/WeChatHUD-1.3.0-macOS14-arm64.zip.sha256">Download</a></li>
    """
}

private final class StubClient: AppUpdateHTTPClient, @unchecked Sendable {
    struct Stub {
        var data: Data
        var response: URLResponse
    }

    private(set) var requests: [URLRequest] = []
    private var stubs: [Stub]

    init(stubs: [Stub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
        let stub = stubs.removeFirst()
        return (stub.data, stub.response)
    }

    static var rateLimitedAPI: Stub {
        Stub(
            data: Data(#"{"message":"API rate limit exceeded for 50.7.21.164."}"#.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://api.github.com/repos/o/r/releases?per_page=20")!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["x-ratelimit-remaining": "0", "Content-Type": "application/json"]
            )!
        )
    }

    static func status(_ code: Int) -> Stub {
        Stub(
            data: Data(#"{"message":"Bad credentials"}"#.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://api.github.com/repos/o/r/releases?per_page=20")!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
        )
    }

    static func redirect(to target: String) -> Stub {
        Stub(
            data: Data(),
            response: HTTPURLResponse(
                url: URL(string: "https://github.com/o/r/releases/latest")!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target]
            )!
        )
    }

    static func html(_ body: String) -> Stub {
        Stub(
            data: Data(body.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://github.com/o/r/releases/expanded_assets/v1.3.0")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"]
            )!
        )
    }
}
