import Foundation

/// Real-data adapter from `ChatMonitor` (whitelist + WeChatReader) to
/// `ScopeCandidatesProvider`. Plan M6.0.
///
/// Holds a weak ChatMonitor reference; if monitor is deallocated, every
/// query returns empty (job will see zero candidates and finalize as
/// completed with chatCount=0).
actor ChatMonitorScopeProvider: ScopeCandidatesProvider {
    private weak var monitor: ChatMonitor?

    init(monitor: ChatMonitor) {
        self.monitor = monitor
    }

    func candidates(in range: DateRange) async -> [ScopeCandidate] {
        guard let monitor else { return [] }
        let whitelist = monitor.hudStore.getWhitelist()
        let myUname = monitor.myUsername
        var out: [ScopeCandidate] = []
        for entry in whitelist {
            let inRange = monitor.messagesInRange(
                chatUsername: entry.id, start: range.start, end: range.end
            )
            guard !inRange.isEmpty else { continue }
            let myCount = inRange.filter { $0.senderUsername == myUname }.count
            // WhitelistEntry.id is the chatUsername; group rooms end in "@chatroom"
            let isGroup = entry.id.hasSuffix("@chatroom")
            out.append(ScopeCandidate(
                chatUsername: entry.id,
                chatName: entry.displayName,
                isGroup: isGroup,
                msgCountInRange: inRange.count,
                myMsgCountInRange: myCount
            ))
        }
        return out
    }

    func sampleMessages(for usernames: [String], in range: DateRange, limit: Int) async -> [String: [String]] {
        guard let monitor else { return [:] }
        var out: [String: [String]] = [:]
        for u in usernames {
            out[u] = monitor.sampleMessageTexts(
                chatUsername: u, start: range.start, end: range.end, limit: limit
            )
        }
        return out
    }

    func messages(for username: String, in range: DateRange, limit: Int) async -> [MessageInfo] {
        guard let monitor else { return [] }
        let all = monitor.messagesInRange(
            chatUsername: username, start: range.start, end: range.end,
            fetchLimit: max(1000, limit * 5)
        )
        return Array(all.prefix(limit))
    }

    func relation(for username: String) async -> Relation {
        guard let monitor else { return .unknown }
        guard let profile = monitor.hudStore.getRelationshipProfile(username: username) else {
            return .unknown
        }
        switch profile.hierarchy {
        case .superior:    return .superior
        case .peer:        return .peer
        case .subordinate: return .subordinate
        case .external:    return .client
        case .personal:    return .friend
        }
    }
}
