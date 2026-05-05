import Foundation
import XCTest
@testable import WeChatHUD

final class AIDailyReportActionInsightGeneratorTests: XCTestCase {

    // MARK: - Prompt formatting

    func testFormatPromptIncludesAllActions() {
        let generator = makeGenerator()
        let actions = [
            makeAction(id: "todo-1",       content: "回复客户", deadline: Date()),
            makeAction(id: "commitment-2", content: "交付报告", deadline: nil),
        ]
        let template = "count={count}\nactions:\n{actions}"
        let prompt = generator.formatPrompt(template: template, actions: actions)

        XCTAssertTrue(prompt.contains("count=2"))
        XCTAssertTrue(prompt.contains("id=\"todo-1\""))
        XCTAssertTrue(prompt.contains("id=\"commitment-2\""))
        XCTAssertTrue(prompt.contains("回复客户"))
        XCTAssertTrue(prompt.contains("交付报告"))
    }

    func testFormatPromptCapsActionsAtTwelve() {
        let generator = makeGenerator()
        let actions = (0..<20).map { makeAction(id: "todo-\($0)", content: "x", deadline: nil) }
        let template = "{actions}"
        let prompt = generator.formatPrompt(template: template, actions: actions)

        let occurrences = prompt.components(separatedBy: "id=\"todo-").count - 1
        XCTAssertEqual(occurrences, 12)
    }

    // MARK: - Parsing

    func testParseValidArray() {
        let generator = makeGenerator()
        let raw = """
        [
          {"id":"todo-1","reason":"r1","next_step":"n1"},
          {"id":"todo-2","reason":"r2","next_step":"n2"}
        ]
        """
        let parsed = generator.parse(raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "todo-1")
        XCTAssertEqual(parsed[0].reason, "r1")
        XCTAssertEqual(parsed[1].nextStep, "n2")
    }

    func testParseRejectsGarbage() {
        let generator = makeGenerator()
        XCTAssertTrue(generator.parse("not json").isEmpty)
        XCTAssertTrue(generator.parse("").isEmpty)
    }

    // MARK: - Helpers

    private func makeGenerator() -> AIDailyReportActionInsightGenerator {
        AIDailyReportActionInsightGenerator(
            aiService: AIService(config: AIConfig()),
            store: HUDStore(dbPath: ":memory:")
        )
    }

    private func makeAction(id: String, content: String, deadline: Date?) -> DailyReportAction {
        DailyReportAction(
            id: id,
            content: content,
            type: .todo,
            urgency: .high,
            deadline: deadline,
            sourceChatName: "Test",
            sourceChatUsername: "wxid_test",
            relatedID: id
        )
    }
}
