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
            sharedContext: ["同事关系", "都在杭州"],
            communicationNotes: ["他喜欢发语音"],
            moodTrend: "积极",
            conversationPhase: "", stance: "",
            messageCount7d: 42,
            lastUpdated: Date()
        )
        try store.upsertConversationMemory(memory)

        let loaded = store.loadConversationMemory(chatUsername: "wxid_boss")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "讨论 Q3 方案")
        XCTAssertEqual(loaded?.keyTopics, ["Q3方案", "预算"])
        XCTAssertEqual(loaded?.pendingItems, ["发送报告"])
        XCTAssertEqual(loaded?.sharedContext, ["同事关系", "都在杭州"])
        XCTAssertEqual(loaded?.communicationNotes, ["他喜欢发语音"])
        XCTAssertEqual(loaded?.moodTrend, "积极")
        XCTAssertEqual(loaded?.messageCount7d, 42)
    }

    func testUpsertUpdatesExisting() throws {
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "c1", summary: "old", keyTopics: [], pendingItems: [],
            sharedContext: [], communicationNotes: [],
            moodTrend: "", conversationPhase: "", stance: "", messageCount7d: 1, lastUpdated: Date()
        ))
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "c1", summary: "new", keyTopics: ["topic"],
            pendingItems: ["item"], sharedContext: ["大学同学"],
            communicationNotes: ["晚上不回消息"],
            moodTrend: "紧张", conversationPhase: "", stance: "", messageCount7d: 10,
            lastUpdated: Date()
        ))

        let loaded = store.loadConversationMemory(chatUsername: "c1")
        XCTAssertEqual(loaded?.summary, "new")
        XCTAssertEqual(loaded?.keyTopics, ["topic"])
        XCTAssertEqual(loaded?.messageCount7d, 10)
        XCTAssertEqual(loaded?.sharedContext, ["大学同学"])
        XCTAssertEqual(loaded?.communicationNotes, ["晚上不回消息"])
    }

    func testLoadReturnsNilForMissing() {
        XCTAssertNil(store.loadConversationMemory(chatUsername: "nonexistent"))
    }

    func testEmptyTopicsAndPendingItems() throws {
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "c2", summary: "empty", keyTopics: [], pendingItems: [],
            sharedContext: [], communicationNotes: [],
            moodTrend: "", conversationPhase: "", stance: "", messageCount7d: 0, lastUpdated: Date()
        ))
        let loaded = store.loadConversationMemory(chatUsername: "c2")
        XCTAssertEqual(loaded?.keyTopics, [])
        XCTAssertEqual(loaded?.pendingItems, [])
        XCTAssertEqual(loaded?.sharedContext, [])
        XCTAssertEqual(loaded?.communicationNotes, [])
    }

    func testChineseContentRoundTrip() throws {
        try store.upsertConversationMemory(ConversationMemory(
            chatUsername: "wxid_张三",
            summary: "张三最近在讨论年终奖发放方案，情绪偏焦虑",
            keyTopics: ["年终奖", "晋升", "绩效考核"],
            pendingItems: ["回复张三关于预算的问题", "确认会议时间"],
            sharedContext: ["大学同学", "都在杭州", "上周一起吃了火锅"],
            communicationNotes: ["喜欢发语音", "晚上11点后不回消息"],
            moodTrend: "从积极转向焦虑，可能因为季度末压力",
            conversationPhase: "讨论", stance: "支持调薪",
            messageCount7d: 87,
            lastUpdated: Date()
        ))
        let loaded = store.loadConversationMemory(chatUsername: "wxid_张三")
        XCTAssertEqual(loaded?.keyTopics.count, 3)
        XCTAssertTrue(loaded?.summary.contains("年终奖") ?? false)
        XCTAssertTrue(loaded?.moodTrend.contains("焦虑") ?? false)
        XCTAssertEqual(loaded?.sharedContext.count, 3)
        XCTAssertEqual(loaded?.communicationNotes.count, 2)
    }

    // MARK: - New tests for Round 1

    func testFormatForPromptWithFullMemory() {
        let memory = ConversationMemory(
            chatUsername: "wxid_test",
            summary: "讨论项目进度",
            keyTopics: ["项目A", "周报"],
            pendingItems: ["给他推荐一本书"],
            sharedContext: ["同事", "都在上海"],
            communicationNotes: ["喜欢用表情包"],
            moodTrend: "积极",
            conversationPhase: "", stance: "",
            messageCount7d: 10,
            lastUpdated: Date()
        )

        let text = memory.formatForPrompt()
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("讨论项目进度"))
        XCTAssertTrue(text!.contains("项目A"))
        XCTAssertTrue(text!.contains("同事"))
        XCTAssertTrue(text!.contains("给他推荐一本书"))
        XCTAssertTrue(text!.contains("喜欢用表情包"))
        XCTAssertTrue(text!.contains("积极"))
    }

    func testFormatForPromptReturnsNilWhenEmpty() {
        let memory = ConversationMemory(
            chatUsername: "wxid_empty",
            summary: "",
            keyTopics: [],
            pendingItems: [],
            sharedContext: [],
            communicationNotes: [],
            moodTrend: "",
            conversationPhase: "", stance: "",
            messageCount7d: 0,
            lastUpdated: Date()
        )
        XCTAssertNil(memory.formatForPrompt())
    }

    func testFormatForPromptPartialFields() {
        let memory = ConversationMemory(
            chatUsername: "wxid_partial",
            summary: "聊了聊近况",
            keyTopics: [],
            pendingItems: [],
            sharedContext: ["老同学"],
            communicationNotes: [],
            moodTrend: "",
            conversationPhase: "", stance: "",
            messageCount7d: 5,
            lastUpdated: Date()
        )
        let text = memory.formatForPrompt()
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("聊了聊近况"))
        XCTAssertTrue(text!.contains("老同学"))
        XCTAssertFalse(text!.contains("最近话题"))
        XCTAssertFalse(text!.contains("情绪"))
    }

    func testFormatForPromptTruncatesAt400Chars() {
        let longTopics = (1...20).map { "很长的话题名称第\($0)个" }
        let memory = ConversationMemory(
            chatUsername: "wxid_long",
            summary: String(repeating: "这是一个非常长的摘要内容", count: 5),
            keyTopics: longTopics,
            pendingItems: ["待办A", "待办B"],
            sharedContext: ["背景1", "背景2"],
            communicationNotes: ["习惯1"],
            moodTrend: "焦虑",
            conversationPhase: "", stance: "",
            messageCount7d: 50,
            lastUpdated: Date()
        )
        let text = memory.formatForPrompt()
        XCTAssertNotNil(text)
        XCTAssertLessThanOrEqual(text!.count, 400)
        // Summary should always be included (highest priority)
        XCTAssertTrue(text!.contains("摘要:"))
    }
}
