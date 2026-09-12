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
        let following = future.filter { $0.chatUsername == notification.chatUsername }
        return Array(history) + [source] + following
    }

    private static func order(_ lhs: MessageInfo, _ rhs: MessageInfo) -> Bool {
        if lhs.createTime != rhs.createTime { return lhs.createTime < rhs.createTime }
        return lhs.localId < rhs.localId
    }
}
