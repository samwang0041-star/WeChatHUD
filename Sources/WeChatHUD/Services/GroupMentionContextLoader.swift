import Foundation

/// Resolves a group @ notification to the exact source message and a small
/// chronological window around it. This prevents later group chatter from
/// being mistaken for the message that triggered the notification.
enum GroupContextSourceLoader {
    /// Look-back window (seconds) for the single "hot path" query that resolves
    /// the source message. The banner timestamp is
    /// `min(now, max(msg.createTime, session.lastTimestamp))`, so the source
    /// normally sits at or shortly before the notification timestamp; a bounded
    /// window from that timestamp finds it without paging through older chatter.
    ///
    /// Tradeoff (query count vs rows per query): a wider window keeps the common
    /// case at one query but makes that query return more rows (capped by
    /// `fastPathPageLimit`) and to do more index scanning; a narrower window
    /// returns fewer rows per query but falls through to the 128-page loop more
    /// often, which is the cost this fast path exists to avoid. Rows per query
    /// stay bounded either way, so correctness does not depend on this value.
    static let fastPathLookbackSeconds = 6 * 60 * 60

    /// Row cap for the single hot-path query. Deliberately larger than the
    /// fallback's `pageSize` (24) so one round trip covers the whole look-back
    /// window in realistic group traffic (10x the old page size) while still
    /// bounding the payload; if the target falls outside this cap the paged
    /// fallback below still finds it.
    static let fastPathPageLimit = 240

    /// Longest silence that still counts as the same conversation.
    ///
    /// The reported defect this bounds: `historyCount` is a *row* count, and
    /// the only other limit was the seven-day paging window below. On a group
    /// that had gone quiet, an @mention on Tuesday therefore pulled Monday's
    /// chatter in as its "context" — and because that context is what
    /// `group_analysis_v1` summarises, the panel's 话题 / 决议 / 依据 lines were
    /// built partly from messages that had nothing to do with the @.
    ///
    /// So the window is now a *conversation*, not a row count: walking back
    /// from the source, a message is only kept while each step is within this
    /// gap of the message after it.
    ///
    /// The value is a *session* boundary, not a precise measure: long enough
    /// that one working session survives a lunch break, short enough that an
    /// overnight or multi-day silence always ends the link. Both properties are
    /// pinned as behaviour by `testSameWorkingSessionStaysTogether` and
    /// `testPreviousEveningIsADifferentConversation`, so the number can move as
    /// long as those two hold. (It was first set to two hours; that test caught
    /// a three-hour lunch break being treated as the end of the conversation.)
    ///
    /// The source itself is never dropped, however old: it is the anchor the
    /// notification named, and
    /// `testSourceAnchoredAnalysisKeepsSourceOlderThan48Hours` pins that.
    static let maxConversationGapSeconds = 6 * 60 * 60

    /// Trim `history` (ascending, all older than `source`) to the run that is
    /// contiguous with `source` under `maxConversationGapSeconds`.
    ///
    /// Split out as a pure function so the rule is testable without a reader,
    /// a database or a clock.
    static func conversationHistory(
        _ history: [MessageInfo],
        leadingTo source: MessageInfo,
        maxGap: Int = maxConversationGapSeconds
    ) -> [MessageInfo] {
        var kept: [MessageInfo] = []
        // Walk backwards: each candidate must be within `maxGap` of the message
        // already kept after it (the source itself for the first step).
        var edge = source.createTime
        for candidate in history.reversed() {
            guard edge - candidate.createTime <= maxGap else { break }
            kept.append(candidate)
            edge = candidate.createTime
        }
        return kept.reversed()
    }

    /// Trim `following` (ascending, all newer than `source`) to the run that is
    /// contiguous with `source`. Same rule, forwards, so a message sent days
    /// later cannot be read as a reply to the @.
    static func conversationContinuation(
        _ following: [MessageInfo],
        from source: MessageInfo,
        maxGap: Int = maxConversationGapSeconds
    ) -> [MessageInfo] {
        var kept: [MessageInfo] = []
        var edge = source.createTime
        for candidate in following {
            guard candidate.createTime - edge <= maxGap else { break }
            kept.append(candidate)
            edge = candidate.createTime
        }
        return kept
    }

    /// The run of `messages` that belongs to the newest message's conversation,
    /// oldest-first.
    ///
    /// The sibling of `conversationHistory(_:leadingTo:maxGap:)` for the one
    /// caller that has no named source: an on-demand analysis of “这个群现在在
    /// 聊什么” is anchored on the newest message, and anything more than
    /// `maxGap` behind that message is a *different* conversation. Age alone is
    /// not enough to say that — a 48-hour cap still calls two days of unrelated
    /// exchanges one discussion. Measured on a followed group: its newest 50
    /// messages spanned 42 hours and four separate exchanges, and
    /// `group_analysis_v1` was asked to summarise them as one situation.
    ///
    /// Order does not matter on the way in (`getMessages` is newest-first by
    /// default and the analysis path reverses it); the result is oldest-first
    /// for prompt rendering.
    static func currentConversation(
        _ messages: [MessageInfo],
        maxGap: Int = maxConversationGapSeconds
    ) -> [MessageInfo] {
        let ordered = messages.sorted(by: order)
        guard let newest = ordered.last else { return [] }
        return conversationHistory(Array(ordered.dropLast()), leadingTo: newest, maxGap: maxGap)
            + [newest]
    }

    static func newestFirst(_ messages: [MessageInfo]) -> [MessageInfo] {
        messages.sorted {
            if $0.createTime != $1.createTime { return $0.createTime > $1.createTime }
            return $0.localId > $1.localId
        }
    }

    static func load(
        notification: HUDNotification,
        reader: any GroupContextMessageProvider,
        historyCount: Int = 8,
        futureCount: Int = 3
    ) -> [MessageInfo]? {
        guard notification.kind == .groupAt, !notification.messageID.isEmpty else { return nil }

        let targetTimestamp = Int(notification.timestamp.timeIntervalSince1970)
        let startTime = max(0, targetTimestamp - 7 * 24 * 60 * 60)
        let endTime = targetTimestamp == Int.max ? nil : targetTimestamp + 1
        let pageSize = 24
        var beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
        var source: MessageInfo?

        // Hot path (D8): one bounded query from the known notification
        // timestamp. The fast window is the newest part of the same paging
        // window, so when it contains the target it is also the first match the
        // loop below would have found — results cannot diverge. When it does not
        // contain the target we fall through to the unchanged paged walk.
        let fastPathStartTime = max(startTime, targetTimestamp - fastPathLookbackSeconds)
        if let page = try? reader.getMessages(
            chatUsername: notification.chatUsername,
            limit: fastPathPageLimit,
            sinceLocalId: nil,
            afterCursor: nil,
            oldestFirst: false,
            startTime: fastPathStartTime,
            endTime: endTime,
            beforeCursor: nil
        ), let match = page.first(where: {
            $0.id == notification.messageID && $0.chatUsername == notification.chatUsername
        }) {
            source = match
        }

        if source == nil {
            for _ in 0..<128 {
                guard let page = try? reader.getMessages(
                    chatUsername: notification.chatUsername,
                    limit: pageSize,
                    sinceLocalId: nil,
                    afterCursor: nil,
                    oldestFirst: false,
                    startTime: startTime,
                    endTime: endTime,
                    beforeCursor: beforeCursor
                ), !page.isEmpty else { break }

                if let match = page.first(where: {
                    $0.id == notification.messageID && $0.chatUsername == notification.chatUsername
                }) {
                    source = match
                    break
                }

                guard let oldest = page.min(by: order) else { break }
                let next = (lastCreateTime: oldest.createTime, lastLocalId: oldest.localId)
                if beforeCursor?.lastCreateTime == next.lastCreateTime,
                   beforeCursor?.lastLocalId == next.lastLocalId { break }
                beforeCursor = next
                if page.count < pageSize { break }
            }
        }
        guard let source else { return nil }

        let cursor = (lastCreateTime: source.createTime, lastLocalId: source.localId)
        let before = (try? reader.getMessages(
            chatUsername: notification.chatUsername,
            limit: historyCount + 1,
            sinceLocalId: nil,
            afterCursor: nil,
            oldestFirst: false,
            startTime: startTime,
            endTime: source.createTime + 1,
            beforeCursor: cursor
        )) ?? []
        let history = before
            .filter { $0.chatUsername == notification.chatUsername && $0.id != source.id }
            .sorted(by: order)
            .suffix(historyCount)
        // `suffix(historyCount)` is a row count; this is what makes it a
        // conversation. See `maxConversationGapSeconds`.
        let contiguousHistory = conversationHistory(Array(history), leadingTo: source)

        let future = (try? reader.getMessages(
            chatUsername: notification.chatUsername,
            limit: futureCount,
            sinceLocalId: nil,
            afterCursor: cursor,
            oldestFirst: true,
            startTime: source.createTime,
            endTime: nil,
            beforeCursor: nil
        )) ?? []
        let following = conversationContinuation(
            future.filter { $0.chatUsername == notification.chatUsername }.sorted(by: order),
            from: source
        )
        return contiguousHistory + [source] + following
    }


    /// Actor-isolated variant of `load(notification:reader:)`. Same paging /
    /// hot-path semantics; message reads hop through `WeChatReaderActor`.
    static func load(
        notification: HUDNotification,
        readerActor: WeChatReaderActor,
        historyCount: Int = 8,
        futureCount: Int = 3
    ) async -> [MessageInfo]? {
        guard notification.kind == .groupAt, !notification.messageID.isEmpty else { return nil }

        let targetTimestamp = Int(notification.timestamp.timeIntervalSince1970)
        let startTime = max(0, targetTimestamp - 7 * 24 * 60 * 60)
        let endTime = targetTimestamp == Int.max ? nil : targetTimestamp + 1
        let pageSize = 24
        var beforeCursor: (lastCreateTime: Int, lastLocalId: Int)?
        var source: MessageInfo?

        let fastPathStartTime = max(startTime, targetTimestamp - fastPathLookbackSeconds)
        if let page = try? await readerActor.getMessages(
            chatUsername: notification.chatUsername,
            limit: fastPathPageLimit,
            sinceLocalId: nil,
            afterCursor: nil,
            oldestFirst: false,
            startTime: fastPathStartTime,
            endTime: endTime,
            beforeCursor: nil
        ), let match = page.first(where: {
            $0.id == notification.messageID && $0.chatUsername == notification.chatUsername
        }) {
            source = match
        }

        if source == nil {
            for _ in 0..<128 {
                guard let page = try? await readerActor.getMessages(
                    chatUsername: notification.chatUsername,
                    limit: pageSize,
                    sinceLocalId: nil,
                    afterCursor: nil,
                    oldestFirst: false,
                    startTime: startTime,
                    endTime: endTime,
                    beforeCursor: beforeCursor
                ), !page.isEmpty else { break }

                if let match = page.first(where: {
                    $0.id == notification.messageID && $0.chatUsername == notification.chatUsername
                }) {
                    source = match
                    break
                }

                guard let oldest = page.min(by: order) else { break }
                let next = (lastCreateTime: oldest.createTime, lastLocalId: oldest.localId)
                if beforeCursor?.lastCreateTime == next.lastCreateTime,
                   beforeCursor?.lastLocalId == next.lastLocalId { break }
                beforeCursor = next
                if page.count < pageSize { break }
            }
        }
        guard let source else { return nil }

        let cursor = (lastCreateTime: source.createTime, lastLocalId: source.localId)
        let before = (try? await readerActor.getMessages(
            chatUsername: notification.chatUsername,
            limit: historyCount + 1,
            sinceLocalId: nil,
            afterCursor: nil,
            oldestFirst: false,
            startTime: startTime,
            endTime: source.createTime + 1,
            beforeCursor: cursor
        )) ?? []
        let history = before
            .filter { $0.chatUsername == notification.chatUsername && $0.id != source.id }
            .sorted(by: order)
            .suffix(historyCount)
        let contiguousHistory = conversationHistory(Array(history), leadingTo: source)

        let future = (try? await readerActor.getMessages(
            chatUsername: notification.chatUsername,
            limit: futureCount,
            sinceLocalId: nil,
            afterCursor: cursor,
            oldestFirst: true,
            startTime: source.createTime,
            endTime: nil,
            beforeCursor: nil
        )) ?? []
        let following = conversationContinuation(
            future.filter { $0.chatUsername == notification.chatUsername }.sorted(by: order),
            from: source
        )
        return contiguousHistory + [source] + following
    }

    private static func order(_ lhs: MessageInfo, _ rhs: MessageInfo) -> Bool {
        if lhs.createTime != rhs.createTime { return lhs.createTime < rhs.createTime }
        return lhs.localId < rhs.localId
    }
}
