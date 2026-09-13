import XCTest
@testable import WeChatHUD

final class WeChatReaderBatchMessagesTests: XCTestCase {
    func testBatchMatchesPerChatGetMessages() throws {
        let fixture = try WeChatReaderPerfFixture()
        defer { fixture.cleanUp() }

        let chatA = "wxid_batch_a"
        let chatB = "wxid_batch_b"
        let relPath = "message/message_0.db"
        try fixture.createMessageDB(
            relPath: relPath,
            chats: [
                chatA: [
                    .init(localId: 1, createTime: 1_000, senderId: 1, text: "A1"),
                    .init(localId: 2, createTime: 2_000, senderId: 1, text: "A2"),
                ],
                chatB: [
                    .init(localId: 1, createTime: 1_500, senderId: 2, text: "B1"),
                ],
            ],
            name2id: [chatA, chatB]
        )
        let reader = try fixture.makeReader(cacheStrategy: .memory)
        XCTAssertTrue(try reader.refreshIfChanged(relPath: relPath))

        let requests = [
            WeChatReader.MessageBatchRequest(chatUsername: chatA, limit: 10),
            WeChatReader.MessageBatchRequest(chatUsername: chatB, limit: 10),
        ]
        let batch = try reader.getMessagesBatch(requests)
        for req in requests {
            let single = try reader.getMessages(chatUsername: req.chatUsername, limit: req.limit)
            let batched = batch[req.chatUsername] ?? []
            XCTAssertEqual(batched.map(\.id), single.map(\.id), "id mismatch for \(req.chatUsername)")
            XCTAssertEqual(batched.map(\.text), single.map(\.text), "text mismatch for \(req.chatUsername)")
        }
        XCTAssertEqual(batch[chatA]?.map(\.text), ["A2", "A1"])
        XCTAssertEqual(batch[chatB]?.map(\.text), ["B1"])
    }
}
