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
    /// Peer text is attacker-writable, and these five templates answer with
    /// something the app then persists or puts on the wire: a durable memory, a
    /// commitment card, an insight report, a proactive draft, the auto-reply
    /// itself. Each has to say which block is data rather than instructions.
    /// The list is closed on purpose — a new template that stores or sends has to
    /// be added here with its fence, not quietly skip it.
    func testTemplatesThatPersistOrSendDeclareUntrustedData() throws {
        let files = try promptFiles()
        for name in [
            "autopilot_reply_v4", "conversation_memory_v1", "autopilot_proactive_v1",
            "commitment_v1", "chat_insight_v3",
        ] {
            let body = try XCTUnwrap(
                files.first { $0.name.hasPrefix(name) }?.body,
                "\(name) is gone from Resources/prompts"
            )
            XCTAssertTrue(
                body.contains("不可信数据"),
                "\(name) feeds durable state or an outgoing message with no untrusted-data fence"
            )
        }
    }

    /// A fence that names a block the template never renders is a lie the model
    /// cannot act on — the same failure as copy describing a knob that does not
    /// exist. Every block the safety sentence points at must be in the file.
    func testFencesNameBlocksThatActuallyExist() throws {
        let files = try promptFiles()
        let cases: [(String, [String])] = [
            ("autopilot_reply_v4", ["最近几条消息", "需要回复的消息", "你们之前聊过的背景"]),
            ("conversation_memory_v1", ["最近消息"]),
            ("commitment_v1", ["用户发出的消息", "对话上下文"]),
            ("autopilot_proactive_v1", ["触发原因", "你和对方的记忆"]),
        ]
        for (name, blocks) in cases {
            let body = try XCTUnwrap(files.first { $0.name.hasPrefix(name) }?.body)
            for block in blocks {
                XCTAssertTrue(body.contains(block), "\(name)'s fence points at 「\(block)」, which it never renders")
            }
        }
    }

    func testEveryPromptPlaceholderIsSubstituted() throws {        let sources = try swiftSources()
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
