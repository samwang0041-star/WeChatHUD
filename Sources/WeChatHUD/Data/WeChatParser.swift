import Foundation
import CZstd

struct ParsedMessage {
    var text: String = ""
    var title: String = ""
    var description: String = ""
    var url: String = ""
    var quotedText: String = ""
    var senderHint: String = ""
    var appType: Int = 0
}

struct WeChatParser {

    // MARK: - Content Decoding

    /// Decode message_content bytes. If ct==4, decompress with zstd first.
    static func decodeContent(_ raw: Data?, ct: Int) -> String {
        guard let raw = raw, !raw.isEmpty else { return "" }

        if ct == 4 {
            // zstd decompression
            if let decompressed = decompressZstd(raw) {
                return String(data: decompressed, encoding: .utf8) ?? ""
            }
            return ""
        }

        return String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .ascii) ?? ""
    }

    /// Decompress zstd-compressed data via libzstd (statically linked).
    static func decompressZstd(_ data: Data) -> Data? {
        // Generous buffer; grow retry if too small.
        var capacity = max(data.count * 10, 64 * 1024)

        for _ in 0..<3 {
            var dest = Data(count: capacity)
            let written = dest.withUnsafeMutableBytes { dstBuf -> Int in
                data.withUnsafeBytes { srcBuf -> Int in
                    czstd_decompress(
                        dstBuf.baseAddress,
                        capacity,
                        srcBuf.baseAddress,
                        data.count
                    )
                }
            }

            if czstd_is_error(written) != 0 {
                // Grow and retry once in case destination was too small.
                capacity *= 4
                continue
            }

            dest.count = written
            return dest
        }
        return nil
    }

    // MARK: - Group Sender Extraction

    /// In group chats, message format is "sender:\ncontent". Extract sender and content.
    static func extractGroupSender(_ text: String, isGroup: Bool) -> (sender: String?, content: String) {
        guard isGroup else { return (nil, text) }
        guard let range = text.range(of: ":\n") else { return (nil, text) }
        let sender = String(text[text.startIndex..<range.lowerBound])
        let content = String(text[range.upperBound...])
        return (sender, content)
    }

    // MARK: - XML Parsing

    /// Parse appmsg XML to extract title, description, url, quoted text, app type.
    static func parseAppMsg(_ xml: String) -> ParsedMessage {
        var result = ParsedMessage()
        guard xml.contains("<") && xml.contains(">") else {
            result.text = xml
            return result
        }
        // Reject potentially dangerous XML
        guard !xml.contains("<!DOCTYPE") && !xml.contains("<!ENTITY") else {
            result.text = xml
            return result
        }
        guard xml.count < 1_000_000 else {
            result.text = String(xml.prefix(500))
            return result
        }

        guard let data = xml.data(using: .utf8) else {
            result.text = xml
            return result
        }

        let parser = SimpleXMLParser(data: data)
        parser.parse()

        result.title = parser.value(for: "title") ?? ""
        result.description = parser.value(for: "des") ?? parser.value(for: "desc") ?? ""
        result.url = parser.value(for: "url") ?? ""
        result.quotedText = parser.value(for: "refermsg.content") ?? ""
        if let typeStr = parser.value(for: "type"), let t = Int(typeStr) {
            result.appType = t
        }

        if !result.title.isEmpty {
            result.text = result.title
        } else if !result.description.isEmpty {
            result.text = result.description
        }

        return result
    }

    /// Render a human-readable summary from a raw message.
    static func renderMessage(content: String, baseType: Int, isGroup: Bool) -> ParsedMessage {
        switch baseType {
        case 1:  // text
            let (sender, text) = extractGroupSender(content, isGroup: isGroup)
            var msg = ParsedMessage(text: text)
            msg.senderHint = sender ?? ""
            return msg
        case 3:
            return ParsedMessage(text: "[图片]")
        case 34:
            return ParsedMessage(text: "[语音]")
        case 43:
            return ParsedMessage(text: "[视频]")
        case 47:
            return ParsedMessage(text: "[表情]")
        case 48:
            return ParsedMessage(text: "[位置]")
        case 49: // appmsg — XML
            let (sender, xmlContent) = extractGroupSender(content, isGroup: isGroup)
            var msg = parseAppMsg(xmlContent)
            msg.senderHint = sender ?? ""
            return msg
        case 50:
            return ParsedMessage(text: "[通话]")
        case 10000:
            return ParsedMessage(text: content)
        default:
            return ParsedMessage(text: content.isEmpty ? "[消息]" : String(content.prefix(200)))
        }
    }
}

// MARK: - Simple XML Element Extractor

/// Lightweight XML parser that extracts element text by tag path.
/// Not a full DOM parser — just grabs text content from specific elements.
class SimpleXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var elements: [String: String] = [:]
    private var currentPath: [String] = []
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func value(for key: String) -> String? {
        let v = elements[key]
        return (v?.isEmpty == true) ? nil : v
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        currentPath.append(element)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Store by leaf name and by dotted path
            elements[element] = trimmed
            let path = currentPath.joined(separator: ".")
            elements[path] = trimmed
        }
        currentPath.removeLast()
        currentText = ""
    }
}
