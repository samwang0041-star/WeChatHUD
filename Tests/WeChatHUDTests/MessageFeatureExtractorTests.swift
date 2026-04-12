import XCTest
@testable import WeChatHUD

final class MessageFeatureExtractorTests: XCTestCase {
    func testQuestionMark() {
        XCTAssertTrue(MessageFeatureExtractor.extract("你明天有空吗？").hasQuestionMark)
        XCTAssertTrue(MessageFeatureExtractor.extract("hello?").hasQuestionMark)
        XCTAssertFalse(MessageFeatureExtractor.extract("好的没问题").hasQuestionMark)
    }

    func testSecondPerson() {
        XCTAssertTrue(MessageFeatureExtractor.extract("你帮我看看").hasSecondPerson)
        XCTAssertTrue(MessageFeatureExtractor.extract("您好").hasSecondPerson)
        XCTAssertFalse(MessageFeatureExtractor.extract("我已经做完了").hasSecondPerson)
    }

    func testRequestVerb() {
        XCTAssertTrue(MessageFeatureExtractor.extract("麻烦帮我发一下文件").hasRequestVerb)
        XCTAssertTrue(MessageFeatureExtractor.extract("请确认").hasRequestVerb)
        XCTAssertFalse(MessageFeatureExtractor.extract("哈哈好搞笑").hasRequestVerb)
    }

    func testTimeReference() {
        XCTAssertTrue(MessageFeatureExtractor.extract("明天给你").hasTimeReference)
        XCTAssertTrue(MessageFeatureExtractor.extract("下周一之前搞定").hasTimeReference)
        XCTAssertFalse(MessageFeatureExtractor.extract("这个事情").hasTimeReference)
    }

    func testUrgencyWord() {
        XCTAssertTrue(MessageFeatureExtractor.extract("这个很紧急").hasUrgencyWord)
        XCTAssertTrue(MessageFeatureExtractor.extract("尽快处理").hasUrgencyWord)
        // "不着急" contains "着急" so this is true by design — algorithm adds hints, AI makes final judgment.
        XCTAssertTrue(MessageFeatureExtractor.extract("不着急慢慢来").hasUrgencyWord)
    }

    func testCommitmentSignal() {
        XCTAssertTrue(MessageFeatureExtractor.extract("好的我明天发你").hasCommitmentSignal)
        XCTAssertTrue(MessageFeatureExtractor.extract("收到").hasCommitmentSignal)
        XCTAssertFalse(MessageFeatureExtractor.extract("这个怎么做").hasCommitmentSignal)
    }

    func testMediaType() {
        XCTAssertEqual(MessageFeatureExtractor.extract("普通文字").detectedMediaType, .text)
        XCTAssertEqual(MessageFeatureExtractor.extract("看 https://example.com").detectedMediaType, .link)
        XCTAssertEqual(MessageFeatureExtractor.extract("[图片]").detectedMediaType, .image)
        XCTAssertEqual(MessageFeatureExtractor.extract("[语音消息]").detectedMediaType, .voice)
        XCTAssertEqual(MessageFeatureExtractor.extract("[文件]report.pdf").detectedMediaType, .file)
        XCTAssertEqual(MessageFeatureExtractor.extract("他拍了拍你").detectedMediaType, .system)
    }

    func testMessageLength() {
        XCTAssertEqual(MessageFeatureExtractor.extract("你好").messageLength, 2)
        XCTAssertEqual(MessageFeatureExtractor.extract("").messageLength, 0)
    }
}
