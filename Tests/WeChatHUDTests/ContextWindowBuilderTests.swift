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

    // MARK: - Input ordering
    //
    // `WeChatReader.getMessages` defaults to `oldestFirst: false`, so most
    // callers hand this builder a NEWEST-FIRST array. The builder slices by
    // index around the target and `serialize()` renders the slice in array
    // order, so an unsorted input silently reversed the window: the reply
    // generator asked for 15 messages of lead-up and got the newest few in
    // reverse, and the commitment extractor's look-behind became look-ahead.
    // Two call sites worked around it with an explicit sort, which is what
    // proved the contract; the other two did not.

    private func sample() -> [MessageInfo] {
        (0..<20).map { i in makeMsg(time: 1000 + i * 60, sender: "U\(i % 3)", text: "msg\(i)") }
    }

    func testWindowIsChronologicalAndCentredOnTargetRegardlessOfInputOrder() {
        let msgs = sample()
        let target = msgs[12]

        let ascending = ContextWindowBuilder.build(
            target: target, role: .replyGenerator, allMessages: msgs,
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        let descending = ContextWindowBuilder.build(
            target: target, role: .replyGenerator, allMessages: msgs.reversed(),
            chatType: .privateChat, contactLookup: { _ in nil }
        )

        // Identical output either way.
        XCTAssertEqual(ascending.messages.map(\.id), descending.messages.map(\.id))

        // Chronological, target present, and the look-behind really is behind it.
        let times = descending.messages.map(\.createTime)
        XCTAssertEqual(times, times.sorted(), "serialized window must run oldest → newest")
        // 15 look-behind from index 12 clamps at the start of this 20-message
        // array, so the slice is msg0…msg14 and the target sits at index 12 —
        // inside the window, with the lead-up before it.
        XCTAssertEqual(descending.messages.count, 15)
        XCTAssertEqual(descending.messages.first?.id, msgs[0].id)
        XCTAssertEqual(descending.messages.firstIndex(where: { $0.id == target.id }), 12)

        // The text is what the model actually reads: msg12 must come after msg11.
        let serialized = descending.serialize()
        let idx11 = serialized.range(of: "msg11")
        let idx12 = serialized.range(of: "msg12")
        XCTAssertNotNil(idx11)
        XCTAssertNotNil(idx12)
        if let idx11, let idx12 {
            XCTAssertLessThan(idx11.lowerBound, idx12.lowerBound,
                              "lead-up must be serialized before the target message")
        }
    }

    func testCommitmentLookBehindIsNotReversedByNewestFirstInput() {
        // The commitment extractor passes getMessages output unsorted, so this
        // is the exact regression: 5 messages of lead-up, no look-ahead.
        let msgs = sample()
        let target = msgs[15]
        let window = ContextWindowBuilder.build(
            target: target, role: .commitmentTracker, allMessages: msgs.reversed(),
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        let ids = window.messages.map(\.id)
        XCTAssertEqual(ids.last, target.id, "look-ahead is 0, so the target ends the window")
        XCTAssertEqual(window.messages.map(\.createTime), window.messages.map(\.createTime).sorted())
        XCTAssertFalse(ids.contains(msgs[16].id), "nothing after the target may leak in")
    }

    func testMessagesSharingASecondKeepTheirLocalSequence() {
        // WeChat timestamps are second-resolution; localId is the tie-break the
        // reader's own ORDER BY uses.
        func tied(_ text: String, localId: Int) -> MessageInfo {
            MessageInfo(id: "m\(localId)", localId: localId, chatUsername: "test", chatName: "Test",
                        senderUsername: "A", senderName: "A", text: text,
                        baseType: 1, subType: 0, createTime: 5000)
        }
        let ordered = [tied("first", localId: 1), tied("second", localId: 2), tied("third", localId: 3)]
        let window = ContextWindowBuilder.build(
            target: ordered[1], role: .classifier, allMessages: ordered.reversed(),
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertEqual(window.messages.map(\.id), ["m1", "m2", "m3"])
    }
}
