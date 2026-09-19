import Foundation

/// Extracts link metadata from WeChat app messages (baseType=49).
///
/// There used to be a `fetchWebContent(url:)` here that took the `<url>` out of
/// a peer's message and asked URLSession for it — no scheme allowlist, no
/// response-size cap, and nothing in the app ever called it. A dead sink for
/// "fetch whatever the other party typed" is not worth keeping on the strength
/// of a comment claiming a caller exists.
enum LinkExtractor {

    struct LinkMetadata {
        let title: String
        let description: String
        let url: String
        let appType: Int        // 5=link/article, 33/36=mini program, 6=file
    }

    /// Extract link metadata from a WeChat app message XML content.
    /// Returns nil if the message is not a link or parsing fails.
    static func extractMetadata(from messageText: String) -> LinkMetadata? {
        // WeChatParser already has SimpleXMLParser. But we can also
        // just extract the key fields with simple string matching.
        // The XML typically looks like: <msg><appmsg><title>...<des>...<url>...<type>...</appmsg></msg>

        guard let titleMatch = extractTag("title", from: messageText),
              !titleMatch.isEmpty else { return nil }

        let description = extractTag("des", from: messageText) ?? extractTag("desc", from: messageText) ?? ""
        let url = extractTag("url", from: messageText) ?? ""
        let typeStr = extractTag("type", from: messageText) ?? "5"
        let appType = Int(typeStr) ?? 5

        return LinkMetadata(
            title: titleMatch,
            description: description,
            url: url,
            appType: appType
        )
    }

    /// Simple XML tag extraction. Not a full parser — just grabs content between <tag> and </tag>.
    private static func extractTag(_ tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        let content = String(xml[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
        return content.isEmpty ? nil : content
    }
}
