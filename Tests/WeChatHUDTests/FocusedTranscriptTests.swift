import XCTest
@testable import WeChatHUD

final class FocusedTranscriptTests: XCTestCase {
    func testMissingFocusIsInsertedAtTheTop() {
        let focus = TranscriptFocus(
            chatUsername: "preview-project",
            messageID: "missed-2",
            senderName: "林晓",
            body: "@我 纪要还差你那一段，今天下班前能补上吗？",
            timestamp: Date()
        )
        let rows = FocusedTranscript.assemble(
            loaded: [("林晓", "今天的评审定在几点？"), ("我", "我先确认一下。")],
            focus: focus
        )
        XCTAssertEqual(rows.first?.body, focus.body)
        XCTAssertEqual(rows.first?.isFocus, true)
        XCTAssertEqual(rows.filter { $0.isFocus }.count, 1)
    }

    func testMatchingLoadedRowIsMarkedNotDuplicated() {
        let focus = TranscriptFocus(
            chatUsername: "alice",
            messageID: "a1",
            senderName: "许宁",
            body: "上周说的报价，你看了没？",
            timestamp: Date()
        )
        let rows = FocusedTranscript.assemble(
            loaded: [("许宁", "上周说的报价，你看了没？"), ("我", "嗯")],
            focus: focus
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].isFocus, true)
        XCTAssertEqual(rows[1].isFocus, false)
    }

    func testWithoutFocusNothingIsHighlighted() {
        let rows = FocusedTranscript.assemble(
            loaded: [("林晓", "今天的评审定在几点？")],
            focus: nil
        )
        XCTAssertEqual(rows.map { $0.isFocus }, [false])
    }

    @MainActor
    func testConversationFocusIsConsumedOnceForTheMatchingChat() {
        let state = PanelState()
        let focus = TranscriptFocus(
            chatUsername: "preview-project",
            messageID: "missed-2",
            senderName: "林晓",
            body: "@我 纪要还差你那一段，今天下班前能补上吗？",
            timestamp: Date()
        )
        state.showChatDetail(chatUsername: "preview-project", chatName: "项目协作群", focus: focus)
        XCTAssertNil(state.consumeTranscriptFocus(for: "other"))
        XCTAssertEqual(state.consumeTranscriptFocus(for: "preview-project")?.messageID, "missed-2")
        XCTAssertNil(state.consumeTranscriptFocus(for: "preview-project"))
    }
}
