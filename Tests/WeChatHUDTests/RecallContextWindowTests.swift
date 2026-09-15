import XCTest
@testable import WeChatHUD

/// The recall analyser's context window, driven against a real encrypted
/// database.
///
/// This path shipped untested when the window was changed from "the chat's
/// newest 10 messages" to "a bounded window straddling the recall". The change
/// is only correct if `getMessages` really honours the two-sided query, so the
/// assertions below are about the *queries*, which an in-memory stub cannot
/// check.
@MainActor
final class RecallContextWindowTests: XCTestCase {
    private var fixture: SyntheticShardedScanFixture!

    override func tearDown() {
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
        fixture = nil
        super.tearDown()
    }

    private func recalled(
        chat: String,
        sentAt: Int,
        recalledAt: Int
    ) -> RecalledMessage {
        RecalledMessage(
            id: 1, msgUID: "\(chat)_2", senderUsername: "member", senderName: "成员",
            senderLevel: .whitelist, senderRole: .colleague, chatUsername: chat,
            chatName: "群", chatType: .group, originalText: "说漏嘴的内容",
            sentAt: sentAt, recalledAt: recalledAt, recallDelaySeconds: recalledAt - sentAt,
            aiReason: nil, aiIntelligenceValue: nil, aiDetail: nil,
            aiShouldNotify: nil, aiNotifyLevel: nil, aiAnalyzedAt: nil, createdAt: Date()
        )
    }

    /// The window has to contain messages from *both* sides of the recall.
    ///
    /// The prompt asks for 「撤回前后上下文」 and reasons from both directions
    /// ("之后重发了类似内容" needs the after side, "说太多" needs the before side).
    /// The previous implementation fetched only the newest 10, which for a
    /// recall — itself the newest event — were all after the fact.
    func testContextIncludesMessagesBeforeAndAfterTheRecall() async throws {
        let chat = "recall-room@chatroom"
        let now = Int(Date().timeIntervalSince1970)
        let sentAt = now - 300
        let recalledAt = now - 240
        let rows = [
            SyntheticShardedScanFixture.MessageRow(
                localId: 1, createTime: now - 600, senderId: 2, text: "撤回之前大家在聊"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 3, createTime: now - 120, senderId: 3, text: "撤回之后有人接着说"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 4, createTime: now - 60, senderId: 2, text: "还在继续"
            )
        ]
        fixture = try SyntheticShardedScanFixture(chatUsername: chat, shards: [0: rows])

        let context = await ChatMonitor.recallContext(
            recalled: recalled(chat: chat, sentAt: sentAt, recalledAt: recalledAt),
            readerActor: WeChatReaderActor(fixture.reader)
        )
        let texts = context.map(\.text)

        XCTAssertTrue(
            texts.contains("撤回之前大家在聊"),
            "the before side is what judges 「说太多」: \(texts)"
        )
        XCTAssertTrue(
            texts.contains("撤回之后有人接着说"),
            "the after side is what detects a re-send: \(texts)"
        )
        // Order matters: the prompt reads them as a transcript.
        XCTAssertEqual(texts, texts.sorted { a, b in
            func t(_ s: String) -> Int {
                context.first { $0.text == s }?.createTime ?? 0
            }
            return t(a) < t(b)
        }, "the context must be chronological: \(texts)")
    }

    /// A recall in a chat that has been quiet for days must not pull the
    /// previous session in as its "context" — the same bound the group loader
    /// uses.
    func testContextDoesNotReachThroughADaysLongSilence() async throws {
        let chat = "quiet-recall@chatroom"
        let now = Int(Date().timeIntervalSince1970)
        let rows = [
            SyntheticShardedScanFixture.MessageRow(
                localId: 1, createTime: now - 5 * 24 * 3600, senderId: 2,
                text: "五天前的旧对话"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 3, createTime: now - 30, senderId: 3, text: "今天的正常发言"
            )
        ]
        fixture = try SyntheticShardedScanFixture(chatUsername: chat, shards: [0: rows])

        let context = await ChatMonitor.recallContext(
            recalled: recalled(chat: chat, sentAt: now - 120, recalledAt: now - 60),
            readerActor: WeChatReaderActor(fixture.reader)
        )
        let texts = context.map(\.text)
        XCTAssertFalse(
            texts.contains("五天前的旧对话"),
            "a five-day-old conversation is not this recall's context: \(texts)"
        )
        XCTAssertTrue(texts.contains("今天的正常发言"))
    }
}
