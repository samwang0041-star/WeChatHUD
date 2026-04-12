import XCTest
@testable import WeChatHUD

final class ConversationMemoryTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        let tmp = NSTemporaryDirectory() + "test_memory_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() { store.close() }

    func testUpsertAndLoad() throws {
        let memory = ConversationMemory(
            chatUsername: "wxid_boss",
            summary: "讨论 Q3 方案",
            keyTopics: ["Q3方案", "预算"],
            pendingItems: ["发送报告"],
            moodTrend: "积极",
            messageCount7d: 42,
            lastUpdated: Date()
        )
        try store.upsertConversationMemory(memory)

        let loaded = store.loadConversationMemory(chatUsername: "wxid_boss")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "讨论 Q3 方案")
        XCTAssertEqual(loaded?.keyTopics, ["Q3方案", "预算"])
        XCTAssertEqual(loaded?.pendingItems, ["发送报告"])
        XCTAssertEqual(loaded?.moodTrend, "积极")
        XCTAssertEqual(loaded?.messageCount7d, 42)
    }

    func testUpsertUpdatesExisting() throws {
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "c1", summary: "old", keyTopics: [], pendingItems: [],
            moodTrend: "", messageCount7d: 1, lastUpdated: Date()
        ))
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "c1", summary: "new", keyTopics: ["topic"],
            pendingItems: ["item"], moodTrend: "紧张", messageCount7d: 10,
            lastUpdated: Date()
        ))

        let loaded = store.loadConversationMemory(chatUsername: "c1")
        XCTAssertEqual(loaded?.summary, "new")
        XCTAssertEqual(loaded?.keyTopics, ["topic"])
        XCTAssertEqual(loaded?.messageCount7d, 10)
    }

    func testLoadReturnsNilForMissing() {
        XCTAssertNil(store.loadConversationMemory(chatUsername: "nonexistent"))
    }

    func testEmptyTopicsAndPendingItems() throws {
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "c2", summary: "empty", keyTopics: [], pendingItems: [],
            moodTrend: "", messageCount7d: 0, lastUpdated: Date()
        ))
        let loaded = store.loadConversationMemory(chatUsername: "c2")
        XCTAssertEqual(loaded?.keyTopics, [])
        XCTAssertEqual(loaded?.pendingItems, [])
    }

    func testChineseContentRoundTrip() throws {
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "wxid_张三",
            summary: "张三最近在讨论年终奖发放方案，情绪偏焦虑",
            keyTopics: ["年终奖", "晋升", "绩效考核"],
            pendingItems: ["回复张三关于预算的问题", "确认会议时间"],
            moodTrend: "从积极转向焦虑，可能因为季度末压力",
            messageCount7d: 87,
            lastUpdated: Date()
        ))
        let loaded = store.loadConversationMemory(chatUsername: "wxid_张三")
        XCTAssertEqual(loaded?.keyTopics.count, 3)
        XCTAssertTrue(loaded?.summary.contains("年终奖") ?? false)
        XCTAssertTrue(loaded?.moodTrend.contains("焦虑") ?? false)
    }
}
