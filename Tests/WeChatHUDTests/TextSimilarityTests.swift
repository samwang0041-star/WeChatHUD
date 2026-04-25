import Testing
@testable import WeChatHUD

@Suite("TextSimilarity")
struct TextSimilarityTests {

    @Test("Identical strings return 1.0")
    func identical() {
        #expect(TextSimilarity.jaccardCJK("hello world", "hello world") == 1.0)
    }

    @Test("Disjoint strings return 0.0")
    func disjoint() {
        #expect(TextSimilarity.jaccardCJK("abc", "xyz") == 0.0)
    }

    @Test("Both empty returns 1.0; one empty returns 0.0")
    func empty() {
        #expect(TextSimilarity.jaccardCJK("", "") == 1.0)
        #expect(TextSimilarity.jaccardCJK("x", "") == 0.0)
        #expect(TextSimilarity.jaccardCJK("", "x") == 0.0)
    }

    @Test("Chinese bigrams overlap with reordered phrasing")
    func chineseBigrams() {
        let s1 = "周一上线v2"
        let s2 = "v2 周一上线"
        let score = TextSimilarity.jaccardCJK(s1, s2)
        #expect(score > 0.6)
    }

    @Test("English word tokens with shared subset")
    func englishWords() {
        let score = TextSimilarity.jaccardCJK("send report to boss", "send the report")
        #expect(score > 0.3)
        #expect(score < 1.0)
    }

    @Test("Punctuation does not pollute tokens")
    func punctuation() {
        let s1 = "hello, world!"
        let s2 = "hello world"
        let score = TextSimilarity.jaccardCJK(s1, s2)
        #expect(score >= 0.9)
    }

    @Test("Mixed Chinese + English with whitespace variation")
    func mixed() {
        let s1 = "周一发 PRD 给 Wang"
        let s2 = "周一 发PRD 给Wang"
        let score = TextSimilarity.jaccardCJK(s1, s2)
        #expect(score > 0.5)
    }

    @Test("Stopwords filtered (the/a/to)")
    func stopwords() {
        let a = TextSimilarity.jaccardCJK("the cat sat", "the dog sat")
        let b = TextSimilarity.jaccardCJK("cat sat", "dog sat")
        // Removing stopwords should not change the relative score
        #expect(a == b)
    }
}
