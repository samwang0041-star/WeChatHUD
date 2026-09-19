import XCTest
@testable import WeChatHUD

/// `AIReplySuggester.suggestions(from:input:storedConfig:)` is the one place that
/// decides what the 回复建议 page may show. These tests pin both directions of
/// the config read: a readable list must honor words the user added themselves,
/// and an unreadable read must fail *toward* review (only a conservative
/// hand-off stands) rather than toward the built-in defaults.
///
/// The old shape read `getSettingJSON("autopilot") ?? AutopilotConfig()` inline,
/// so a corrupt row silently downgraded this page to the built-in list and,
/// worse, computed "no sensitive signal" out of a config it never read.
final class ReplySuggestionConfigReadTests: XCTestCase {

    private func input(_ body: String, askType: AskType = .schedule) -> AIReplySuggester.Input {
        AIReplySuggester.Input(
            messageBody: body,
            senderName: "王工",
            chatName: "项目群",
            isGroup: false,
            askType: askType,
            relationship: "work"
        )
    }

    private func raw(_ entries: [(text: String, intent: String)]) -> String {
        let items = entries.map {
            "{\"text\":\"\($0.text)\",\"tone\":\"recommended\",\"rationale\":\"\",\"intent\":\"\($0.intent)\",\"safe_to_send\":true}"
        }.joined(separator: ",")
        return "{\"suggestions\":[\(items)]}"
    }

    private static let benignSource = "下周团队聚餐，你要不要一起来"
    private static let commitment = "好，那就周三下午两点开会"

    /// Positive control: with a readable config and an innocuous source, the
    /// committing reply still stands. Without this, the "unreadable → assume
    /// sensitive" branch would pass by being always-on.
    func testReadableConfigKeepsACommittingSuggestion() {
        let out = AIReplySuggester.suggestions(
            from: raw([(Self.commitment, "accept")]),
            input: input(Self.benignSource),
            storedConfig: AutopilotConfig()
        )
        XCTAssertEqual(out?.map(\.text), [Self.commitment])
    }

    /// The fix: an unreadable config must not be read as "no sensitive signal".
    /// Same inputs as above, config missing ⇒ the committing draft is dropped
    /// and what's left is the hand-off, labelled as 涉及敏感信息 rather than
    /// pretending a decision was measured.
    func testUnreadableConfigFailsTowardReview() {
        let out = AIReplySuggester.suggestions(
            from: raw([(Self.commitment, "accept")]),
            input: input(Self.benignSource),
            storedConfig: nil
        )
        XCTAssertEqual(out?.count, 1, "读不到配置时不许留下任何表态类回复")
        XCTAssertEqual(out?.first?.text, "我确认下再回你")
        XCTAssertEqual(out?.first?.rationale, "涉及敏感信息")
    }

    /// A keyword the user added themselves must filter the draft — the built-in
    /// list alone would let 青鸟 through.
    func testStoredKeywordListIsTheOneThatFilters() {
        var config = AutopilotConfig()
        config.sensitiveKeywords = ["青鸟"]
        let rawText = raw([("这批青鸟设备的清单我发你", "info")])

        let filtered = AIReplySuggester.suggestions(
            from: rawText, input: input("青鸟项目进展如何"), storedConfig: config
        )
        XCTAssertEqual(filtered?.first?.text, "我确认下再回你",
                       "用户自己加的敏感词必须能拦住这条")

        let control = AIReplySuggester.suggestions(
            from: raw([("下周排期我发你", "info")]),
            input: input("下周排期怎么安排"), storedConfig: config
        )
        XCTAssertEqual(control?.first?.text, "下周排期我发你",
                       "拦住必须是这个词造成的，不是把所有建议都清空")
    }

    /// Failing toward review still filters: losing the stored list must not
    /// also mean losing the built-in floor.
    func testUnreadableConfigStillFiltersBuiltinKeywords() {
        let out = AIReplySuggester.suggestions(
            from: raw([("我这边给你转账过去", "action")]),
            input: input(Self.benignSource),
            storedConfig: nil
        )
        XCTAssertFalse(out?.contains { $0.text.contains("转账") } ?? false,
                       "「转账」在内置清单里，读不到配置也不该被放行")
    }

    /// Wiring, not just capability: the one production caller must hand in the
    /// honest read, and the pure decision must not reach for a store itself.
    func testProductionCallerPassesTheHonestRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/AIReplySuggester.swift")
        let source = try String(contentsOf: root, encoding: .utf8)

        let callSites = source.components(
            separatedBy: "storedConfig: store.autopilotConfigForSendGate()"
        ).count - 1
        XCTAssertEqual(callSites, 1, "生产调用点只有一个，并且必须走同一个诚实读法")

        let body = try XCTUnwrap(
            source.components(separatedBy: "nonisolated static func suggestions(").last
        ).components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertFalse(body.isEmpty, "切片不能为空，否则这条判据什么都没看")
        XCTAssertFalse(body.contains("store."),
                       "纯决策不许自己摸配置：读法只许出现在调用点")
    }
}
