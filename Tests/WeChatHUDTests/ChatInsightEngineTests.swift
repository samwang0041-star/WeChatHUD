import XCTest
@testable import WeChatHUD

final class ChatInsightEngineTests: XCTestCase {

    private let selfUsername = "wxid_me"

    private func msg(_ sender: String, _ text: String, _ time: Int) -> MessageInfo {
        MessageInfo(
            id: UUID().uuidString,
            chatUsername: "test_chat",
            chatName: "Test",
            senderUsername: sender,
            senderName: sender,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: time
        )
    }

    // MARK: - Message counts

    func testBasicStats_countsMessages() {
        let messages = [
            msg("wxid_me", "hello", 1000),
            msg("wxid_a", "hi", 1001),
            msg("wxid_b", "hey", 1002),
            msg("wxid_me", "sup", 1003),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test_chat", chatName: "Test", isGroup: true, category: .work
        )
        XCTAssertEqual(stats.messageCount, 4)
        XCTAssertEqual(stats.myMessageCount, 2)
        XCTAssertEqual(stats.participantCount, 3)
    }

    // MARK: - Messages by hour

    func testMessagesByHour_correctSlots() {
        let base = 1713000000
        let hour10 = base - (base % 86400) + 10 * 3600
        let hour14 = base - (base % 86400) + 14 * 3600
        let messages = [
            msg("wxid_a", "morning", hour10),
            msg("wxid_a", "morning2", hour10 + 60),
            msg("wxid_b", "afternoon", hour14),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .work
        )
        XCTAssertEqual(stats.messagesByHour.reduce(0, +), 3)
    }

    // MARK: - Top senders

    func testTopSenders_sortedByCount() {
        let messages = [
            msg("wxid_a", "1", 1000), msg("wxid_a", "2", 1001), msg("wxid_a", "3", 1002),
            msg("wxid_b", "4", 1003), msg("wxid_b", "5", 1004),
            msg("wxid_c", "6", 1005),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: true, category: .work
        )
        XCTAssertEqual(stats.topSenders[0].name, "wxid_a")
        XCTAssertEqual(stats.topSenders[0].count, 3)
        XCTAssertEqual(stats.topSenders[1].name, "wxid_b")
        XCTAssertEqual(stats.topSenders[1].count, 2)
    }

    // MARK: - Symmetry ratio

    func testSymmetry_balanced() {
        let messages = [
            msg("wxid_me", "hi", 1000),
            msg("wxid_a", "hey", 1001),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .life
        )
        XCTAssertEqual(stats.symmetryRatio, 1.0, accuracy: 0.01)
    }

    func testSymmetry_imbalanced() {
        let messages = [
            msg("wxid_me", "1", 1000), msg("wxid_me", "2", 1001), msg("wxid_me", "3", 1002),
            msg("wxid_a", "4", 1003),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .life
        )
        XCTAssertEqual(stats.symmetryRatio, 0.333, accuracy: 0.01)
    }

    // MARK: - Empty input

    func testEmptyMessages_returnsZeros() {
        let stats = ChatInsightEngine.computeStats(
            messages: [], selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .other
        )
        XCTAssertEqual(stats.messageCount, 0)
        XCTAssertEqual(stats.myMessageCount, 0)
        XCTAssertEqual(stats.symmetryRatio, 1.0)
        XCTAssertEqual(stats.avgResponseTimeSeconds, 0)
    }

    // MARK: - Response time

    func testAvgResponseTime_calculated() {
        let messages = [
            msg("wxid_a", "question", 1000),
            msg("wxid_me", "answer", 1060),
            msg("wxid_a", "followup", 1200),
            msg("wxid_me", "reply", 1320),
        ]
        let stats = ChatInsightEngine.computeStats(
            messages: messages, selfUsername: selfUsername,
            chatUsername: "test", chatName: "Test", isGroup: false, category: .work
        )
        XCTAssertEqual(stats.avgResponseTimeSeconds, 90, accuracy: 0.1)
    }

    // MARK: - Silence detection

    func testDetectSilence_findsAbnormallySilent() {
        let historical: [String: Int] = ["wxid_a": 10, "wxid_b": 2]
        let todayCounts: [String: Int] = ["wxid_a": 1, "wxid_b": 2]
        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical, todayCounts: todayCounts
        )
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent[0].name, "wxid_a")
        XCTAssertEqual(silent[0].usualDaily, 10)
        XCTAssertEqual(silent[0].today, 1)
    }

    func testDetectSilence_normalActivityNotFlagged() {
        let historical: [String: Int] = ["wxid_a": 10]
        let todayCounts: [String: Int] = ["wxid_a": 8]
        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical, todayCounts: todayCounts
        )
        XCTAssertTrue(silent.isEmpty)
    }

    func testDetectSilence_completelySilent() {
        let historical: [String: Int] = ["wxid_a": 5]
        let todayCounts: [String: Int] = [:]
        let silent = ChatInsightEngine.detectSilence(
            historicalDailyCounts: historical, todayCounts: todayCounts
        )
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent[0].today, 0)
    }

    // MARK: - Ignored message detection

    func testDetectIgnored_findsUnrepliedMessages() {
        let messages = [
            msg("wxid_a", "我觉得方案一更好", 1000),
            msg("wxid_b", "今天天气不错", 1200),
            msg("wxid_c", "确实", 1300),
            msg("wxid_b", "明天开会", 1400),
        ]
        let ignored = ChatInsightEngine.detectIgnored(messages: messages, windowSeconds: 600)
        XCTAssertEqual(ignored.count, 1)
        XCTAssertEqual(ignored[0].sender, "wxid_a")
        XCTAssertEqual(ignored[0].text, "我觉得方案一更好")
    }

    func testDetectIgnored_repliedNotFlagged() {
        let messages = [
            msg("wxid_a", "方案一如何", 1000),
            msg("wxid_b", "我同意", 1100),
        ]
        let ignored = ChatInsightEngine.detectIgnored(messages: messages, windowSeconds: 600)
        XCTAssertTrue(ignored.isEmpty)
    }

    func testDetectIgnored_lastMessageNotFlagged() {
        let messages = [
            msg("wxid_a", "有人在吗", 1000),
        ]
        let ignored = ChatInsightEngine.detectIgnored(messages: messages, windowSeconds: 600)
        XCTAssertTrue(ignored.isEmpty)
    }

    // MARK: - Sorting score

    func testSortingScore_workHigherThanLife() {
        let workStats = ChatStatsData(
            chatUsername: "w", chatName: "Work", isGroup: true, category: .work,
            messageCount: 10, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: []
        )
        let lifeStats = ChatStatsData(
            chatUsername: "l", chatName: "Life", isGroup: true, category: .life,
            messageCount: 10, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: []
        )
        XCTAssertGreaterThan(
            ChatInsightEngine.sortingScore(workStats, hasActionForMe: false),
            ChatInsightEngine.sortingScore(lifeStats, hasActionForMe: false)
        )
    }

    func testSortingScore_actionBoostsScore() {
        let stats = ChatStatsData(
            chatUsername: "t", chatName: "Test", isGroup: true, category: .other,
            messageCount: 1, myMessageCount: 0, participantCount: 1,
            messagesByHour: Array(repeating: 0, count: 24),
            avgResponseTimeSeconds: 0, symmetryRatio: 1.0, trend7d: 0,
            topSenders: [], silentMembers: [], ignoredMessages: []
        )
        let withAction = ChatInsightEngine.sortingScore(stats, hasActionForMe: true)
        let withoutAction = ChatInsightEngine.sortingScore(stats, hasActionForMe: false)
        XCTAssertGreaterThan(withAction, withoutAction)
    }
}
