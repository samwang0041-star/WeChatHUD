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

    func testPromptV4Loads() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "autopilot_reply_v4")
        XCTAssertTrue(template.contains("{punctuation_style}"))
        XCTAssertTrue(template.contains("{sentence_style}"))
        XCTAssertTrue(template.contains("{message_pairs}"))
        XCTAssertTrue(template.contains("{session_ledger}"))
        XCTAssertTrue(template.contains("{contact_role}"))
        // v4 should have style-matching rules
        XCTAssertTrue(template.contains("模仿这种感觉"))
    }

    func testPromptV4SafetyDisclaimer() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "autopilot_reply_v4")
        XCTAssertTrue(template.contains("{message_body}"))
        XCTAssertTrue(template.contains("不可信数据"), "v4 must treat message content as untrusted")
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
