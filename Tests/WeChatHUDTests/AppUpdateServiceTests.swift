import CryptoKit
import XCTest
@testable import WeChatHUD

final class AppUpdateServiceTests: XCTestCase {
    func testParsesVersionPrefixAndPreReleaseSuffix() throws {
        XCTAssertEqual(AppVersion("v1.2.0"), AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(AppVersion("1.2"), AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(AppVersion("1.3.0-beta.1"), AppVersion(major: 1, minor: 3, patch: 0, isPrerelease: true))
        XCTAssertTrue(AppVersion("1.2.0")! < AppVersion("1.3.0")!)
        XCTAssertTrue(AppVersion("1.9.0")! < AppVersion("1.10.0")!)
        XCTAssertTrue(AppVersion("1.3.0-beta.1")! < AppVersion("1.3.0")!)
        XCTAssertFalse(AppVersion("1.3.0")! < AppVersion("1.3.0-beta.1")!)
        let decoded = try JSONDecoder().decode(AppVersion.self, from: Data(#"{"major":1,"minor":2,"patch":0}"#.utf8))
        XCTAssertEqual(decoded, AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertFalse(decoded.isPrerelease)
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("release"))
    }

    func testShouldCheckWaitsAFullDayUnlessForcedByMissingDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AppUpdatePolicy.shouldCheck(lastCheck: nil, now: now))
        XCTAssertFalse(AppUpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(AppUpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(-86_400), now: now))
    }

    func testRejectsMalformedRepository() {
        XCTAssertEqual(AppUpdatePolicy.normalizedRepository("samwang0041-star/WeChatHUD"), "samwang0041-star/WeChatHUD")
        XCTAssertNil(AppUpdatePolicy.normalizedRepository("https://github.com/samwang0041-star/WeChatHUD"))
        XCTAssertNil(AppUpdatePolicy.normalizedRepository("owner/repo/extra"))
        XCTAssertNil(AppUpdatePolicy.normalizedRepository("../etc/passwd"))
    }

    func testSelectsArm64ZipAndIgnoresDraftOrOlderReleases() throws {
        let releases = try GitHubReleaseFeed.parseList(Self.releaseListJSON)
        let offer = GitHubReleaseFeed.offer(in: releases, current: AppVersion("1.2.0")!)
        XCTAssertEqual(offer?.version, AppVersion("1.3.0"))
        XCTAssertEqual(offer?.asset.name, "WeChatHUD-1.3.0-macOS14-arm64.zip")
        XCTAssertEqual(offer?.checksumAsset?.name, "WeChatHUD-1.3.0-macOS14-arm64.zip.sha256")
        XCTAssertNil(GitHubReleaseFeed.offer(in: releases, current: AppVersion("1.3.0")!))
        let fromBeta = GitHubReleaseFeed.offer(in: releases, current: AppVersion("1.3.0-beta.1")!)
        XCTAssertEqual(fromBeta?.version, AppVersion("1.3.0"))
    }

    func testSkipsPrereleaseUnlessAsked() throws {
        let releases = try GitHubReleaseFeed.parseList(Self.prereleaseJSON)
        XCTAssertNil(GitHubReleaseFeed.offer(in: releases, current: AppVersion("1.2.0")!))
        let offer = GitHubReleaseFeed.offer(in: releases, current: AppVersion("1.2.0")!, includePrerelease: true)
        XCTAssertEqual(offer?.version, AppVersion("1.4.0-beta.1"))
    }

    func testCheckSendsGitHubHeadersAndBearerToken() async throws {
        let client = MockUpdateClient(responses: [
            MockUpdateClient.response(status: 200, body: Self.releaseListJSON, url: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases?per_page=20")
        ])
        let service = AppUpdateService(
            http: client,
            currentVersion: AppVersion("1.2.0")!,
            tokenProvider: { "secret-token" },
            userAgent: "WeChatHUD/1.2.0 (macOS)"
        )

        let result = try await service.check(repository: "samwang0041-star/WeChatHUD")
        XCTAssertEqual(result.offer?.version, AppVersion("1.3.0"))
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "User-Agent"), "WeChatHUD/1.2.0 (macOS)")
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertFalse((client.requests[0].url?.absoluteString ?? "").contains("secret-token"))
    }

    func testPrivateRepoStatusBecomesUnauthorized() async {
        let client = MockUpdateClient(responses: [
            MockUpdateClient.response(status: 401, body: Data("{}".utf8), url: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases?per_page=20")
        ])
        let service = AppUpdateService(http: client, currentVersion: AppVersion("1.2.0")!)
        do {
            _ = try await service.check(repository: "samwang0041-star/WeChatHUD")
            XCTFail("Expected unauthorized")
        } catch let error as AppUpdateError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingZipReportsUnpublishedInstaller() async throws {
        let client = MockUpdateClient(responses: [
            MockUpdateClient.response(status: 200, body: Self.releaseWithoutZipJSON, url: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases?per_page=20")
        ])
        let service = AppUpdateService(http: client, currentVersion: AppVersion("1.2.0")!)
        let result = try await service.check(repository: "samwang0041-star/WeChatHUD")
        XCTAssertNil(result.offer)
        XCTAssertEqual(result.unpublishedInstaller, AppVersion("1.3.0"))
    }

    func testExtractsAndReplacesAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let incoming = try makeFakeApp(
            at: root.appendingPathComponent("incoming/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.3.0"
        )
        let current = try makeFakeApp(
            at: root.appendingPathComponent("Applications/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.2.0"
        )
        try Data("old".utf8).write(to: current.appendingPathComponent("Contents/MacOS/marker"))
        try Data("new".utf8).write(to: incoming.appendingPathComponent("Contents/MacOS/marker"))

        let service = AppUpdateService(
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: current
        )
        try service.verifyIncomingApp(incoming, expectedVersion: AppVersion("1.3.0")!)
        try service.replace(destination: current, with: incoming)

        let marker = try String(contentsOf: current.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
        XCTAssertEqual(marker, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Applications/.WeChatHUD.app.update-backup").path))
    }

    func testUnzipFindsPackagedApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeFakeApp(
            at: root.appendingPathComponent("WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.3.0"
        )
        let zip = root.appendingPathComponent("WeChatHUD-1.3.0-macOS14-arm64.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        XCTAssertEqual(zipProcess.terminationStatus, 0)

        let extract = root.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        try AppUpdateUnzip.ditto(archive: zip, destination: extract)
        let service = AppUpdateService(
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: app
        )
        let found = try service.findApp(in: extract)
        XCTAssertEqual(found.lastPathComponent, "WeChatHUD.app")
        try service.verifyIncomingApp(found, expectedVersion: AppVersion("1.3.0")!)
    }

    func testRefusesPreviewDestinationAndMismatchedBundle() throws {
        XCTAssertThrowsError(try AppUpdateService.validateDestination(
            URL(fileURLWithPath: "/tmp/WeChatHUD Preview.app"),
            identifier: AppUpdateService.productionIdentifier
        )) { error in
            XCTAssertEqual(error as? AppUpdateError, .previewMode)
        }
        XCTAssertThrowsError(try AppUpdateService.validateDestination(
            URL(fileURLWithPath: "/tmp/DerivedData/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier
        )) { error in
            XCTAssertEqual(error as? AppUpdateError, .destinationNotReplaceable)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = try makeFakeApp(
            at: root.appendingPathComponent("Other.app"),
            identifier: "com.example.other",
            version: "9.0.0"
        )
        let service = AppUpdateService(
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: incoming
        )
        XCTAssertThrowsError(try service.verifyIncomingApp(incoming, expectedVersion: AppVersion("1.3.0")!)) { error in
            XCTAssertEqual(error as? AppUpdateError, .bundleIdentityMismatch)
        }
    }

    func testInstallDownloadsHttpsAssetThenReplaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let incoming = try makeFakeApp(
            at: root.appendingPathComponent("incoming/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.3.0"
        )
        let current = try makeFakeApp(
            at: root.appendingPathComponent("Applications/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.2.0"
        )
        let zip = root.appendingPathComponent("WeChatHUD-1.3.0-macOS14-arm64.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-c", "-k", "--keepParent", incoming.path, zip.path]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        XCTAssertEqual(zipProcess.terminationStatus, 0)

        let zipData = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let sidecar = Data("\(digest)  WeChatHUD-1.3.0-macOS14-arm64.zip\n".utf8)
        let client = MockUpdateClient(responses: [
            MockUpdateClient.response(
                status: 200,
                body: zipData,
                url: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/9"
            ),
            MockUpdateClient.response(
                status: 200,
                body: sidecar,
                url: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/10"
            )
        ])
        let service = AppUpdateService(
            http: client,
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: current,
            tokenProvider: { "secret-token" },
            allowsNonApplicationDestination: true
        )
        let offer = AppUpdateOffer(
            version: AppVersion("1.3.0")!,
            tagName: "v1.3.0",
            htmlURL: URL(string: "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.3.0")!,
            notes: "fixes",
            asset: GitHubReleaseAsset(
                id: 9,
                name: "WeChatHUD-1.3.0-macOS14-arm64.zip",
                browserDownloadURL: URL(string: "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip")!,
                apiURL: URL(string: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/9")!,
                size: zipData.count,
                state: "uploaded"
            ),
            checksumAsset: GitHubReleaseAsset(
                id: 10,
                name: "WeChatHUD-1.3.0-macOS14-arm64.zip.sha256",
                browserDownloadURL: URL(string: "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip.sha256")!,
                apiURL: URL(string: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/10")!,
                size: sidecar.count,
                state: "uploaded"
            )
        )

        let installed = try await service.install(offer, destination: current)
        XCTAssertEqual(installed.standardizedFileURL.path, current.standardizedFileURL.path)
        XCTAssertEqual(client.requests[0].url?.absoluteString, "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/9")
        XCTAssertEqual(client.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        let plist = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(plist?["CFBundleShortVersionString"] as? String, "1.3.0")
    }

    func testInstallRejectsChecksumMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-badhash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = try makeFakeApp(
            at: root.appendingPathComponent("incoming/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.3.0"
        )
        let current = try makeFakeApp(
            at: root.appendingPathComponent("Applications/WeChatHUD.app"),
            identifier: AppUpdateService.productionIdentifier,
            version: "1.2.0"
        )
        let zip = root.appendingPathComponent("WeChatHUD-1.3.0-macOS14-arm64.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-c", "-k", "--keepParent", incoming.path, zip.path]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        let zipData = try Data(contentsOf: zip)
        let client = MockUpdateClient(responses: [
            MockUpdateClient.response(status: 200, body: zipData, url: "https://github.com/x/y/z.zip"),
            MockUpdateClient.response(status: 200, body: Data("0000000000000000000000000000000000000000000000000000000000000000  z.zip\n".utf8), url: "https://github.com/x/y/z.zip.sha256")
        ])
        let service = AppUpdateService(
            http: client,
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: current,
            allowsNonApplicationDestination: true
        )
        let offer = AppUpdateOffer(
            version: AppVersion("1.3.0")!,
            tagName: "v1.3.0",
            htmlURL: URL(string: "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.3.0")!,
            notes: "",
            asset: GitHubReleaseAsset(
                id: 1,
                name: "WeChatHUD-1.3.0-macOS14-arm64.zip",
                browserDownloadURL: URL(string: "https://github.com/x/y/z.zip")!,
                apiURL: nil,
                size: zipData.count,
                state: "uploaded"
            ),
            checksumAsset: GitHubReleaseAsset(
                id: 2,
                name: "WeChatHUD-1.3.0-macOS14-arm64.zip.sha256",
                browserDownloadURL: URL(string: "https://github.com/x/y/z.zip.sha256")!,
                apiURL: nil,
                size: 80,
                state: "uploaded"
            )
        )
        do {
            _ = try await service.install(offer, destination: current)
            XCTFail("Expected checksum mismatch")
        } catch let error as AppUpdateError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        let markerPlist = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(markerPlist?["CFBundleShortVersionString"] as? String, "1.2.0")
    }

    func testDeviceSettingsKeepsUpdateKey() {
        XCTAssertTrue(DeviceSettingsStore.sharedKeys.contains("update"))
    }

    @MainActor
    func testControllerPersistsCheckTimestampAndOffer() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("update-store-\(UUID().uuidString).sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        defer { store.close() }

        let client = MockUpdateClient(responses: [
            MockUpdateClient.response(status: 200, body: Self.releaseListJSON, url: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases?per_page=20")
        ])
        let controller = AppUpdateController()
        controller.serviceOverride = AppUpdateService(
            http: client,
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: URL(fileURLWithPath: "/Applications/WeChatHUD.app")
        )
        controller.bind(store: store)
        await controller.check(force: true, installIfEnabled: false)

        XCTAssertEqual(controller.phase, .available)
        XCTAssertEqual(controller.offer?.version, AppVersion("1.3.0"))
        let saved = store.getSettingJSON(AppUpdateConfig.settingKey, as: AppUpdateConfig.self)
        XCTAssertNotNil(saved?.lastCheckAt)
        XCTAssertEqual(saved?.pendingOffer?.version, AppVersion("1.3.0"))

        let restored = AppUpdateController()
        restored.bind(store: store)
        XCTAssertEqual(restored.offer?.version, AppVersion("1.3.0"))
        XCTAssertEqual(restored.phase, .available)
        XCTAssertTrue(AppUpdatePolicy.shouldCheck(
            lastCheck: saved?.lastCheckDate,
            now: Date(),
            hasPendingOffer: saved?.pendingOffer != nil
        ))
    }

    func testParsesSHA256Sidecar() {
        XCTAssertEqual(
            GitHubReleaseFeed.parseSHA256Manifest(Data("abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd  WeChatHUD.zip\n".utf8)),
            "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
        )
        XCTAssertNil(GitHubReleaseFeed.parseSHA256Manifest(Data("not-a-hash".utf8)))
    }

    func testPrivateAssetDownloadUsesAPIURLWhenTokenPresent() {
        let asset = GitHubReleaseAsset(
            id: 9,
            name: "WeChatHUD-1.3.0-macOS14-arm64.zip",
            browserDownloadURL: URL(string: "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip")!,
            apiURL: URL(string: "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/9")!,
            size: 12,
            state: "uploaded"
        )
        XCTAssertEqual(
            GitHubReleaseFeed.downloadURL(for: asset, hasToken: true)?.absoluteString,
            "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/9"
        )
        XCTAssertEqual(
            GitHubReleaseFeed.downloadURL(for: asset, hasToken: false)?.absoluteString,
            asset.browserDownloadURL.absoluteString
        )
    }

    private func makeFakeApp(at url: URL, identifier: String, version: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(version)</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        return url
    }
}

private final class MockUpdateClient: AppUpdateHTTPClient, @unchecked Sendable {
    struct Stub {
        let data: Data
        let response: URLResponse
    }

    private(set) var requests: [URLRequest] = []
    private var stubs: [Stub]

    init(responses: [Stub]) {
        self.stubs = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
        let stub = stubs.removeFirst()
        return (stub.data, stub.response)
    }

    static func response(status: Int, body: Data, url: String) -> Stub {
        let resp = HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return Stub(data: body, response: resp)
    }
}

private extension AppUpdateServiceTests {
    static let releaseListJSON = Data("""
    [
      {
        "tag_name": "v1.3.0",
        "name": "1.3.0",
        "draft": false,
        "prerelease": false,
        "html_url": "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.3.0",
        "body": "stability",
        "assets": [
          {
            "id": 1,
            "name": "WeChatHUD-1.3.0-macOS14-arm64.zip",
            "browser_download_url": "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip",
            "url": "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/1",
            "size": 12,
            "state": "uploaded"
          },
          {
            "id": 2,
            "name": "WeChatHUD-1.3.0-macOS14-arm64.zip.sha256",
            "browser_download_url": "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.3.0/WeChatHUD-1.3.0-macOS14-arm64.zip.sha256",
            "url": "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/2",
            "size": 64,
            "state": "uploaded"
          },
          {
            "id": 3,
            "name": "Source code.zip",
            "browser_download_url": "https://github.com/samwang0041-star/WeChatHUD/archive/refs/tags/v1.3.0.zip",
            "url": "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/3",
            "size": 8,
            "state": "uploaded"
          }
        ]
      },
      {
        "tag_name": "v1.4.0",
        "name": "1.4.0",
        "draft": true,
        "prerelease": false,
        "html_url": "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.4.0",
        "body": "draft",
        "assets": [
          {
            "id": 4,
            "name": "WeChatHUD-1.4.0-macOS14-arm64.zip",
            "browser_download_url": "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.4.0/WeChatHUD-1.4.0-macOS14-arm64.zip",
            "url": "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/4",
            "size": 12,
            "state": "uploaded"
          }
        ]
      },
      {
        "tag_name": "v1.1.0",
        "name": "1.1.0",
        "draft": false,
        "prerelease": false,
        "html_url": "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.1.0",
        "body": "old",
        "assets": [
          {
            "id": 5,
            "name": "WeChatHUD-1.1.0-macOS14-arm64.zip",
            "browser_download_url": "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.1.0/WeChatHUD-1.1.0-macOS14-arm64.zip",
            "url": "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/5",
            "size": 12,
            "state": "uploaded"
          }
        ]
      }
    ]
    """.utf8)

    static let prereleaseJSON = Data("""
    [
      {
        "tag_name": "v1.4.0-beta.1",
        "name": "1.4.0-beta.1",
        "draft": false,
        "prerelease": true,
        "html_url": "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.4.0-beta.1",
        "body": "beta",
        "assets": [
          {
            "id": 8,
            "name": "WeChatHUD-1.4.0-macOS14-arm64.zip",
            "browser_download_url": "https://github.com/samwang0041-star/WeChatHUD/releases/download/v1.4.0-beta.1/WeChatHUD-1.4.0-macOS14-arm64.zip",
            "url": "https://api.github.com/repos/samwang0041-star/WeChatHUD/releases/assets/8",
            "size": 12,
            "state": "uploaded"
          }
        ]
      }
    ]
    """.utf8)

    static let releaseWithoutZipJSON = Data("""
    [
      {
        "tag_name": "v1.3.0",
        "name": "1.3.0",
        "draft": false,
        "prerelease": false,
        "html_url": "https://github.com/samwang0041-star/WeChatHUD/releases/tag/v1.3.0",
        "body": "notes only",
        "assets": []
      }
    ]
    """.utf8)
}
