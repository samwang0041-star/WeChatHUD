import Foundation

/// Lightweight message shape consumed by `RedBannerDetector` (Spec §6.7).
/// Independent from the heavier `MessageInfo` so adapters can choose what
/// to materialize.
struct SimpleMessage: Sendable {
    let id: String       // matches MessageInfo.id (UID)
    let text: String
    let timestamp: Date
}

/// Adapter protocol for "my messages in chat between dates" queries —
/// the only message-side dependency of `RedBannerDetector`. Real impl
/// goes through `ChatMonitor` which wraps `WeChatReader.getMessages`.
protocol MessageQuery: Sendable {
    func myMessages(chatUsername: String, since: Date, until: Date) async -> [SimpleMessage]
}

/// Adapter protocol for the four queries `RetrospectiveJob` makes against
/// the conversation source. Real impl is `ChatMonitorScopeProvider`.
protocol ScopeCandidatesProvider: Sendable {
    /// All whitelist conversations with at least one message in `range`.
    func candidates(in range: DateRange) async -> [ScopeCandidate]
    /// First N sample messages per chat — fed to `GroupScreener` for
    /// is-this-work-related triage. Plain text strings, no metadata.
    func sampleMessages(for usernames: [String], in range: DateRange, limit: Int) async -> [String: [String]]
    /// Full messages for one chat in range, up to `limit`. Used by
    /// `RetrospectiveAnalyzer` for deep extraction.
    func messages(for username: String, in range: DateRange, limit: Int) async -> [MessageInfo]
    /// Per-contact relation classification (looked up from
    /// `RelationshipProfile.hierarchy` — see ChatMonitorScopeProvider for
    /// the .external→.client / .personal→.friend mapping).
    func relation(for username: String) async -> Relation
}
