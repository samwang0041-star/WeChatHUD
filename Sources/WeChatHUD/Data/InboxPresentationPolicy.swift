import Foundation

enum InboxPresentationPolicy {
    /// The three buckets the pending list is made of. Anything else — an AI
    /// failure row, a sync issue, an idle row — is not part of the list, and
    /// must not be counted by its header either.
    static func buckets(
        _ items: [InboxItem]
    ) -> (action: [InboxItem], fyi: [InboxItem], passive: [InboxItem]) {
        (
            items.filter { $0.participatesInActionQueue },
            items.filter { $0.semanticState == .groupMentionFYI },
            items.filter { $0.isAggregatablePassiveUpdate }
        )
    }

    /// How many items the list stands for, folded tail included. This is the
    /// number the 「待处理 (N)」 header prints: it used to print the size of the
    /// action bucket only, so a panel of one reply-needed row and two group
    /// @s said 「1」 above three rows.
    static func pendingCount(_ items: [InboxItem]) -> Int {
        let split = buckets(items)
        return split.action.count + split.fyi.count + split.passive.count
    }

    static func visibleItems(
        _ items: [InboxItem],
        showAllPassive: Bool = false,
        passiveLimit: Int = 3,
        limit: Int = 10
    ) -> [InboxItem] {
        let split = buckets(items)
        let nonPassiveItems = split.action + split.fyi
        let remainingSlots = max(0, limit - nonPassiveItems.count)
        let passiveVisibleLimit = showAllPassive ? remainingSlots : min(passiveLimit, remainingSlots)
        let visiblePassive = Array(split.passive.prefix(passiveVisibleLimit))
        return Array((nonPassiveItems + visiblePassive).prefix(limit))
    }

    static func hiddenPassiveUpdateCount(
        _ items: [InboxItem],
        showAllPassive: Bool = false,
        passiveLimit: Int = 3,
        limit: Int = 10
    ) -> Int {
        guard !showAllPassive else { return 0 }
        let split = buckets(items)
        let remainingSlots = max(0, limit - split.action.count - split.fyi.count)
        let visiblePassiveCount = min(passiveLimit, remainingSlots)
        return max(0, split.passive.count - visiblePassiveCount)
    }

    static func summaryCandidates(
        _ items: [InboxItem],
        passiveLimit: Int = 3,
        limit: Int = 10
    ) -> [InboxItem] {
        visibleItems(items, showAllPassive: false, passiveLimit: passiveLimit, limit: limit)
            .filter(shouldGenerateRowSummary)
    }

    static func shouldGenerateRowSummary(for item: InboxItem) -> Bool {
        switch item.semanticState {
        case .handled, .aiFailed, .aiLoading, .idle, .syncIssue:
            return false
        default:
            return item.participatesInActionQueue
                || item.semanticState == .groupMentionFYI
                || item.isAggregatablePassiveUpdate
        }
    }
}
