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
    ) -> [T]? {
        for candidate in arrayCandidates(from: raw) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode([T].self, from: data) {
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

    /// Responses are bounded by `max_tokens`; anything past this is a runaway
    /// echo, and scanning it is what made a brace-heavy answer quadratic.
    static let maxScanLength = 200_000
    /// Characters the balanced scan may examine before giving up. A long run of
    /// unclosed braces used to walk to the end of the text once per brace.
    private static let scanBudget = 2_000_000

    private static func balancedCandidates(from raw: String, open: Character, close: Character) -> [String] {
        var cleaned = stripThinkingBlocks(raw)
        if cleaned.count > maxScanLength {
            cleaned = String(cleaned.prefix(maxScanLength))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        // Scan the fence's inside first (that is conventionally the payload),
        // then the surrounding text: stripping the fence used to discard
        // everything outside it, so prose-before-JSON, multiple fences, or JSON
        // that followed a non-JSON fence lost the payload completely.
        let inside = stripMarkdownFence(cleaned)
        var variants = [inside]
        if inside != cleaned { variants.append(cleaned) }

        var seen = Set<String>()
        var results: [String] = []
        // Each variant gets its own budget: a brace flood inside the fence
        // must not starve the outside-text variant that holds the real
        // payload. Worst case is variants × budget visits — still linear and
        // bounded, since the variant count is fixed at two.
        for variant in variants where !variant.isEmpty {
            var budget = scanBudget
            for candidate in balancedCandidates(in: variant, open: open, close: close, budget: &budget) {
                if seen.insert(candidate).inserted { results.append(candidate) }
            }
        }
        return results
    }

    /// Every balanced `open … close` slice in `text`, newest-first, spending at
    /// most `budget` character visits in total so a pathological input cannot
    /// make the scan quadratic.
    private static func balancedCandidates(
        in text: String,
        open: Character,
        close: Character,
        budget: inout Int
    ) -> [String] {
        let chars = Array(text)
        var results: [String] = []

        for start in chars.indices where chars[start] == open {
            var depth = 0
            var inString = false
            var escaping = false

            for index in start..<chars.count {
                budget -= 1
                if budget <= 0 { return results }
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
