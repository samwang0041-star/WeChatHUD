import Foundation
import CryptoKit
import Security

protocol AppUpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionAppUpdateClient: AppUpdateHTTPClient {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        // The public web channel reads the release tag out of the
        // `releases/latest` redirect, so redirects are reported instead of
        // followed. Downloads use pre-built URLs and are unaffected.
        let configuration = URLSessionConfiguration.ephemeral
        self.session = URLSession(
            configuration: configuration,
            delegate: RedirectInspectingDelegate(),
            delegateQueue: nil
        )
    }

    /// A client that follows redirects (the default URLSession behaviour).
    /// Downloads use pre-built URLs that always redirect once, so they need
    /// this instead of the redirect-inspecting default above.
    static func followingRedirects() -> URLSessionAppUpdateClient {
        URLSessionAppUpdateClient(session: URLSession(configuration: .ephemeral))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Reports redirect responses to the caller instead of following them, so the
/// public web channel can read `releases/latest` → `releases/tag/<tag>` from
/// the `Location` header.
private final class RedirectInspectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum AppUpdateError: Error, Equatable, LocalizedError {
    case previewMode
    case currentVersionUnknown
    case invalidRepository
    case unauthorized
    case rateLimited
    case privateOrMissingRelease
    case httpStatus(Int)
    case noInstallableAsset(String)
    case invalidDownloadURL
    case invalidArchive
    case bundleIdentityMismatch
    case destinationNotReplaceable
    case checksumMismatch
    case unsignedArchive
    case signatureMismatch
    case signingIdentityUnavailable
    case replaceFailed
    case restartFailed(String)

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .previewMode:
            return "演示模式不检查或安装更新"
        case .currentVersionUnknown:
            return "无法读取当前版本号"
        case .invalidRepository:
            return "发布仓库地址无效"
        case .unauthorized:
            return "GitHub 拒绝了这次读取，请稍后再试，也可以到发布页手动下载。"
        case .rateLimited:
            // Anonymous GitHub API calls are limited per IP, and that budget is
            // shared by everyone behind the same network. Saying so is the
            // difference between "I will retry in a few minutes" and "the
            // developer never published anything".
            return "GitHub 的查询次数暂时用完了（同一网络共用额度），请过几分钟再试。也可以到发布页手动下载。"
        case .privateOrMissingRelease:
            return "没有找到已发布的版本，或仓库尚未公开。"
        case .httpStatus:
            return "暂时无法检查更新，请稍后再试"
        case .noInstallableAsset(let version):
            return "已发布 \(version)，但还没有 macOS 安装包。"
        case .invalidDownloadURL:
            return "安装包地址无效"
        case .invalidArchive:
            return "下载的安装包无法打开"
        case .bundleIdentityMismatch:
            return "安装包与当前应用不匹配，已取消替换"
        case .destinationNotReplaceable:
            return "请从完整的应用打开后再安装更新"
        case .checksumMismatch:
            return "安装包校验失败，已取消替换"
        case .unsignedArchive:
            return "安装包没有通过代码签名校验，已取消替换"
        case .signatureMismatch:
            return "安装包的签名与当前应用不一致，已取消替换"
        case .signingIdentityUnavailable:
            return "无法确认当前应用的签名身份，请到发布页手动下载新版"
        case .replaceFailed:
            return "未能替换当前应用，原应用仍可使用"
        case .restartFailed:
            return "新版本已装好，请手动重新打开助手"
        }
    }
}

struct AppUpdateCheckResult: Equatable, Sendable {
    let offer: AppUpdateOffer?
    /// A published tag that is newer, but has no zip we can install.
    let unpublishedInstaller: AppVersion?
}

/// Fetches GitHub Releases and, when asked, downloads a zip and replaces this `.app`.
struct AppUpdateService {
    static let productionIdentifier = "com.wechat-cli.hud"
    static let previewIdentifier = "com.wechathud.product-preview"

    var http: any AppUpdateHTTPClient
    /// Downloads follow one 302 (API assets and releases/download both redirect
    /// to objects.githubusercontent.com), so they need a redirect-following
    /// client. `http` stays redirect-inspecting for `releases/latest` tag
    /// resolution.
    var downloadHTTP: any AppUpdateHTTPClient
    var currentVersion: AppVersion
    var currentBundleIdentifier: String
    var currentBundleURL: URL
    var userAgent: String
    var unzip: @Sendable (URL, URL) throws -> Void
    var fileManager: FileManager
    /// Tests install into temp folders. Production only replaces /Applications.
    var allowsNonApplicationDestination: Bool
    /// Returns the downloaded app's Team ID, throwing when it is not validly
    /// signed. Injectable so the download/replace tests can run without a
    /// Developer ID-signed fixture; the real implementation is the default.
    var signatureTeamIdentifier: @Sendable (URL) throws -> String?
    /// Team ID of the running app, nil when this build carries none.
    var runningTeamIdentifier: @Sendable () -> String?

    init(
        http: any AppUpdateHTTPClient = URLSessionAppUpdateClient(),
        downloadHTTP: (any AppUpdateHTTPClient)? = nil,
        currentVersion: AppVersion,
        currentBundleIdentifier: String = Bundle.main.bundleIdentifier ?? AppUpdateService.productionIdentifier,
        currentBundleURL: URL = Bundle.main.bundleURL,
        userAgent: String = AppUpdateService.defaultUserAgent(),
        unzip: @escaping @Sendable (URL, URL) throws -> Void = { archive, destination in
            try AppUpdateUnzip.ditto(archive: archive, destination: destination)
        },
        fileManager: FileManager = .default,
        allowsNonApplicationDestination: Bool = false,
        signatureTeamIdentifier: @escaping @Sendable (URL) throws -> String? = { url in
            try AppUpdateSignature.teamIdentifier(ofAppAt: url)
        },
        runningTeamIdentifier: @escaping @Sendable () -> String? = {
            AppUpdateSignature.runningTeamIdentifier()
        }
    ) {
        self.http = http
        // An explicit `downloadHTTP` wins (install tests wire their stub to
        // both). Otherwise downloads follow redirects with a real session.
        self.downloadHTTP = downloadHTTP ?? URLSessionAppUpdateClient.followingRedirects()
        self.currentVersion = currentVersion
        self.currentBundleIdentifier = currentBundleIdentifier
        self.currentBundleURL = currentBundleURL
        self.userAgent = userAgent
        self.unzip = unzip
        self.fileManager = fileManager
        self.allowsNonApplicationDestination = allowsNonApplicationDestination
        self.signatureTeamIdentifier = signatureTeamIdentifier
        self.runningTeamIdentifier = runningTeamIdentifier
    }

    static func defaultUserAgent(version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) -> String {
        "WeChatHUD/\(version ?? "dev") (macOS)"
    }

    static func runningVersion(from bundle: Bundle = .main) -> AppVersion? {
        let raw = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        return raw.flatMap(AppVersion.init)
    }

    func check(repository: String, includePrerelease: Bool = false) async throws -> AppUpdateCheckResult {
        guard let repo = AppUpdatePolicy.normalizedRepository(repository) else {
            throw AppUpdateError.invalidRepository
        }
        do {
            return try await checkViaAPI(repository: repo, includePrerelease: includePrerelease)
        } catch let error as AppUpdateError where Self.shouldFallBackToWeb(error) {
            // The REST API is rate limited per client IP — 60 requests an
            // hour for anonymous callers — and that budget is shared by
            // everyone behind the same NAT. A published app therefore cannot
            // treat a 403 here as "private repository": for most users it
            // just means the group's quota ran out. The public release pages
            // carry the same version and installers without a quota, so the
            // update check falls through to them instead of failing.
            return try await checkViaWeb(repository: repo)
        }
    }

    /// True when the API failure says nothing about whether a release
    /// exists, so the public pages should be asked instead.
    static func shouldFallBackToWeb(_ error: AppUpdateError) -> Bool {
        switch error {
        case .rateLimited, .httpStatus, .privateOrMissingRelease:
            return true
        case .unauthorized:
            // A 401 carries no signal about whether a release exists, so the
            // web channel stays out of it and the failure is reported as-is.
            return false
        default:
            return false
        }
    }

    private func checkViaAPI(repository repo: String, includePrerelease: Bool) async throws -> AppUpdateCheckResult {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 403:
            // Distinguish "you are not allowed" from "you are over quota":
            // GitHub signals the latter with rate-limit headers and a body that
            // says so.
            throw Self.isRateLimited(response: response, body: data)
                ? AppUpdateError.rateLimited
                : AppUpdateError.unauthorized
        case 401:
            throw AppUpdateError.unauthorized
        case 404:
            throw AppUpdateError.privateOrMissingRelease
        default:
            throw AppUpdateError.httpStatus(status)
        }

        let releases = try GitHubReleaseFeed.parseList(data)
        if let offer = GitHubReleaseFeed.offer(in: releases, current: currentVersion, includePrerelease: includePrerelease) {
            return AppUpdateCheckResult(offer: offer, unpublishedInstaller: nil)
        }

        let newerWithoutZip = releases
            .filter { !$0.draft }
            .filter { includePrerelease || !$0.prerelease }
            .compactMap { AppVersion($0.tagName) ?? AppVersion($0.name) }
            .filter { $0 > currentVersion }
            .max()
        return AppUpdateCheckResult(offer: nil, unpublishedInstaller: newerWithoutZip)
    }

    /// GitHub reports an exhausted quota with `x-ratelimit-remaining: 0`, and
    /// in the body it names the limit. Either signal is enough.
    static func isRateLimited(response: URLResponse, body: Data) -> Bool {
        if let http = response as? HTTPURLResponse {
            if let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining"), remaining == "0" {
                return true
            }
            if let retry = http.value(forHTTPHeaderField: "retry-after"), !retry.isEmpty {
                return true
            }
        }
        let text = String(data: body.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        return text.contains("rate limit");
    }

    // MARK: Public web channel

    /// Reads the newest release from the public release pages. One request
    /// resolves `releases/latest` to a tag; a second lists that release's
    /// uploaded files. No quota, no credentials.
    private func checkViaWeb(repository repo: String) async throws -> AppUpdateCheckResult {
        guard let latestURL = GitHubReleaseWebFeed.latestReleaseURL(repository: repo) else {
            throw AppUpdateError.invalidRepository
        }
        let tag = try await resolveLatestTag(from: latestURL)
        guard let version = AppVersion(tag) else {
            throw AppUpdateError.httpStatus(0)
        }
        guard version > currentVersion else {
            return AppUpdateCheckResult(offer: nil, unpublishedInstaller: nil)
        }

        let names = try await installerNames(repository: repo, tag: tag)
        guard let installer = Self.preferredInstaller(from: names),
              let url = GitHubReleaseWebFeed.downloadURL(repository: repo, tag: tag, assetName: installer) else {
            // The release exists but carries nothing installable — the same
            // distinction the API path reports.
            return AppUpdateCheckResult(offer: nil, unpublishedInstaller: version)
        }

        let checksum = names.first { $0.lowercased() == installer.lowercased() + ".sha256" }
        let htmlURL = URL(string: GitHubReleaseWebFeed.baseURL + "/" + repo + "/releases/tag/" + tag) ?? latestURL
        let offer = AppUpdateOffer(
            version: version,
            tagName: tag,
            htmlURL: htmlURL,
            // Notes live on the release page; the app links there rather than
            // re-rendering HTML it would first have to sanitize.
            notes: "",
            asset: GitHubReleaseAsset(
                id: 0,
                name: installer,
                browserDownloadURL: url,
                apiURL: nil,
                size: 0,
                state: "uploaded"
            ),
            checksumAsset: checksum.flatMap { name in
                GitHubReleaseWebFeed.downloadURL(repository: repo, tag: tag, assetName: name).map {
                    GitHubReleaseAsset(id: 0, name: name, browserDownloadURL: $0, apiURL: nil, size: 0, state: "uploaded")
                }
            }
        )
        return AppUpdateCheckResult(offer: offer, unpublishedInstaller: nil)
    }

    /// Resolves `releases/latest` to its tag, using whichever the response
    /// exposes: the redirect header, the final URL, or the page itself.
    private func resolveLatestTag(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch status {
        case 200, 301, 302, 303, 307, 308:
            break
        case 404:
            throw AppUpdateError.privateOrMissingRelease
        case 403, 429:
            throw AppUpdateError.rateLimited
        default:
            throw AppUpdateError.httpStatus(status)
        }
        if let location = http?.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: url)?.absoluteURL,
           let tag = GitHubReleaseWebFeed.tag(fromResolvedLatestURL: target) {
            return tag
        }
        if let finalURL = http?.url, let tag = GitHubReleaseWebFeed.tag(fromResolvedLatestURL: finalURL) {
            return tag
        }
        if let html = String(data: data, encoding: .utf8), let tag = Self.tagFromReleasePage(html) {
            return tag
        }
        throw AppUpdateError.httpStatus(status)
    }

    private func installerNames(repository repo: String, tag: String) async throws -> [String] {
        guard let url = GitHubReleaseWebFeed.expandedAssetsURL(repository: repo, tag: tag) else {
            throw AppUpdateError.httpStatus(0)
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 404:
            throw AppUpdateError.privateOrMissingRelease
        case 403, 429:
            throw AppUpdateError.rateLimited
        default:
            throw AppUpdateError.httpStatus(status)
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        return ExpandedAssetsParser.parse(html).names
    }

    /// Picks the installer out of a release's file list with the same scoring
    /// the API path uses, so both channels agree on what is installable.
    static func preferredInstaller(from names: [String]) -> String? {
        let installers = names.filter { name in
            let lowered = name.lowercased()
            guard lowered.hasSuffix(".zip") else { return false }
            if lowered.contains("sha256") || lowered.contains("source") { return false }
            return true
        }
        return installers.max { GitHubReleaseFeed.assetScore($0) < GitHubReleaseFeed.assetScore($1) }
    }

    static func tagFromReleasePage(_ html: String) -> String? {
        // The page can link more than one release (sidebar, footer). Collect
        // every tag candidate and prefer the highest version: this fallback
        // only runs when the redirect itself gave no tag, and resolving to an
        // older tag fails safe (fewer upgrades, never a wrong install — the
        // installer still comes from that tag's own asset list).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/+"))
        var candidates: [String] = []
        var searchFrom = html.startIndex
        while let marker = html.range(of: "/releases/tag/", range: searchFrom..<html.endIndex) {
            let rest = html[marker.upperBound...]
            let tag = String(rest.prefix { $0.unicodeScalars.allSatisfy(allowed.contains) })
            if !tag.isEmpty { candidates.append(tag) }
            searchFrom = marker.upperBound
        }
        let versions: [(AppVersion, String)] = candidates.compactMap { tag in
            AppVersion(tag).map { ($0, tag) }
        }
        if let best = versions.sorted(by: { $0.0 < $1.0 }).last { return best.1 }
        return candidates.first
    }

    func install(_ offer: AppUpdateOffer, destination: URL? = nil) async throws -> URL {
        if PreviewRuntime.isEnabled || currentBundleIdentifier == Self.previewIdentifier {
            throw AppUpdateError.previewMode
        }
        let dest = (destination ?? currentBundleURL).standardizedFileURL
        try Self.validateDestination(
            dest,
            identifier: currentBundleIdentifier,
            allowNonApplicationDestination: allowsNonApplicationDestination
        )

        guard GitHubReleaseFeed.downloadURL(for: offer.asset) != nil else {
            throw AppUpdateError.invalidDownloadURL
        }

        let work = fileManager.temporaryDirectory.appendingPathComponent("WeChatHUD-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let archive = work.appendingPathComponent(offer.asset.name)
        try await download(asset: offer.asset, to: archive)
        if let checksum = offer.checksumAsset {
            let sidecar = work.appendingPathComponent(checksum.name)
            try await download(asset: checksum, to: sidecar)
            let expected = GitHubReleaseFeed.parseSHA256Manifest(try Data(contentsOf: sidecar))
            let actual = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected == actual else {
                throw AppUpdateError.checksumMismatch
            }
        }

        let extract = work.appendingPathComponent("extract")
        try fileManager.createDirectory(at: extract, withIntermediateDirectories: true)
        try unzip(archive, extract)

        let incoming = try findApp(in: extract)
        try verifyIncomingApp(incoming, expectedVersion: offer.version)
        try verifyIncomingSignature(of: incoming)

        try replace(destination: dest, with: incoming)
        return dest.standardizedFileURL
    }

    static func validateDestination(
        _ url: URL,
        identifier: String,
        allowNonApplicationDestination: Bool = false
    ) throws {
        if identifier == previewIdentifier {
            throw AppUpdateError.previewMode
        }
        let path = url.path
        if url.pathExtension.lowercased() != "app" {
            throw AppUpdateError.destinationNotReplaceable
        }
        if path.localizedCaseInsensitiveContains("Preview.app") {
            throw AppUpdateError.previewMode
        }
        if !allowNonApplicationDestination, !isTrustedInstallLocation(url) {
            throw AppUpdateError.destinationNotReplaceable
        }
    }

    static func isTrustedInstallLocation(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
        return parent.path == applications.path || parent.path == userApplications.path
    }

    private func download(asset: GitHubReleaseAsset, to file: URL) async throws {
        // Public releases only: the browser download URL needs no credential
        // and redirects once to the objects host, which the following-
        // redirects download client handles.
        guard let url = GitHubReleaseFeed.downloadURL(for: asset) else {
            throw AppUpdateError.invalidDownloadURL
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await downloadHTTP.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            try data.write(to: file, options: .atomic)
        case 401:
            throw AppUpdateError.unauthorized
        case 403:
            throw Self.isRateLimited(response: response, body: data)
                ? AppUpdateError.rateLimited
                : AppUpdateError.unauthorized
        case 404:
            throw AppUpdateError.privateOrMissingRelease
        default:
            throw AppUpdateError.httpStatus(status)
        }
    }

    func findApp(in root: URL) throws -> URL {
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var candidates: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "app",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            enumerator?.skipDescendants()
            candidates.append(url)
        }
        if let named = candidates.first(where: { $0.lastPathComponent.lowercased().contains("wechathud") }) {
            return named
        }
        if let only = candidates.first, candidates.count == 1 {
            return only
        }
        throw AppUpdateError.invalidArchive
    }

    func verifyIncomingApp(_ app: URL, expectedVersion: AppVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any],
              let identifier = dict["CFBundleIdentifier"] as? String else {
            throw AppUpdateError.invalidArchive
        }
        if identifier == Self.previewIdentifier {
            throw AppUpdateError.bundleIdentityMismatch
        }
        guard identifier == currentBundleIdentifier || identifier == Self.productionIdentifier else {
            throw AppUpdateError.bundleIdentityMismatch
        }
        let versionRaw = (dict["CFBundleShortVersionString"] as? String) ?? ""
        guard let version = AppVersion(versionRaw), version >= expectedVersion else {
            throw AppUpdateError.bundleIdentityMismatch
        }
    }

    /// Pin the downloaded app to this build's signing identity.
    ///
    /// Nothing else here proves who built the archive: `verifyIncomingApp` reads
    /// bundle identity and version out of the bundle being installed, so a
    /// tampered release satisfies them, and the optional `.sha256` sidecar
    /// travels in the same release as the archive it validates (it detects a
    /// truncated download, not a substituted release). The archive must
    /// therefore be validly signed, and when this build carries a Team ID the
    /// two must match. A build with no identity of its own cannot pin anything,
    /// and refuses rather than accepting an unknown archive.
    func verifyIncomingSignature(of app: URL) throws {
        // Check our own identity first: an ad-hoc/local build cannot pin
        // anything, and reporting `signingIdentityUnavailable` (not
        // `unsignedArchive`) tells the user the real reason updates refuse.
        guard let runningTeam = runningTeamIdentifier() else {
            throw AppUpdateError.signingIdentityUnavailable
        }
        let incomingTeam = try signatureTeamIdentifier(app)
        guard incomingTeam == runningTeam else {
            throw AppUpdateError.signatureMismatch
        }
    }

    func replace(destination dest: URL, with incoming: URL) throws {
        let parent = dest.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(".\(dest.lastPathComponent).update-backup")
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }

        var didMoveOriginal = false
        do {
            if fileManager.fileExists(atPath: dest.path) {
                try relocate(dest, to: backup)
                didMoveOriginal = true
            }
            try relocate(incoming, to: dest)
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if didMoveOriginal, fileManager.fileExists(atPath: backup.path) {
                if fileManager.fileExists(atPath: dest.path) {
                    try? fileManager.removeItem(at: dest)
                }
                try? relocate(backup, to: dest)
            }
            throw AppUpdateError.replaceFailed
        }
    }

    private func relocate(_ from: URL, to: URL) throws {
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        do {
            try fileManager.moveItem(at: from, to: to)
        } catch {
            try fileManager.copyItem(at: from, to: to)
            try? fileManager.removeItem(at: from)
        }
    }
}

enum AppUpdateUnzip {
    static func ditto(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.invalidArchive
        }
    }
}

/// Static code-signature checks for the self-updater.
enum AppUpdateSignature {
    /// Team identifier of the running process's code, or nil when this build
    /// has no Developer ID signature (locally built or ad-hoc signed).
    static func runningTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        // SecCodeRef and SecStaticCodeRef are the same C struct
        // (struct __SecCode); the signing-information accessor is only declared
        // for the static variant, so reinterpret the reference.
        return teamIdentifier(of: unsafeBitCast(selfCode, to: SecStaticCode.self))
    }

    /// Validates `app` as a static code object and returns its Team ID
    /// (`nil` for an ad-hoc signature).
    ///
    /// `SecStaticCodeCheckValidity` verifies the signature over the main
    /// executable and every sealed resource in the bundle, so an edited binary
    /// or an injected component fails here even though the Info.plist still
    /// looks right. `kSecCSCheckAllArchitectures` validates the universal
    /// binary as a whole instead of one slice, and `kSecCSStrictValidate`
    /// looks right. `kSecCSCheckNestedCode` extends the check into nested
    /// code (Frameworks, Helpers, XPC services) so a swapped nested
    /// component fails here too. `kSecCSCheckAllArchitectures` validates the
    /// universal binary as a whole instead of one slice, and
    /// `kSecCSStrictValidate` rejects a bundle that carries unsealed content
    /// where the signature says there should be none.
    static func teamIdentifier(ofAppAt url: URL) throws -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw AppUpdateError.unsignedArchive
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            throw AppUpdateError.unsignedArchive
        }
        guard let team = teamIdentifier(of: staticCode), !team.isEmpty else { return nil }
        return team
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        let trimmed = team.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
