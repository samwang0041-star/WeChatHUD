import Foundation
import CryptoKit

protocol AppUpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionAppUpdateClient: AppUpdateHTTPClient {
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum AppUpdateError: Error, Equatable, LocalizedError {
    case previewMode
    case currentVersionUnknown
    case invalidRepository
    case unauthorized
    case privateOrMissingRelease
    case httpStatus(Int)
    case noInstallableAsset(String)
    case invalidDownloadURL
    case invalidArchive
    case bundleIdentityMismatch
    case destinationNotReplaceable
    case checksumMismatch
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
            return "GitHub 拒绝访问。私有仓库需要填写具有读取权限的 Token。"
        case .privateOrMissingRelease:
            return "还没有可安装的新版本，或仓库尚未公开发布。"
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
    var currentVersion: AppVersion
    var currentBundleIdentifier: String
    var currentBundleURL: URL
    var tokenProvider: @Sendable () -> String?
    var userAgent: String
    var unzip: @Sendable (URL, URL) throws -> Void
    var fileManager: FileManager
    /// Tests install into temp folders. Production only replaces /Applications.
    var allowsNonApplicationDestination: Bool

    init(
        http: any AppUpdateHTTPClient = URLSessionAppUpdateClient(),
        currentVersion: AppVersion,
        currentBundleIdentifier: String = Bundle.main.bundleIdentifier ?? AppUpdateService.productionIdentifier,
        currentBundleURL: URL = Bundle.main.bundleURL,
        tokenProvider: @escaping @Sendable () -> String? = { nil },
        userAgent: String = AppUpdateService.defaultUserAgent(),
        unzip: @escaping @Sendable (URL, URL) throws -> Void = { archive, destination in
            try AppUpdateUnzip.ditto(archive: archive, destination: destination)
        },
        fileManager: FileManager = .default,
        allowsNonApplicationDestination: Bool = false
    ) {
        self.http = http
        self.currentVersion = currentVersion
        self.currentBundleIdentifier = currentBundleIdentifier
        self.currentBundleURL = currentBundleURL
        self.tokenProvider = tokenProvider
        self.userAgent = userAgent
        self.unzip = unzip
        self.fileManager = fileManager
        self.allowsNonApplicationDestination = allowsNonApplicationDestination
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
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token = resolvedToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 401, 403:
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

        guard GitHubReleaseFeed.downloadURL(for: offer.asset, hasToken: resolvedToken() != nil) != nil else {
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

    func resolvedToken() -> String? {
        let candidates = [
            tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
            ProcessInfo.processInfo.environment["GH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            ProcessInfo.processInfo.environment["GITHUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return candidates.first(where: { token in
            guard let token, !token.isEmpty else { return false }
            return true
        }) ?? nil
    }

    private func download(asset: GitHubReleaseAsset, to file: URL) async throws {
        let token = resolvedToken()
        guard let url = GitHubReleaseFeed.downloadURL(for: asset, hasToken: token != nil) else {
            throw AppUpdateError.invalidDownloadURL
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            try data.write(to: file, options: .atomic)
        case 401, 403:
            throw AppUpdateError.unauthorized
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
