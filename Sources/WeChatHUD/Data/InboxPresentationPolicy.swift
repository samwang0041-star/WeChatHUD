import Foundation

enum InboxPresentationPolicy {
    static func visibleItems(
        _ items: [InboxItem],
        showAllPassive: Bool = false,
        passiveLimit: Int = 3,
        limit: Int = 10
    ) -> [InboxItem] {
        let actionItems = items.filter { $0.participatesInActionQueue }
        let fyiItems = items.filter { $0.semanticState == .groupMentionFYI }
        let passiveItems = items.filter { $0.isAggregatablePassiveUpdate }
        let nonPassiveItems = actionItems + fyiItems
        let remainingSlots = max(0, limit - nonPassiveItems.count)
        let passiveVisibleLimit = showAllPassive ? remainingSlots : min(passiveLimit, remainingSlots)
        let visiblePassive = Array(passiveItems.prefix(passiveVisibleLimit))
        return Array((nonPassiveItems + visiblePassive).prefix(limit))
    }

    static func hiddenPassiveUpdateCount(
        _ items: [InboxItem],
        showAllPassive: Bool = false,
        passiveLimit: Int = 3,
        limit: Int = 10
    ) -> Int {
        guard !showAllPassive else { return 0 }
        let actionItems = items.filter { $0.participatesInActionQueue }
        let fyiItems = items.filter { $0.semanticState == .groupMentionFYI }
        let passiveCount = items.filter { $0.isAggregatablePassiveUpdate }.count
        let remainingSlots = max(0, limit - actionItems.count - fyiItems.count)
        let visiblePassiveCount = min(passiveLimit, remainingSlots)
        return max(0, passiveCount - visiblePassiveCount)
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
