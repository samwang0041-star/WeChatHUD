import XCTest
@testable import WeChatHUD

final class ConversationSegmenterTests: XCTestCase {
    func testPrivateChatSplitByTimeGap() {
        let msgs = [
            makeMsg(time: 1000, sender: "A", text: "你好"),
            makeMsg(time: 1060, sender: "B", text: "你好"),
            makeMsg(time: 1120, sender: "A", text: "方案发你了"),
            // 3-hour gap
            makeMsg(time: 11920, sender: "B", text: "看完了"),
            makeMsg(time: 11980, sender: "B", text: "有几个问题"),
        ]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].messages.count, 3)
        XCTAssertEqual(segments[1].messages.count, 2)
    }

    func testGroupChatSplitByDensityDrop() {
        var msgs: [MessageInfo] = []
        for i in 0..<20 {
            msgs.append(makeMsg(time: 1000 + i * 30, sender: "User\(i % 4)", text: "msg\(i)"))
        }
        msgs.append(makeMsg(time: 2200, sender: "X", text: "sparse1"))
        msgs.append(makeMsg(time: 2600, sender: "X", text: "sparse2"))
        msgs.append(makeMsg(time: 3100, sender: "X", text: "sparse3"))
        for i in 0..<10 {
            msgs.append(makeMsg(time: 3200 + i * 30, sender: "New\(i % 3)", text: "new\(i)"))
        }
        let segments = ConversationSegmenter.segment(msgs, chatType: .group)
        XCTAssertGreaterThanOrEqual(segments.count, 2)
    }

    func testSingleMessage() {
        let msgs = [makeMsg(time: 1000, sender: "A", text: "hello")]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments.count, 1)
    }

    func testEmpty() {
        let segments = ConversationSegmenter.segment([], chatType: .privateChat)
        XCTAssertTrue(segments.isEmpty)
    }

    func testSegmentProperties() {
        let msgs = [
            makeMsg(time: 1000, sender: "A", text: "hello"),
            makeMsg(time: 1010, sender: "B", text: "hi"),
            makeMsg(time: 1020, sender: "A", text: "how are you"),
        ]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments[0].startTime, 1000)
        XCTAssertEqual(segments[0].endTime, 1020)
        XCTAssertEqual(segments[0].participants, Set(["A", "B"]))
    }

    func testFindSegment() {
        let msgs = [
            makeMsg(time: 1000, sender: "A", text: "a"),
            makeMsg(time: 1010, sender: "A", text: "b"),
            makeMsg(time: 10000, sender: "A", text: "c"),
        ]
        let segments = ConversationSegmenter.segment(msgs, chatType: .privateChat)
        XCTAssertEqual(segments.count, 2)
        let found = ConversationSegmenter.findSegment(for: 1005, in: segments)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.startTime, 1000)
    }

    private func makeMsg(time: Int, sender: String, text: String) -> MessageInfo {
        MessageInfo(id: UUID().uuidString, chatUsername: "test", chatName: "Test",
                    senderUsername: sender, senderName: sender, text: text,
                    baseType: 1, subType: 0, createTime: time)
    }
}
