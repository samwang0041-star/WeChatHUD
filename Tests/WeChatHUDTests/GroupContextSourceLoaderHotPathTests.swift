import XCTest
@testable import WeChatHUD

/// D8: group @-source lookup used to walk backwards through the 7-day window in
/// pages of `pageSize` (24) messages, up to 128 queries, before it could even
/// start building the source-centred window. These tests pin the single bounded
/// "hot path" query, the unchanged paged fallback, and the resulting window.
final class GroupContextSourceLoaderHotPathTests: XCTestCase {
    private let base = 1_700_000_000

    // MARK: - Common path

    func testHotPathResolvesSourceWithOneQueryWhenChatterFollowsTheTarget() {
        // 300 messages; the target is #200, i.e. ~100 messages from the newest.
        // Old loop: newest-first pages of 24 with a one-row overlap (the
        // inclusive beforeCursor re-includes the previous page's oldest row,
        // exactly as WeChatReader does), so four pages reach only row 92 of the
        // 99 newer messages and the target first appears on page 5 -> 5
        // source-resolution queries (a longer backlog hits the 128-page cap).
        let messages = (0..<300).map { index in
            message("m\(index)", "正文\(index)", base + index, index + 1)
        }
        let provider = CountingProvider(messages: messages)
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "m200", ts: TimeInterval(base + 299)),
            reader: provider
        )

        XCTAssertEqual(
            result?.map(\.id),
            (192...199).map { "m\($0)" } + ["m200"] + ["m201", "m202", "m203"]
        )

        // One bounded query replaces the >= 5 paging queries. Every successful
        // `load` still ends with the two window queries (history + future) that
        // D8 leaves unchanged, so 3 total calls is the floor here.
        XCTAssertEqual(provider.sourceResolutionQueryCount, 1)
        XCTAssertLessThanOrEqual(provider.sourceResolutionQueryCount, 2)
        XCTAssertEqual(provider.calls.count, 3)

        let hot = provider.calls[0]
        XCTAssertEqual(hot.limit, GroupContextSourceLoader.fastPathPageLimit)
        XCTAssertEqual(hot.startTime, base + 299 - GroupContextSourceLoader.fastPathLookbackSeconds)
        XCTAssertEqual(hot.endTime, base + 300)
        XCTAssertFalse(hot.oldestFirst)
        XCTAssertNil(hot.beforeCursor)
        XCTAssertNil(hot.afterCursor)
    }

    // MARK: - Fallback path

    func testFallsBackToPagedWalkWhenTargetPredatesHotPathWindow() {
        // Stale notification: the banner timestamp is 3 days after the @ itself,
        // so the target sits outside the fast-path look-back while still inside
        // the 7-day paging window. 50 newer messages at 23 effective rows per
        // page (24 minus the re-included boundary row) = 3 fallback queries, so
        // more than the common path. Paging is the slow road by design, and it
        // still has to work.
        let notificationTime = base + 259_201 // target + 3 days
        var messages: [MessageInfo] = [
            message("old0", "三天前", base - 100, 1),
            message("old1", "一天前", base - 50, 2),
            message("src", "@你 看一下预算", base + 1, 3)
        ]
        messages += (0..<50).map { index in
            message("post\(index)", "后续讨论\(index)", base + 2 + index, 100 + index)
        }
        let provider = CountingProvider(messages: messages)
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "src", ts: TimeInterval(notificationTime)),
            reader: provider
        )

        XCTAssertEqual(result?.map(\.id), ["old0", "old1", "src", "post0", "post1", "post2"])

        // The hot path ran first and missed (bounded window from the stale
        // timestamp), then the paged walk found the source.
        let hot = provider.calls[0]
        XCTAssertEqual(hot.limit, GroupContextSourceLoader.fastPathPageLimit)
        XCTAssertEqual(hot.startTime, notificationTime - GroupContextSourceLoader.fastPathLookbackSeconds)
        XCTAssertEqual(hot.endTime, notificationTime + 1)

        XCTAssertGreaterThan(provider.sourceResolutionQueryCount, 2)
        XCTAssertEqual(provider.sourceResolutionQueryCount, 4) // 1 hot + 3 pages
        XCTAssertEqual(provider.calls[3].limit, 24) // paging still uses pageSize
    }

    func testHotPathPageCapMissFallsBackWithoutChangingTheWindow() {
        // The fast path is a prefix of the paged window, not a replacement: when
        // 300 newer messages exhaust its row cap the target is missed, and the
        // paged walk still has to produce the identical window.
        let targetTime = base + 296_400 // 1h before the banner timestamp
        let notificationTime = targetTime + 3600
        var messages: [MessageInfo] = [
            message("h0", "更早", targetTime - 100, 1),
            message("h1", "稍早", targetTime - 50, 2),
            message("src", "@你 原文", targetTime, 3)
        ]
        messages += (0..<300).map { index in
            message("c\(index)", "闲聊\(index)", targetTime + 1 + index, 100 + index)
        }
        let provider = CountingProvider(messages: messages)
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "src", ts: TimeInterval(notificationTime)),
            reader: provider
        )

        // 303 rows in the 6h look-back window; the newest 240 are all chatter,
        // so the hot path returns a full page that does not contain the source.
        XCTAssertEqual(provider.calls[0].limit, GroupContextSourceLoader.fastPathPageLimit)
        XCTAssertEqual(provider.calls[0].returnedCount, GroupContextSourceLoader.fastPathPageLimit)
        // The source is the 301st-newest row => 14 pages of 24 after the miss
        // (one row is re-included per page by the inclusive beforeCursor).
        XCTAssertEqual(provider.sourceResolutionQueryCount, 15)
        XCTAssertEqual(provider.calls[3].limit, 24)
        XCTAssertEqual(result?.map(\.id), ["h0", "h1", "src", "c0", "c1", "c2"])
    }

    // MARK: - Equivalence

    func testReturnedWindowEqualsExplicitSourceCentredExpectation() {
        // Locks the exact `[history…, source, …future]` contract: 8 trailing
        // history messages, the source, then 3 future messages. The hot path and
        // the paged fallback build this same array; D8 only changes how the
        // source is located.
        let messages = (0..<10).map { index in
            message("h\(index)", "历史\(index)", base + index, index + 1)
        } + [message("src", "@你 原文", base + 10, 11)]
          + (0..<5).map { index in
            message("f\(index)", "后续\(index)", base + 11 + index, 12 + index)
        }

        let provider = CountingProvider(messages: messages)
        let result = GroupContextSourceLoader.load(
            notification: notification(id: "src", ts: TimeInterval(base + 10)),
            reader: provider
        )

        let expected = (2...9).map { "h\($0)" } + ["src"] + ["f0", "f1", "f2"]
        XCTAssertEqual(result?.map(\.id), expected)
        XCTAssertEqual(result?.count, 12)
        XCTAssertEqual(provider.sourceResolutionQueryCount, 1)
    }

    // MARK: - Fixtures

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

private struct GetMessagesCall {
    let limit: Int
    let returnedCount: Int
    let startTime: Int?
    let endTime: Int?
    let oldestFirst: Bool
    let beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
    let afterCursor: (lastCreateTime: Int, lastLocalId: Int)?
}

/// Provider stub that records every `getMessages` call. Filter semantics mirror
/// the `Provider` stub in GroupContextSourceLoaderTests.swift exactly:
/// `endTime` is exclusive and `beforeCursor` keeps
/// `createTime < c || (== c && localId <= l)`.
private final class CountingProvider: GroupContextMessageProvider {
    let messages: [MessageInfo]
    private(set) var calls: [GetMessagesCall] = []

    init(messages: [MessageInfo]) {
        self.messages = messages
    }

    /// Every successful `load` finishes with exactly two window queries —
    /// history (beforeCursor set) and future (afterCursor set) — which D8 does
    /// not touch. Everything before them is source resolution: the hot path
    /// and/or the paged fallback.
    var sourceResolutionQueryCount: Int {
        calls.count - 2
    }

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
            if $0.createTime != $1.createTime {
                return oldestFirst ? $0.createTime < $1.createTime : $0.createTime > $1.createTime
            }
            return oldestFirst ? $0.localId < $1.localId : $0.localId > $1.localId
        }
        let result = Array(ordered.prefix(limit))
        calls.append(GetMessagesCall(
            limit: limit, returnedCount: result.count, startTime: startTime,
            endTime: endTime, oldestFirst: oldestFirst,
            beforeCursor: beforeCursor, afterCursor: afterCursor
        ))
        return result
    }
}
