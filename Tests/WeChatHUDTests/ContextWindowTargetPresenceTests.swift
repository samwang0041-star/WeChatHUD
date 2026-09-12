import XCTest
@testable import WeChatHUD

/// ContextWindowBuilder 的「目标不在窗口内」语义。
///
/// 旧实现用 `?? ordered.count - 1` 兜底：目标消息不在 `allMessages` 里时，窗口
/// 会静默退化成一截与目标无关的尾消息，还把最后一条标成「目标消息」。承诺提取
/// 会把这段尾消息写进承诺的 `contextText`，回复建议也会拿到一段不以目标为中心
/// 的窗口。正确行为是显式表达「目标不在窗口内」：空窗口 + `targetFound == false`，
/// 调用方按「没有上下文」处理。
final class ContextWindowTargetPresenceTests: XCTestCase {

    func testTargetMissingReturnsEmptyWindowAndExplicitMarker() {
        let msgs = (0..<10).map { makeMsg(id: "m\($0)", time: 1_000 + $0 * 60, text: "msg\($0)") }
        // 目标消息完全不在窗口数据里（例如它比最近 10 条更早，或来自别的读法）。
        let target = makeMsg(id: "absent", time: 9_999_999, text: "@你 周三前给我稿子")

        let window = ContextWindowBuilder.build(
            target: target, role: .commitmentTracker, allMessages: msgs,
            chatType: .privateChat, contactLookup: { _ in nil }
        )

        XCTAssertTrue(window.messages.isEmpty, "目标缺席时不能退化成窗口末条消息")
        XCTAssertFalse(window.targetFound)
        XCTAssertEqual(window.serialize(), "", "空窗口序列化后不得包含任何无关上下文")
    }

    func testLookAlikeMessageIsNotMistakenForTarget() {
        // 同一秒、同一段文字，但 id 不同：只能按 id 命中目标。
        let lookAlike = makeMsg(id: "synthetic", time: 5_000, text: "好")
        let target = makeMsg(id: "real", time: 5_000, text: "好")

        let window = ContextWindowBuilder.build(
            target: target, role: .classifier, allMessages: [lookAlike],
            chatType: .privateChat, contactLookup: { _ in nil }
        )

        XCTAssertTrue(window.messages.isEmpty)
        XCTAssertFalse(window.targetFound)
    }

    func testEmptyInputAlsoReportsTargetMissing() {
        let target = makeMsg(id: "m", time: 1_000, text: "x")
        let window = ContextWindowBuilder.build(
            target: target, role: .classifier, allMessages: [],
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertTrue(window.messages.isEmpty)
        XCTAssertFalse(window.targetFound)
    }

    func testTargetPresentStillBuildsTheSameCentredWindow() {
        let msgs = (0..<20).map { makeMsg(id: "m\($0)", time: 1_000 + $0 * 60, text: "msg\($0)") }
        let target = msgs[15]

        let window = ContextWindowBuilder.build(
            target: target, role: .commitmentTracker, allMessages: msgs,
            chatType: .group, contactLookup: { _ in nil }
        )

        XCTAssertTrue(window.targetFound)
        XCTAssertEqual(window.messages.filter(\.isTarget).map(\.id), [target.id])
        // commitmentTracker: lookBehind 5 / lookAhead 0 → 目标是窗口最后一条。
        XCTAssertEqual(window.messages.count, 6)
        XCTAssertEqual(window.messages.last?.id, target.id)
        XCTAssertTrue(window.serialize().contains("← 目标消息"))
    }

    func testTargetIdentityIsKeptInSerializedWindow() {
        let msgs = [
            makeMsg(id: "a", time: 1_000, text: "前文"),
            makeMsg(id: "b", time: 1_060, text: "@你 明天中午前发我"),
            makeMsg(id: "c", time: 1_120, text: "后来的闲聊")
        ]
        let window = ContextWindowBuilder.build(
            target: msgs[1], role: .replyGenerator, allMessages: msgs,
            chatType: .privateChat, contactLookup: { _ in nil }
        )
        XCTAssertTrue(window.targetFound)
        XCTAssertEqual(window.messages.map(\.id), ["a", "b", "c"])
    }

    private func makeMsg(id: String, time: Int, text: String) -> MessageInfo {
        MessageInfo(
            id: id, chatUsername: "chat", chatName: "Chat",
            senderUsername: "sender", senderName: "Sender", text: text,
            baseType: 1, subType: 0, createTime: time
        )
    }
}
