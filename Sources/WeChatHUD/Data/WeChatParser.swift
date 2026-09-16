import Foundation
import CZstd

struct ParsedMessage {
    var text: String = ""
    var title: String = ""
    var description: String = ""
    var url: String = ""
    var quotedText: String = ""
    var quotedSender: String = ""
    var senderHint: String = ""
    var appType: Int = 0
    /// `<sysmsg type="...">` kind for baseType-10000 rows ("revokemsg",
    /// "sysmsgtemplate", …). Empty for non-system messages.
    var sysKind: String = ""
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
        // Absolute output cap: a hostile or corrupt blob must never turn a
        // few KB of compressed input into a multi-GB transient allocation.
        // WeChat message payloads are well under 1MB; 32MB is generous.
        let maxOutput = 32 * 1024 * 1024
        var capacity = min(max(data.count * 10, 64 * 1024), maxOutput)

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
                // Grow and retry only while below the cap — a non-size error
                // (bad magic, truncated stream) can't be fixed by a bigger
                // buffer, and a decompression bomb just runs into the cap.
                capacity *= 4
                if capacity > maxOutput { return nil }
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
        // Reject potentially dangerous XML — case-insensitive: XMLParser
        // expands internal general entities, so a `<!doctype`/`<!entity`
        // written in any case is the same amplification vector.
        let lowered = xml.lowercased()
        guard !lowered.contains("<!doctype") && !lowered.contains("<!entity") else {
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

        // Scope lookups under `appmsg`: leaf-name collisions are real here —
        // `refermsg` carries its own <type>/<content>, and finderFeed repeats
        // <desc>/<title>. The unscoped leaf lookup stays as a fallback for
        // appmsg documents without the wrapper.
        result.title = parser.value(forPathSuffix: "appmsg.title") ?? parser.value(for: "title") ?? ""
        result.description = parser.value(forPathSuffix: "appmsg.des")
            ?? parser.value(forPathSuffix: "appmsg.desc")
            ?? parser.value(for: "des") ?? parser.value(for: "desc") ?? ""
        result.url = parser.value(forPathSuffix: "appmsg.url") ?? parser.value(for: "url") ?? ""
        // Quoted message (app_type 57): real XML nests refermsg under
        // msg.appmsg, so a root-level "refermsg.content" lookup never matched.
        result.quotedText = parser.value(forPathSuffix: "refermsg.content") ?? ""
        result.quotedSender = parser.value(forPathSuffix: "refermsg.displayname") ?? ""
        let typeStr = parser.value(forPathSuffix: "appmsg.type") ?? parser.value(for: "type")
        if let typeStr, let t = Int(typeStr) {
            result.appType = t
        }

        if !result.title.isEmpty {
            result.text = result.title
        } else if !result.description.isEmpty {
            result.text = result.description
        }

        // Typed prefixes mirror the reference renderer so a shared link, file,
        // mini-program, or quote doesn't read as plain text in previews and
        // AI context. Type 57 is the quote-reply: `title` holds the new reply,
        // `refermsg` holds the message being answered — without it a bare
        // "好的" loses what was agreed to.
        switch result.appType {
        case 5:
            result.text = result.title.isEmpty ? "[链接]" : "[链接] \(result.title)"
        case 6:
            result.text = result.title.isEmpty ? "[文件]" : "[文件] \(result.title)"
        case 33, 36, 44:
            result.text = result.title.isEmpty ? "[小程序]" : "[小程序] \(result.title)"
        case 57:
            var quoteText = result.title.isEmpty ? "[引用消息]" : result.title
            if !result.quotedText.isEmpty {
                let ref = result.quotedText.count > 160
                    ? String(result.quotedText.prefix(160)) + "..."
                    : result.quotedText
                let prefix = result.quotedSender.isEmpty ? "回复: " : "回复 \(result.quotedSender): "
                quoteText += "\n  ↳ \(prefix)\(ref)"
            }
            result.text = quoteText
        default:
            if result.text.isEmpty {
                result.text = "[链接/文件]"
            }
        }

        return result
    }

    /// Render a baseType-10000 system message. WeChat stores these as
    /// `<sysmsg type="...">…</sysmsg>` XML — handing the raw blob to previews
    /// and AI context leaks markup (and lets attribute text false-positive
    /// @-mention detection), so extract the human-readable payload.
    /// `revokemsg` rows carry `replacemsg` ("「X」撤回了一条消息") which both
    /// displays correctly and feeds the recall pipeline via `sysKind`.
    static func parseSysMsg(_ xml: String, isGroup: Bool) -> ParsedMessage {
        var result = ParsedMessage()
        let (sender, body) = extractGroupSender(xml, isGroup: isGroup)
        result.senderHint = sender ?? ""
        guard body.contains("<sysmsg") else {
            // Non-XML system text (join notices, plain "你已添加了…" lines).
            result.text = body.isEmpty ? "[系统消息]" : String(body.prefix(200))
            return result
        }
        // `type` is an attribute — outside SimpleXMLParser's element-text
        // model — so it is lifted by regex before the element pass.
        if let match = body.range(of: #"type\s*=\s*"([^"]+)""#, options: .regularExpression) {
            result.sysKind = body[match]
                .split(separator: "\"")
                .dropFirst()
                .first
                .map(String.init) ?? ""
        }
        guard let data = body.data(using: .utf8) else {
            result.text = "[系统消息]"
            return result
        }
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        if result.sysKind == "revokemsg" {
            let replace = parser.value(forPathSuffix: "revokemsg.replacemsg")
                ?? parser.value(for: "replacemsg") ?? ""
            result.text = replace.isEmpty ? "[撤回了一条消息]" : replace
            return result
        }
        let contentText = parser.value(for: "content") ?? ""
        result.text = contentText.isEmpty ? "[系统消息]" : contentText
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
            return parseSysMsg(content, isGroup: isGroup)
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

    /// Look up a value by trailing dotted path — matches the exact key or any
    /// stored path ending `.<suffix>` (e.g. "msg.appmsg.refermsg.content"
    /// matches suffix "refermsg.content"). When several paths share the suffix
    /// the shallowest wins: the root-ward element is the real payload, not a
    /// nested same-named field.
    func value(forPathSuffix suffix: String) -> String? {
        if let direct = elements[suffix], !direct.isEmpty { return direct }
        var best: String?
        var bestDepth = Int.max
        for (key, value) in elements where key.hasSuffix("." + suffix) && !value.isEmpty {
            let depth = key.split(separator: ".").count
            if depth < bestDepth {
                best = value
                bestDepth = depth
            }
        }
        return best
    }

    /// Parent-element text preserved while a child element is open. Without
    /// it, `abc<br/>def` stores only "def" — the text before the child was
    /// silently discarded when `didStartElement` reset `currentText`.
    private var textStack: [String] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        textStack.append(currentText)
        currentPath.append(element)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    /// CDATA arrives only through this callback — without it
    /// `<des><![CDATA[...]]></des>` stored an empty value.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            currentText += s
        }
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
        currentText = textStack.popLast() ?? ""
    }
}
