import Foundation

/// Reads the latest release over GitHub's public *web* surface instead of the
/// REST API.
///
/// The API is rate limited per client IP (60 requests an hour for anonymous
/// callers). That budget is shared by every user behind the same NAT, VPN or
/// carrier gateway, so a published app cannot treat it as its primary update
/// channel: the check fails with 403 through no fault of the user, and the
/// failure reads as "no new version" or "this repo is private".
///
/// These endpoints are the ones the releases page itself uses. They are not
/// subject to the API quota and need no credentials, which is what a public
/// release channel requires. The REST API is still preferred when a token is
/// configured, because it carries richer data (notes, publish date, asset ids)
/// in one request.
enum GitHubReleaseWebFeed {
    static let baseURL = "https://github.com"

    static func latestReleaseURL(repository: String) -> URL? {
        URL(string: baseURL + "/" + repository + "/releases/latest")
    }

    static func expandedAssetsURL(repository: String, tag: String) -> URL? {
        URL(string: baseURL + "/" + repository + "/releases/expanded_assets/" + encodePath(tag))
    }

    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`
    ///
    /// Built rather than followed from the redirect: a download must not
    /// depend on a second hop we do not control.
    static func downloadURL(repository: String, tag: String, assetName: String) -> URL? {
        URL(string: baseURL + "/" + repository + "/releases/download/" + encodePath(tag) + "/" + encodePath(assetName))
    }

    /// Pulls the tag out of a resolved `releases/latest` URL, e.g.
    /// `.../releases/tag/v1.3.0` gives `v1.3.0`, and a tag containing a slash
    /// keeps the rest of the path.
    static func tag(fromResolvedLatestURL url: URL) -> String? {
        let marker = "/releases/tag/"
        let path = url.path
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        let tag = String(path[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return tag.isEmpty ? nil : tag.removingPercentEncoding ?? tag
    }

    private static func encodePath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#");
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
