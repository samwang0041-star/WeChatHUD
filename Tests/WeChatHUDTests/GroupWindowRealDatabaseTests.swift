import XCTest
@testable import WeChatHUD

/// The reported defect, proved against a real encrypted WeChat-shaped database
/// rather than against a stub reader.
///
/// `GroupContextSourceLoaderTests` pins the rule on an in-memory provider, which
/// is fast and exact but proves nothing about the queries. This drives the same
/// scenario through SQLite: a group that spoke three days ago, went silent, and
/// then received one @mention. The window handed to `group_analysis_v1` has to
/// contain the mention and nothing from the earlier conversation.
@MainActor
final class GroupWindowRealDatabaseTests: XCTestCase {
    private var fixture: SyntheticShardedScanFixture!

    override func tearDown() {
        if let fixture { try? FileManager.default.removeItem(at: fixture.root) }
        fixture = nil
        super.tearDown()
    }

    /// The id the reader actually produces for the newest message, which is
    /// what a real notification carries.
    ///
    /// Deriving it here instead of hardcoding keeps the fixture honest: a
    /// hand-written id would let the loader match by luck and hide a mismatch
    /// between what the scanner notices and what the loader looks up.
    private func newestMessage(in chat: String) throws -> MessageInfo {
        let messages = try fixture.reader.getMessages(chatUsername: chat, limit: 10)
        let newest = messages.max { $0.createTime < $1.createTime }
        return try XCTUnwrap(newest, "fixture produced no messages for \(chat)")
    }

    func testDaysOldChatterDoesNotEnterTodaysMentionWindow() throws {
        let chat = "quiet-room@chatroom"
        let now = Int(Date().timeIntervalSince1970)
        let threeDaysAgo = now - 3 * 24 * 3600

        // Monday: a real conversation. Then the group goes quiet for three days.
        // Today: a single @mention.
        let rows = [
            SyntheticShardedScanFixture.MessageRow(
                localId: 1, createTime: threeDaysAgo,
                senderId: 2, text: "陈总: 月报不要发，有很多修改"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 2, createTime: threeDaysAgo + 60,
                senderId: 3, text: "张沛: 一会去电梯口拍集体照"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 3, createTime: threeDaysAgo + 120,
                senderId: 2, text: "收到"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 4, createTime: now,
                senderId: 3, text: "@我 看一下新的排期"
            )
        ]
        fixture = try SyntheticShardedScanFixture(chatUsername: chat, shards: [0: rows])

        let mention = try newestMessage(in: chat)
        let notification = HUDNotification(
            chatUsername: chat, chatName: "静默群", senderUsername: "pzhang",
            senderName: "张沛", attentionLevel: .watch, messageID: mention.id,
            rawText: "@我 看一下新的排期", snippet: "@我 看一下新的排期",
            isAtMention: true, timestamp: Date(timeIntervalSince1970: TimeInterval(now)),
            kind: .groupAt
        )

        let window = GroupContextSourceLoader.load(
            notification: notification,
            reader: fixture.reader
        )

        let texts = (window ?? []).map(\.text)
        XCTAssertTrue(
            texts.contains("@我 看一下新的排期"),
            "the @mention itself must be in its own window"
        )
        XCTAssertFalse(
            texts.contains { $0.contains("月报不要发") || $0.contains("拍集体照") },
            "three-day-old chatter reached the analysis window: \(texts)"
        )
    }

    /// The counterpart on the same real database: a conversation that actually
    /// led up to the mention still arrives whole.
    func testContiguousLeadUpStillArrivesWhole() throws {
        let chat = "busy-room@chatroom"
        let now = Int(Date().timeIntervalSince1970)
        let rows = [
            SyntheticShardedScanFixture.MessageRow(
                localId: 1, createTime: now - 300, senderId: 2, text: "这个方案谁跟？"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 2, createTime: now - 240, senderId: 3, text: "我来跟"
            ),
            SyntheticShardedScanFixture.MessageRow(
                localId: 3, createTime: now, senderId: 3, text: "@我 你看下"
            )
        ]
        fixture = try SyntheticShardedScanFixture(chatUsername: chat, shards: [0: rows])

        let mention = try newestMessage(in: chat)
        let notification = HUDNotification(
            chatUsername: chat, chatName: "活跃群", senderUsername: "b", senderName: "乙",
            attentionLevel: .watch, messageID: mention.id, rawText: "@我 你看下",
            snippet: "@我 你看下", isAtMention: true,
            timestamp: Date(timeIntervalSince1970: TimeInterval(now)), kind: .groupAt
        )

        let window = GroupContextSourceLoader.load(
            notification: notification,
            reader: fixture.reader
        )
        let texts = (window ?? []).map(\.text)
        XCTAssertTrue(texts.contains("这个方案谁跟？"), "the lead-up is the context: \(texts)")
        XCTAssertTrue(texts.contains("我来跟"))
        XCTAssertTrue(texts.contains("@我 你看下"))
    }
}
