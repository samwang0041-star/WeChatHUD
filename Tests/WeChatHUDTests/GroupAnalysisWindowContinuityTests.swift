import XCTest
@testable import WeChatHUD

/// The reported defect: on a group whose history spans more than a day, the
/// on-demand analysis summarised *every* recent exchange as one situation, so a
/// topic from one or two days earlier was read as what the group is discussing
/// now.
///
/// The `@` path was already bounded (`GroupContextSourceLoader`). The plain
/// group path was not: it took the newest 50 messages and kept everything
/// inside a 48-hour window, which on a followed parents' group is 1.8 days and
/// several separate conversations. These tests pin the missing bound.
@MainActor
final class GroupAnalysisWindowContinuityTests: XCTestCase {
    private let chat = "room@chatroom"
    private var now = Date()

    override func setUp() {
        super.setUp()
        now = Date()
    }

    private func message(
        _ localId: Int,
        minutesAgo: Double,
        text: String,
        sender: String = "老师"
    ) -> MessageInfo {
        MessageInfo(
            id: "message/message_0.db/Msg/\(localId)",
            localId: localId,
            chatUsername: chat,
            chatName: "四二班",
            senderUsername: sender,
            senderName: sender,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: Int(now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970)
        )
    }

    // MARK: - The rule

    func testCurrentConversationDropsTheEarlierSession() {
        // Two exchanges separated by an overnight gap, plus today's.
        let messages = [
            message(1, minutesAgo: 40 * 60, text: "昨天的作业提醒"),
            message(2, minutesAgo: 40 * 60 - 2, text: "收到"),
            message(3, minutesAgo: 50, text: "今天的留堂通知"),
            message(4, minutesAgo: 30, text: "@所有人 记得接孩子")
        ]

        let kept = GroupContextSourceLoader.currentConversation(messages).map(\.text)

        XCTAssertEqual(kept, ["今天的留堂通知", "@所有人 记得接孩子"],
                       "只有与最新消息相连的那段会话属于“现在在聊什么”")
    }

    func testCurrentConversationKeepsASessionThatSurvivesALunchBreak() {
        let messages = [
            message(1, minutesAgo: 5 * 60, text: "中午那条"),
            message(2, minutesAgo: 60, text: "刚回复的")
        ]
        XCTAssertEqual(GroupContextSourceLoader.currentConversation(messages).count, 2,
                       "6 小时以内的一次连续讨论必须完整保留")
    }

    func testCurrentConversationIsEmptyForNoMessages() {
        XCTAssertTrue(GroupContextSourceLoader.currentConversation([]).isEmpty)
    }

    func testCurrentConversationHandlesNewestFirstInput() {
        // `getMessages` returns newest-first; the rule must not depend on order.
        let newestFirst = [
            message(4, minutesAgo: 1, text: "最新"),
            message(3, minutesAgo: 2, text: "刚才"),
            message(1, minutesAgo: 30 * 60, text: "昨天"),
            message(2, minutesAgo: 30 * 60 - 1, text: "昨天稍后")
        ]
        XCTAssertEqual(GroupContextSourceLoader.currentConversation(newestFirst).map(\.text),
                       ["刚才", "最新"])
    }

    // MARK: - The analysis window

    /// The measured shape of the real defect: 28 readable messages inside the
    /// 48-hour cap, spanning 1.8 days. Before this bound, all 28 went to
    /// `group_analysis_v1` as one situation.
    func testUnanchoredWindowIsOneConversationNotFortyEightHours() {
        var messages: [MessageInfo] = []
        var id = 0
        for minute in stride(from: 42.0 * 60, to: 40.0 * 60, by: -10) {
            id += 1
            messages.append(message(id, minutesAgo: minute, text: "昨天的话题 \(id)"))
        }
        for minute in stride(from: 25.0 * 60, to: 23.0 * 60, by: -10) {
            id += 1
            messages.append(message(id, minutesAgo: minute, text: "今天的话题 \(id)"))
        }

        let filtered = ChatMonitor.filterGroupAnalysisMessages(messages, sourceAnchored: false, now: now)

        XCTAssertFalse(filtered.isEmpty)
        XCTAssertTrue(filtered.allSatisfy { $0.text.hasPrefix("今天的话题") },
                      "昨天的话题不能进入“这个群现在在聊什么”：\(filtered.map(\.text))")
    }

    /// The 48-hour cap still owns the “group went quiet” case.
    func testUnanchoredWindowStillDropsAMonthOldGroup() {
        let messages = [message(1, minutesAgo: 30 * 24 * 60, text: "很久以前")]
        XCTAssertTrue(
            ChatMonitor.filterGroupAnalysisMessages(messages, sourceAnchored: false, now: now).isEmpty,
            "静了很久的群没有“当前讨论”，不能把上个月的对话端上来"
        )
    }

    /// The `@` path keeps its own contract: the loader decided the window, and
    /// the source is kept however old it is (a user may only now see a
    /// three-day-old @).
    func testAnchoredWindowIsLeftAlone() {
        let messages = [
            message(1, minutesAgo: 3 * 24 * 60, text: "三天前的@"),
            message(2, minutesAgo: 3 * 24 * 60 - 1, text: "紧接着的一句")
        ]
        let filtered = ChatMonitor.filterGroupAnalysisMessages(messages, sourceAnchored: true, now: now)
        XCTAssertEqual(filtered.count, 2)
    }

    func testUnreadableContentIsDroppedInBothBranches() {
        let messages = [
            message(1, minutesAgo: 10, text: "正常的一条"),
            message(2, minutesAgo: 5, text: "[图片]")
        ]
        XCTAssertEqual(
            ChatMonitor.filterGroupAnalysisMessages(messages, sourceAnchored: true, now: now).map(\.text),
            ["正常的一条"]
        )
        XCTAssertEqual(
            ChatMonitor.filterGroupAnalysisMessages(messages, sourceAnchored: false, now: now).map(\.text),
            ["正常的一条"]
        )
    }
}
