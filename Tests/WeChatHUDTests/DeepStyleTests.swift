import XCTest
@testable import WeChatHUD

final class DeepStyleTests: XCTestCase {

    // MARK: - TypingRhythm

    func testTypingRhythmDescriptions() {
        XCTAssertEqual(
            StyleProfiler.StyleProfile.TypingRhythm.singleMessage.description,
            "一条消息说完"
        )
        XCTAssertEqual(
            StyleProfiler.StyleProfile.TypingRhythm.mixed.description,
            "有时一条说完，有时分几条"
        )
        // The burst count is measured, so two different senders get two
        // different numbers. It used to read "每次表达2-3条连发" for everyone.
        XCTAssertEqual(
            StyleProfiler.StyleProfile.TypingRhythm.multiMessage(burstSize: 7).description,
            "习惯分多条发送（一次连发约 7 条）"
        )
        XCTAssertNotEqual(
            StyleProfiler.StyleProfile.TypingRhythm.multiMessage(burstSize: 2).description,
            StyleProfiler.StyleProfile.TypingRhythm.multiMessage(burstSize: 9).description
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
