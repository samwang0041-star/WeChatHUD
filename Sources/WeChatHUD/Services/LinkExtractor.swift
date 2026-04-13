import Foundation

/// Extracts link metadata from WeChat app messages (baseType=49).
/// Also fetches webpage content for AI analysis when needed.
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

    /// Fetch webpage content for AI analysis.
    /// Returns the first ~2000 chars of extracted body text, or nil on failure.
    /// Timeout: 5 seconds.
    static func fetchWebContent(url: String) async -> String? {
        guard let requestURL = URL(string: url) else { return nil }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 5
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return nil
            }
            return extractBodyText(from: html)
        } catch {
            print("[WCHUD] LinkExtractor: fetch failed for \(url): \(error.localizedDescription)")
            return nil
        }
    }

    /// Strip HTML tags and extract readable text. Returns first ~2000 chars.
    private static func extractBodyText(from html: String) -> String? {
        // Remove script, style, nav, header, footer tags and their content
        var text = html
        let removePatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<nav[^>]*>[\\s\\S]*?</nav>",
            "<header[^>]*>[\\s\\S]*?</header>",
            "<footer[^>]*>[\\s\\S]*?</footer>"
        ]
        for pattern in removePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }

        // Remove all remaining HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
            text = tagRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }

        // Clean up whitespace
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(2000))
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
