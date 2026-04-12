import XCTest
@testable import WeChatHUD

final class DeepStyleTests: XCTestCase {

    // MARK: - TypingRhythm

    func testTypingRhythmDescriptions() {
        XCTAssertFalse(StyleProfiler.StyleProfile.TypingRhythm.singleMessage.description.isEmpty)
        XCTAssertFalse(StyleProfiler.StyleProfile.TypingRhythm.multiMessage.description.isEmpty)
        XCTAssertFalse(StyleProfiler.StyleProfile.TypingRhythm.mixed.description.isEmpty)
        // Verify they're distinct
        XCTAssertNotEqual(
            StyleProfiler.StyleProfile.TypingRhythm.singleMessage.description,
            StyleProfiler.StyleProfile.TypingRhythm.multiMessage.description
        )
    }

    // MARK: - Prompt v2 loads

    func testPromptV2Loads() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "autopilot_reply_v2")
        XCTAssertTrue(template.contains("{punctuation_style}"))
        XCTAssertTrue(template.contains("{sentence_style}"))
        XCTAssertTrue(template.contains("{typing_rhythm}"))
        XCTAssertTrue(template.contains("{message_pairs}"))
        XCTAssertTrue(template.contains("{length_p25}"))
        XCTAssertTrue(template.contains("{length_p50}"))
        XCTAssertTrue(template.contains("{length_p75}"))
        // v2 should have style-matching rules
        XCTAssertTrue(template.contains("模仿标点习惯"))
    }

    func testPromptV1StillExists() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "autopilot_reply_v1")
        XCTAssertTrue(template.contains("{message_body}"))
    }

    // MARK: - MessageUrgency (additional coverage)

    func testUrgencyMultipleQuestionMarks() {
        XCTAssertEqual(MessageUrgency.detect(from: "你到底怎么想的？？"), .high)
    }

    func testUrgencyASAP() {
        XCTAssertEqual(MessageUrgency.detect(from: "ASAP please"), .high)
    }

    func testUrgencyHaveYouGotTime() {
        XCTAssertEqual(MessageUrgency.detect(from: "有空吗"), .high)
    }
}
