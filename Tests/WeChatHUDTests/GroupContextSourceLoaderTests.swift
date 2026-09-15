import XCTest
@testable import WeChatHUD

final class GroupContextSourceLoaderTests: XCTestCase {
    func testLoadsExactSourceCenteredWindowWhenLaterMemberSpoke() {
        let messages = [
            message("before", "前文", 100, 1),
            message("mention", "@你 看预算", 110, 2),
            message("later", "我补充背景", 120, 3)
        ]
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "mention", ts: 110),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(result?.map(\.id), ["before", "mention", "later"])
    }

    func testFindsHistoricalSourceBeyondNewestPage() {
        let messages = (0..<60).map { index in
            message("m\(index)", "正文\(index)", 100 + index, index + 1)
        }
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "m5", ts: 105),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(result?.first?.id, "m0")
        XCTAssertTrue(result?.contains(where: { $0.id == "m5" }) == true)
        XCTAssertFalse(result?.contains(where: { $0.id == "m40" }) == true)
    }

    func testMissingSourceReturnsNilInsteadOfUsingNewestMessage() {
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "missing", ts: 200),
            reader: Provider(messages: [message("latest", "无关", 200, 1)])
        )
        XCTAssertNil(result)
    }

    @MainActor func testSourceAnchoredAnalysisKeepsSourceOlderThan48Hours() {
        let old = message("old", "@你 旧问题", 100, 1)
        let filtered = ChatMonitor.filterGroupAnalysisMessages(
            [old], sourceAnchored: true, now: Date(timeIntervalSince1970: 100 + 49 * 3600)
        )
        XCTAssertEqual(filtered.map(\.id), ["old"])
    }

    func testLoaderWindowCanBeOrderedNewestFirstForChatAnalyzer() {
        let messages = [message("old", "旧", 100, 1), message("new", "新", 200, 2)]
        XCTAssertEqual(GroupContextSourceLoader.newestFirst(messages).map(\.id), ["new", "old"])
    }

    /// The reported defect: a quiet group let days-old chatter into the
    /// summary of today's @message.
    ///
    /// `historyCount` is a *row* count, and the only bound on those rows was
    /// the loader's own 7-day paging window. So on a group that had been silent
    /// since Monday, a Tuesday @mention pulled Monday's conversation in as its
    /// "context" — the topic, the decisions and the 依据 lines were all built
    /// partly from messages that had nothing to do with the @.
    func testWindowDoesNotReachBackThroughADaysLongSilence() {
        let monday: Int = 1_000_000
        let tuesdayMention = monday + 3 * 24 * 3600
        let messages = [
            // Monday's conversation — three days before the mention.
            message("mon-1", "陈总：月报不要发，有很多修改", monday, 1),
            message("mon-2", "张沛：一会去电梯口拍集体照", monday + 60, 2),
            message("mon-3", "收到", monday + 120, 3),
            // Tuesday: the group goes quiet, then one @mention.
            message("today", "@你 看一下新的排期", tuesdayMention, 4)
        ]
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "today", ts: TimeInterval(tuesdayMention)),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(
            result?.map(\.id), ["today"],
            "Monday's messages are not context for a Tuesday @mention in a group that was silent in between"
        )
    }

    /// The counterpart: genuinely contiguous chatter still comes through.
    func testWindowKeepsConversationThatLedUpToTheMention() {
        let base: Int = 2_000_000
        let messages = [
            message("a", "这个方案谁跟？", base, 1),
            message("b", "我来跟", base + 30, 2),
            message("mention", "@你 你看下", base + 60, 3)
        ]
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "mention", ts: TimeInterval(base + 60)),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(result?.map(\.id), ["a", "b", "mention"])
    }

    /// The pipeline as production runs it: load a source-centred window, then
    /// apply the readability filter with `sourceAnchored: true`.
    ///
    /// That filter skips the 48-hour age rule on purpose (the source itself may
    /// legitimately be older), so the only thing keeping stale messages out of
    /// the prompt is the loader's contiguity bound. This pins the two halves
    /// together, so a future edit to either one cannot quietly restore the
    /// reported bug.
    @MainActor func testLoadedWindowStaysBoundedThroughTheSourceAnchoredFilter() {
        let monday = 4_000_000
        let tuesday = monday + 3 * 24 * 3600
        let messages = [
            message("mon", "三天前的旧话题", monday, 1),
            message("mention", "@你 新话题", tuesday, 2)
        ]
        let loaded = GroupContextSourceLoader.load(
            notification: notification(id: "mention", ts: TimeInterval(tuesday)),
            reader: Provider(messages: messages)
        )
        let filtered = ChatMonitor.filterGroupAnalysisMessages(
            loaded ?? [],
            sourceAnchored: true,
            now: Date(timeIntervalSince1970: TimeInterval(tuesday + 60))
        )
        XCTAssertEqual(
            filtered.map(\.id), ["mention"],
            "the loader's bound has to hold all the way into the prompt input"
        )
    }

    /// A message sent days *after* the @ is not a reply to it.
    func testWindowDoesNotReachForwardThroughADaysLongSilence() {
        let base: Int = 3_000_000
        let messages = [
            message("mention", "@你 看下", base, 1),
            message("next-day", "另一个话题", base + 3 * 24 * 3600, 2)
        ]
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "mention", ts: TimeInterval(base)),
            reader: Provider(messages: messages)
        )
        XCTAssertEqual(
            result?.map(\.id), ["mention"],
            "a message from three days later is not context for this @"
        )
    }

    /// The contiguity rule is a pure function, so it can be pinned directly.
    ///
    /// The gap is measured between **consecutive messages**, not from the
    /// source: a slow-but-unbroken conversation stays one conversation even if
    /// it spans more than the gap in total. What ends the run is a single
    /// silence longer than the gap — here the three-day hole before 「stale」.
    func testConversationHistoryStopsAtTheHoleNotAtItsTotalLength() {
        let source = message("s", "@你", 500_000, 9)
        let history = [
            message("stale", "三天前", 500_000 - 3 * 24 * 3600, 1),
            message("older", "两小时前", 500_000 - 2 * 3600 - 1, 2),
            message("near", "十分钟前", 500_000 - 600, 3)
        ]
        let kept = GroupContextSourceLoader.conversationHistory(history, leadingTo: source)
        XCTAssertEqual(
            kept.map(\.id), ["older", "near"],
            "「older」 is 1h50m before 「near」 so the conversation is unbroken from the source back to it; 「stale」 is three days behind that hole and must stop it"
        )
    }

    /// What the gap constant means, stated as behaviour rather than as a
    /// number.
    ///
    /// The reported bug was "many days ago" leaking in, so the bound only has
    /// to be decisively below a day. What it must *not* do is break up a single
    /// working session: an @ after lunch still refers to the morning's
    /// discussion in the same group. These two assertions are the contract —
    /// `maxConversationGapSeconds` is free to move as long as both hold.
    func testSameWorkingSessionStaysTogether() {
        let source = message("s", "@你 上午那个方案", 800_000, 9)
        // Morning discussion, @ three hours later — a lunch break between.
        let morning = message("am", "上午的讨论", 800_000 - 3 * 3600, 1)
        XCTAssertEqual(
            GroupContextSourceLoader.conversationHistory([morning], leadingTo: source).map(\.id),
            ["am"],
            "a three-hour break must not split one working session"
        )
    }

    func testPreviousEveningIsADifferentConversation() {
        let source = message("s", "@你 今天的事", 900_000, 9)
        // The same group the evening before — a different day's session.
        let lastNight = message("pm", "昨天傍晚的讨论", 900_000 - 13 * 3600, 1)
        XCTAssertTrue(
            GroupContextSourceLoader.conversationHistory([lastNight], leadingTo: source).isEmpty,
            "overnight silence ends the conversation; yesterday is not this @'s context"
        )
    }

    /// A single long silence anywhere in the chain ends the run there.
    func testConversationHistoryStopsAtALongSilence() {
        let source = message("s", "@你", 700_000, 9)
        let gap = GroupContextSourceLoader.maxConversationGapSeconds
        let history = [
            message("ancient", "更早", 700_000 - gap * 4, 1),
            message("afterHole", "沉默之后", 700_000 - gap - 30, 2),
            message("recent", "刚才", 700_000 - 60, 3)
        ]
        XCTAssertEqual(
            GroupContextSourceLoader.conversationHistory(history, leadingTo: source).map(\.id),
            ["afterHole", "recent"]
        )
    }

    /// Exactly at the boundary counts as the same conversation; one second past
    /// it does not. Without this the gap could silently drift.
    func testConversationGapBoundaryIsExact() {
        let source = message("s", "@你", 600_000, 9)
        let gap = GroupContextSourceLoader.maxConversationGapSeconds
        let atLimit = message("at", "正好", 600_000 - gap, 1)
        let past = message("past", "超一秒", 600_000 - gap - 1, 2)
        XCTAssertEqual(
            GroupContextSourceLoader.conversationHistory([atLimit], leadingTo: source).map(\.id),
            ["at"]
        )
        XCTAssertTrue(
            GroupContextSourceLoader.conversationHistory([past], leadingTo: source).isEmpty,
            "one second beyond the gap ends the conversation"
        )
    }

    private func notification(id: String, ts: TimeInterval) -> HUDNotification {
        HUDNotification(
            chatUsername: "room@chatroom", chatName: "群", senderUsername: "bob",
            senderName: "Bob", attentionLevel: .watch, messageID: id,
            rawText: "@你 原文", snippet: "@你 原文", isAtMention: true,
            timestamp: Date(timeIntervalSince1970: ts), kind: .groupAt
        )
    }

    private func message(_ id: String, _ text: String, _ ts: Int, _ localID: Int) -> MessageInfo {
        MessageInfo(
            id: id, localId: localID, chatUsername: "room@chatroom", chatName: "群",
            senderUsername: "sender", senderName: "成员", text: text,
            baseType: 1, subType: 0, createTime: ts
        )
    }
}

private struct Provider: GroupContextMessageProvider {
    let messages: [MessageInfo]

    func getMessages(
        chatUsername: String, limit: Int, sinceLocalId: Int?,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)?, oldestFirst: Bool,
        startTime: Int?, endTime: Int?,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    ) throws -> [MessageInfo] {
        let filtered = messages.filter { message in
            guard message.chatUsername == chatUsername else { return false }
            if let startTime, message.createTime < startTime { return false }
            if let endTime, message.createTime >= endTime { return false }
            if let cursor = afterCursor,
               !(message.createTime > cursor.lastCreateTime ||
                 (message.createTime == cursor.lastCreateTime && message.localId > cursor.lastLocalId)) { return false }
            if let cursor = beforeCursor,
               !(message.createTime < cursor.lastCreateTime ||
                 (message.createTime == cursor.lastCreateTime && message.localId <= cursor.lastLocalId)) { return false }
            return true
        }
        let ordered = filtered.sorted {
            if $0.createTime != $1.createTime { return oldestFirst ? $0.createTime < $1.createTime : $0.createTime > $1.createTime }
            return oldestFirst ? $0.localId < $1.localId : $0.localId > $1.localId
        }
        return Array(ordered.prefix(limit))
    }
}
