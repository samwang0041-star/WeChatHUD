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

    func testOutgoingInquiryDetectsUserAskingPeer() {
        let inquiries = [
            "问一下",
            "问一下六七千块钱的报价/价格情况",
            "我问一下这个报价",
            "我来问一下这个报价",
            "谢潘，问一下价格",
            "请问今天下午几点开会",
            "想问下周五放假吗",
            "这个价格能优惠吗？",
            "什么时候发货呢",
            "问一下我发的那个"
        ]
        for text in inquiries {
            XCTAssertTrue(MessageFeatureExtractor.isOutgoingInquiryToPeer(text), text)
        }
    }

    func testOutgoingInquiryDoesNotSwallowRealCommitments() {
        let commitments = [
            "好的我明天发你",
            "我去问一下老板再回你",
            "无论如何我明天发给你",
            "我看看呢",
            "收到",
            "了解一下这个项目",
            "我打听一下之后回你"
        ]
        for text in commitments {
            XCTAssertFalse(MessageFeatureExtractor.isOutgoingInquiryToPeer(text), text)
        }
    }

    func testInvertedInquiryRecordDetectsAskThenReplyHallucination() {
        XCTAssertTrue(MessageFeatureExtractor.isInvertedInquiryRecord(
            sourceText: "问一下六七千块钱的报价/价格情况",
            summary: "去问一下六七千块钱的报价/价格情况，之后回复谢潘"
        ))
        XCTAssertFalse(MessageFeatureExtractor.isInvertedInquiryRecord(
            sourceText: "我去问一下老板再回你",
            summary: "去问老板之后回复对方"
        ))
        XCTAssertTrue(MessageFeatureExtractor.isInvertedInquiryRecord(
            sourceText: "",
            summary: "去问一下报价，之后回复谢潘"
        ))
        XCTAssertFalse(MessageFeatureExtractor.isInvertedInquiryRecord(
            sourceText: "",
            summary: "确认是否周五前交货"
        ))
    }

    func testRepairedInquiryDiscussionMovesToWaitingOnPeer() {
        let repaired = MessageFeatureExtractor.repairedInquiryDiscussion(
            kind: .todo, owner: .mine,
            content: "去问一下六七千块钱的报价，之后回复谢潘"
        )
        XCTAssertEqual(repaired?.kind, .question)
        XCTAssertEqual(repaired?.owner, .theirs)
        XCTAssertEqual(repaired?.content, "问一下六七千块钱的报价")
        XCTAssertNil(MessageFeatureExtractor.repairedInquiryDiscussion(
            kind: .todo, owner: .mine, content: "明天把方案发给张三"
        ))
        XCTAssertNil(MessageFeatureExtractor.repairedInquiryDiscussion(
            kind: .todo, owner: .mine, content: "确认是否可以周五交货"
        ))
}
}
