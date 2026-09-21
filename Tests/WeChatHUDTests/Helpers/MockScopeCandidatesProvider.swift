import Foundation
@testable import WeChatHUD

actor MockScopeCandidatesProvider: ScopeCandidatesProvider {
    private var candidatesByRange: [DateRange: [ScopeCandidate]] = [:]
    private var defaultCandidates: [ScopeCandidate] = []
    private var scopeUnreadable = false
    private var samplesByUsername: [String: [String]] = [:]
    private var messagesByUsername: [String: [MessageInfo]] = [:]
    private var relationByUsername: [String: Relation] = [:]

    func setCandidates(_ items: [ScopeCandidate], for range: DateRange) {
        candidatesByRange[range] = items
    }

    /// Convenience: registers candidates returned for ANY range query.
    /// Tests rarely care about exact range matching against ScopeResolver
    /// (which produces a fresh `.end = now` each call), so this avoids
    /// hash misses.
    func setCandidatesForAnyRange(_ items: [ScopeCandidate]) {
        defaultCandidates = items
    }

    /// 「这次没读到名单」—— 与「没有可回顾的对话」是两件事。
    func setScopeUnreadable() {
        scopeUnreadable = true
    }

    func setSamples(_ samples: [String], for username: String) {
        samplesByUsername[username] = samples
    }

    func setMessages(_ msgs: [MessageInfo], for username: String) {
        messagesByUsername[username] = msgs
    }

    func setRelation(_ r: Relation, for username: String) {
        relationByUsername[username] = r
    }

    // MARK: - ScopeCandidatesProvider

    func candidates(in range: DateRange) async -> ScopeCandidatesRead {
        if scopeUnreadable { return .unreadable }
        if let exact = candidatesByRange[range] { return .value(exact) }
        return .value(defaultCandidates)
    }

    func sampleMessages(for usernames: [String], in range: DateRange, limit: Int) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for u in usernames {
            if let s = samplesByUsername[u] {
                out[u] = Array(s.prefix(limit))
            }
        }
        return out
    }

    func messages(for username: String, in range: DateRange, limit: Int) async -> [MessageInfo] {
        Array((messagesByUsername[username] ?? []).prefix(limit))
    }

    func relation(for username: String) async -> Relation {
        relationByUsername[username] ?? .unknown
    }
}
