import Foundation

/// Pulls file names (and, when present, numeric asset ids) out of GitHub's
/// `releases/expanded_assets/<tag>` fragment.
///
/// A regex over the raw HTML keeps this dependency-free and testable. The page
/// marks asset rows with `Box-row` and prints each file name as the row's
/// text, so scanning row by row is both simpler and sturdier than walking the
/// markup: if GitHub restyles the page, we would rather find no files than
/// find the wrong ones.
enum ExpandedAssetsParser {
    struct Result: Equatable, Sendable {
        var names: [String]
        var ids: [String: Int]
    }

    static func parse(_ html: String) -> Result {
        var names: [String] = []
        var ids: [String: Int] = [:]
        for row in assetRows(in: html) {
            guard let name = fileName(in: row) else { continue }
            if !names.contains(name) { names.append(name) }
            if let id = assetID(in: row), ids[name] == nil { ids[name] = id }
        }
        return Result(names: names, ids: ids)
    }

    /// Splits the fragment on the row marker GitHub uses for each uploaded
    /// file. Anything before the first marker is page chrome, not an asset.
    private static func assetRows(in html: String) -> [String] {
        let marker = "Box-row"
        var rows: [String] = []
        var searchStart = html.startIndex
        while let found = html.range(of: marker, range: searchStart..<html.endIndex) {
            let end = html.range(of: marker, range: found.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
            rows.append(String(html[found.upperBound..<end]))
            searchStart = end
        }
        return rows
    }

    /// The file name is the row's `">name</span>` text (GitHub wraps it in a
    /// span with the truncation class). Falls back to any `title=`/`download=`
    /// attribute that looks like a file so a restyle stays recoverable.
    private static func fileName(in row: String) -> String? {
        if let name = firstMatch(in: row, pattern: "<span[^>]*>\\s*([^<>]*?\\.(?:zip|sha256|txt|dmg|tar\\.gz|tgz|pkg))\\s*</span>") {
            return name
        }
        if let name = firstMatch(in: row, pattern: "(?:title|download)=\"([^\"]*?\\.(?:zip|sha256|txt|dmg|tar\\.gz|tgz|pkg))\"") {
            return name
        }
        return nil
    }

    /// API-backed pages link the file as `/releases/download/<id>/<name>`; the
    /// id is what a token-bearing download should request.
    private static func assetID(in row: String) -> Int? {
        guard let raw = firstMatch(in: row, pattern: "/releases/download/([0-9]{3,})/") else { return nil }
        return Int(raw)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
