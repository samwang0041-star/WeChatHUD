import Foundation

/// One asset on a GitHub Release. Only zip installers are considered.
struct GitHubReleaseAsset: Equatable, Sendable, Codable {
    let id: Int
    let name: String
    let browserDownloadURL: URL
    let apiURL: URL?
    let size: Int
    let state: String
}

struct GitHubRelease: Equatable, Sendable {
    let tagName: String
    let name: String
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let body: String
    let assets: [GitHubReleaseAsset]
}

struct AppUpdateOffer: Equatable, Sendable, Codable {
    let version: AppVersion
    let tagName: String
    let htmlURL: URL
    let notes: String
    let asset: GitHubReleaseAsset
    var checksumAsset: GitHubReleaseAsset? = nil
}

enum GitHubReleaseFeed {
    static func parseList(_ data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([DTO].self, from: data).map { $0.model() }
    }

    static func parseLatest(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(DTO.self, from: data).model()
    }

    /// Newest non-draft release that is newer than `current` and has a macOS zip.
    static func offer(
        in releases: [GitHubRelease],
        current: AppVersion,
        includePrerelease: Bool = false
    ) -> AppUpdateOffer? {
        releases
            .filter { !$0.draft }
            .filter { includePrerelease || !$0.prerelease }
            .compactMap { release -> AppUpdateOffer? in
                guard let version = AppVersion(release.tagName) ?? AppVersion(release.name),
                      version > current,
                      let asset = preferredAsset(in: release.assets) else {
                    return nil
                }
                return AppUpdateOffer(
                    version: version,
                    tagName: release.tagName,
                    htmlURL: release.htmlURL,
                    notes: release.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    asset: asset,
                    checksumAsset: checksumAsset(for: asset, in: release.assets)
                )
            }
            .max { $0.version < $1.version }
    }

    /// Prefer the archive `make package` emits: `WeChatHUD-<ver>-macOS14-arm64.zip`.
    static func preferredAsset(in assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        let zips = assets.filter { asset in
            let name = asset.name.lowercased()
            guard name.hasSuffix(".zip") else { return false }
            if name.contains("sha256") || name.contains("source") { return false }
            if asset.state == "uploaded" || asset.state.isEmpty { return true }
            return false
        }
        return zips.max { lhs, rhs in
            assetScore(lhs.name) < assetScore(rhs.name)
        }
    }

    static func checksumAsset(for zip: GitHubReleaseAsset, in assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        let expected = zip.name.lowercased() + ".sha256"
        return assets.first { $0.name.lowercased() == expected || $0.name.lowercased() == expected + ".txt" }
    }

    /// Private assets must be fetched from the Releases API URL when a token is present.
    /// Public releases only: the browser download URL needs no credential.
    static func downloadURL(for asset: GitHubReleaseAsset) -> URL? {
        guard asset.browserDownloadURL.scheme?.lowercased() == "https" else { return nil }
        return asset.browserDownloadURL
    }

    static func parseSHA256Manifest(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let hex = text.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
        guard let hex, hex.count == 64, hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        return hex
    }

    static func assetScore(_ name: String) -> Int {
        let n = name.lowercased()
        var score = 0
        if n.contains("wechathud") { score += 10 }
        if n.contains("macos") { score += 8 }
        if n.contains("arm64") { score += 6 }
        if n.contains("macos14") { score += 2 }
        return score
    }
}

private struct DTO: Decodable {
    let tagName: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let body: String?
    let assets: [AssetDTO]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case draft
        case prerelease
        case htmlURL = "html_url"
        case body
        case assets
    }

    func model() -> GitHubRelease {
        GitHubRelease(
            tagName: tagName,
            name: name ?? "",
            draft: draft,
            prerelease: prerelease,
            htmlURL: htmlURL,
            body: body ?? "",
            assets: assets.compactMap { $0.model() }
        )
    }
}

private struct AssetDTO: Decodable {
    let id: Int
    let name: String
    let browserDownloadURL: URL
    let url: URL?
    let size: Int
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case browserDownloadURL = "browser_download_url"
        case url
        case size
        case state
    }

    func model() -> GitHubReleaseAsset? {
        GitHubReleaseAsset(
            id: id,
            name: name,
            browserDownloadURL: browserDownloadURL,
            apiURL: url,
            size: size,
            state: state ?? ""
        )
    }
}
