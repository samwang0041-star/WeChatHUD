import Foundation

/// Surfaces "you committed but didn't follow up" warnings (Spec §6.7,
/// §3.4). Runs after each RetrospectiveJob completion + can be invoked
/// independently for the floating-tab banner refresh.
struct RedBannerCandidate: Sendable, Identifiable {
    let id: Int   // todoID
    let content: String
    let deadline: Date?
    let counterpart: String?
    let chatName: String
    let daysSinceCommit: Int
}

actor RedBannerDetector {
    private let store: HUDStore
    private let messageQuery: any MessageQuery

    init(store: HUDStore, messageQuery: any MessageQuery) {
        self.store = store
        self.messageQuery = messageQuery
    }

    /// 14-day window of my pending commitments. For each, scan my own
    /// follow-up messages in the source chat — if Jaccard(msg, todo.content)
    /// > 0.3 anywhere after createdAt, treat as followed-up and skip.
    /// Caps at top 3 sorted by daysSinceCommit DESC.
    func detect() async -> [RedBannerCandidate] {
        let now = Date()
        let recent = now.addingTimeInterval(-14 * 86400)
        let candidates = store.pendingTodos(direction: .mine, since: recent)
            .filter { ($0.deadline ?? now) <= now.addingTimeInterval(86400) }

        var banners: [RedBannerCandidate] = []
        for todo in candidates {
            if store.hasDismissal(todoID: todo.id, validForHours: 24) { continue }

            let myMsgs = await messageQuery.myMessages(
                chatUsername: todo.sourceChatUsername,
                since: todo.createdAt,
                until: now
            )
            let followedUp = myMsgs.contains { msg in
                TextSimilarity.jaccardCJK(msg.text, todo.content) > 0.3
            }
            if followedUp { continue }

            banners.append(RedBannerCandidate(
                id: todo.id,
                content: todo.content,
                deadline: todo.deadline,
                counterpart: todo.involved.first,
                chatName: todo.sourceChatName,
                daysSinceCommit: max(0, Int(now.timeIntervalSince(todo.createdAt) / 86400))
            ))
        }
        return banners
            .sorted { $0.daysSinceCommit > $1.daysSinceCommit }
            .prefix(3)
            .map { $0 }
    }
}
