import Foundation

/// Lightweight CJK-aware text similarity for retrospective todo
/// dedupe (Spec §6.2 step 7b). Pure value-type API; no dependencies.
enum TextSimilarity {

    /// Jaccard similarity for CJK + Latin text in [0, 1].
    /// 1 = identical token sets; 0 = disjoint.
    /// Tokenization:
    /// - Chinese chars → bigrams (sliding 2-char window over CJK runs)
    /// - Latin/digit runs → lowercase words split on whitespace + punctuation
    /// - Common stopwords dropped
    static func jaccardCJK(_ a: String, _ b: String) -> Double {
        let aTokens = tokenize(a)
        let bTokens = tokenize(b)
        if aTokens.isEmpty && bTokens.isEmpty { return 1.0 }
        if aTokens.isEmpty || bTokens.isEmpty { return 0.0 }
        let intersection = aTokens.intersection(bTokens).count
        let union = aTokens.union(bTokens).count
        return Double(intersection) / Double(union)
    }

    static func tokenize(_ s: String) -> Set<String> {
        var tokens = Set<String>()
        var currentLatin = ""
        var cjkBuffer: [Character] = []

        func flushLatin() {
            if !currentLatin.isEmpty {
                let lower = currentLatin.lowercased()
                if !lower.isEmpty { tokens.insert(lower) }
                currentLatin = ""
            }
        }

        func flushCJK() {
            if cjkBuffer.count == 1 {
                tokens.insert(String(cjkBuffer[0]))
            } else if cjkBuffer.count >= 2 {
                for i in 0..<(cjkBuffer.count - 1) {
                    tokens.insert(String([cjkBuffer[i], cjkBuffer[i + 1]]))
                }
            }
            cjkBuffer.removeAll(keepingCapacity: true)
        }

        for ch in s {
            if isCJK(ch) {
                flushLatin()
                cjkBuffer.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                currentLatin.append(ch)
            } else {
                // whitespace or punctuation = boundary
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()

        // Drop common stopwords so "the cat" vs "cat" doesn't penalize.
        let stopwords: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "at", "and", "or", "for"]
        tokens.subtract(stopwords)
        return tokens
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)        // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(v)    // Extension A
                || (0x20000...0x2A6DF).contains(v)  // Extension B
            {
                return true
            }
        }
        return false
    }
}
