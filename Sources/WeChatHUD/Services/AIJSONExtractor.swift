import Foundation

enum AIJSONExtractor {
    static func decodeFirstObject<T: Decodable>(
        from raw: String,
        as type: T.Type = T.self
    ) -> T? {
        for candidate in objectCandidates(from: raw) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode(type, from: data) {
                return decoded
            }
        }
        return nil
    }

    static func decodeFirstArray<T: Decodable>(
        from raw: String,
        as type: T.Type = T.self
    ) -> T? {
        for candidate in arrayCandidates(from: raw) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode(type, from: data) {
                return decoded
            }
        }
        return nil
    }

    static func firstObjectString(from raw: String) -> String? {
        objectCandidates(from: raw).first
    }

    static func firstArrayString(from raw: String) -> String? {
        arrayCandidates(from: raw).first
    }

    private static func objectCandidates(from raw: String) -> [String] {
        balancedCandidates(from: raw, open: "{", close: "}")
    }

    private static func arrayCandidates(from raw: String) -> [String] {
        balancedCandidates(from: raw, open: "[", close: "]")
    }

    private static func balancedCandidates(from raw: String, open: Character, close: Character) -> [String] {
        let cleaned = stripMarkdownFence(stripThinkingBlocks(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let chars = Array(cleaned)
        var results: [String] = []
        var starts: [Int] = []

        for (index, char) in chars.enumerated() where char == open {
            starts.append(index)
        }

        for start in starts {
            var depth = 0
            var inString = false
            var escaping = false

            for index in start..<chars.count {
                let char = chars[index]
                if inString {
                    if escaping {
                        escaping = false
                    } else if char == "\\" {
                        escaping = true
                    } else if char == "\"" {
                        inString = false
                    }
                    continue
                }

                if char == "\"" {
                    inString = true
                } else if char == open {
                    depth += 1
                } else if char == close {
                    depth -= 1
                    if depth == 0 {
                        results.append(String(chars[start...index]))
                        break
                    }
                }
            }
        }

        return results
    }

    private static func stripThinkingBlocks(_ raw: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    private static func stripMarkdownFence(_ raw: String) -> String {
        guard let fenceRange = raw.range(of: "```") else { return raw }
        var cleaned = String(raw[fenceRange.upperBound...])
        if cleaned.hasPrefix("json") {
            cleaned = String(cleaned.dropFirst(4))
        }
        if let endFence = cleaned.range(of: "```") {
            cleaned = String(cleaned[..<endFence.lowerBound])
        }
        return cleaned
    }
}
