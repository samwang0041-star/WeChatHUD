import XCTest
@testable import WeChatHUD

/// Gates for the prompt layer: every token a template asks for must be filled,
/// and every template the code asks for must exist.
///
/// Why: a prompt is a template, and nothing about editing one tells you whether
/// the code still substitutes its placeholders. A prompt that gains `{foo}`
/// without a matching `replacingOccurrences` ships the literal text
/// `{foo}` to the model — the model then guesses, and the guess is cached as
/// analysis. The reverse (code loading a version whose file was renamed) throws
/// at runtime and degrades to a fallback, which is quieter than it should be.
/// Both are cheap to check from source.
final class PromptWiringTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
    }

    private func promptFiles() throws -> [(name: String, body: String)] {
        let dir = sourcesRoot().appendingPathComponent("Resources/prompts")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".txt") }
        XCTAssertFalse(names.isEmpty, "no prompt files found")
        return try names.map {
            (name: $0, body: try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    private func swiftSources() throws -> String {
        var combined = ""
        let root = sourcesRoot()
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertFalse(combined.isEmpty, "no Swift sources found")
        return combined
    }

    /// Every `{token}` in a prompt has a `replacingOccurrences(of: "{token}")`
    /// somewhere in the sources.
    func testEveryPromptPlaceholderIsSubstituted() throws {
        let sources = try swiftSources()
        let substituted = Set(
            matches(in: sources, pattern: #"of: "\{[a-z_0-9]+\}""#)
                .flatMap { matches(in: $0, pattern: #"\{[a-z_0-9]+\}"#) }
        )
        XCTAssertFalse(substituted.isEmpty, "found no substitution sites at all — the scan itself is broken")

        for prompt in try promptFiles() {
            let tokens = Set(matches(in: prompt.body, pattern: #"\{[a-z_][a-z_0-9]*\}"#))
            // `{{` would be JSON braces in an example, not a placeholder; the
            // pattern above already requires a lowercase first letter, so the
            // schema braces in these prompts do not match.
            let missing = tokens.subtracting(substituted).sorted()
            XCTAssertTrue(
                missing.isEmpty,
                "\(prompt.name) asks for \(missing.joined(separator: ", ")) but nothing substitutes it, so the model receives the literal token"
            )
        }
    }

    /// Every prompt version named in the sources has a file next to it.
    func testEveryPromptVersionReferencedByCodeExists() throws {
        let sources = try swiftSources()
        let referenced = Set(matches(in: sources, pattern: #"load\(version: "[a-z_0-9]+""#)
            .flatMap { matches(in: $0, pattern: #""[a-z_0-9]+"$"#) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
        XCTAssertFalse(referenced.isEmpty, "found no load(version:) call sites — the scan itself is broken")

        let available = Set(try promptFiles().map { String($0.name.dropLast(4)) })
        for version in referenced.sorted() {
            XCTAssertTrue(
                available.contains(version),
                "code loads prompt version \(version) but Resources/prompts has no \(version).txt; the load throws and the feature silently falls back"
            )
        }
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
    }
}
