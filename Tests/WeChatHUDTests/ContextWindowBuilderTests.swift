import XCTest
@testable import WeChatHUD

final class ContextWindowBuilderTests: XCTestCase {
    func testClassifierLimit() {
        let msgs = (0..<30).map { i in makeMsg(time: 1000 + i * 60, sender: "A", text: "msg\(i)") }
        let target = msgs[25]
        let result = ContextWindowBuilder.build(
            target: target, role: .classifier, allMessages: msgs,
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertLessThanOrEqual(result.messages.count, 20)
        XCTAssertTrue(result.messages.contains(where: { $0.id == target.id }))
    }

    func testContextAnalyzerGetsMore() {
        let msgs = (0..<60).map { i in makeMsg(time: 1000 + i * 60, sender: "U\(i % 3)", text: "msg\(i)") }
        let target = msgs[50]
        let result = ContextWindowBuilder.build(
            target: target, role: .contextAnalyzer, allMessages: msgs,
            chatType: .group, contactLookup: { _ in nil }
        )
        XCTAssertGreaterThan(result.messages.count, 20)
        XCTAssertLessThanOrEqual(result.messages.count, 50)
    }

    func testCommitmentTrackerSmall() {
        let msgs = (0..<20).map { i in makeMsg(time: 1000 + i * 60, sender: "A", text: "msg\(i)") }
        let target = msgs[15]
        let result = ContextWindowBuilder.build(
            target: target, role: .commitmentTracker, allMessages: msgs,
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertLessThanOrEqual(result.messages.count, 8)
    }

    func testAnnotationsIncludeRole() {
        let msgs = [makeMsg(time: 1000, sender: "boss1", text: "方案怎么样了")]
        let result = ContextWindowBuilder.build(
            target: msgs[0], role: .classifier, allMessages: msgs,
            chatType: .privateChat, contactLookup: { u in
                u == "boss1" ? (.vip, .boss) : nil
            }
        )
        XCTAssertEqual(result.messages[0].senderLevel, .vip)
        XCTAssertEqual(result.messages[0].senderRole, .boss)
    }

    func testSerialize() {
        let msgs = [makeMsg(time: 1000, sender: "A", text: "你好")]
        let result = ContextWindowBuilder.build(
            target: msgs[0], role: .classifier, allMessages: msgs,
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertTrue(result.serialize().contains("你好"))
        XCTAssertTrue(result.serialize().contains("← 目标消息"))
    }

    func testEmptyInput() {
        let dummy = makeMsg(time: 1000, sender: "A", text: "x")
        let result = ContextWindowBuilder.build(
            target: dummy, role: .classifier, allMessages: [],
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertTrue(result.messages.isEmpty)
    }

    private func makeMsg(time: Int, sender: String, text: String) -> MessageInfo {
        MessageInfo(id: "msg_\(time)_\(sender)", chatUsername: "test", chatName: "Test",
                    senderUsername: sender, senderName: sender, text: text,
                    baseType: 1, subType: 0, createTime: time)
    }
}
