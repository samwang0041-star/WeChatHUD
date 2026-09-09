import Foundation

/// Reads the candidate and message material used by the whitelist
/// recommendation flow. The reader is deliberately kept behind injected
/// closures so the aggregation and partial-failure behavior can be tested
/// without a live WeChat database.
struct ContactRecommendationScanSource: Sendable {
    struct Candidate: Sendable, Hashable {
        let username: String
        let displayName: String
        let isGroup: Bool
        let recentCount: Int
    }

    struct Message: Sendable, Hashable {
        let sender: String
        let body: String
    }

    struct MessageBundle: Sendable {
        let candidateIndex: Int
        let candidate: Candidate
        let messages: [Message]
    }

    struct MessageReadFailure: Sendable {
        let candidate: Candidate
    }

    struct Progress: Sendable {
        let completed: Int
        let total: Int
        let succeeded: Int
        let failed: Int
        let empty: Int
    }

    struct Result: Sendable {
        let candidates: [Candidate]
        let messageBundles: [MessageBundle]
        let failures: [MessageReadFailure]
        let emptyMessageCount: Int

        var completedCount: Int { messageBundles.count + failures.count + emptyMessageCount }
        var failedCount: Int { failures.count }
    }

    typealias CandidateReader = @Sendable (Int) throws -> [Candidate]
    typealias MessageReader = @Sendable (String, Int) throws -> [Message]

    private let readCandidates: CandidateReader
    private let readMessages: MessageReader

    init(reader: WeChatReader) {
        self.init(
            readCandidates: { limit in
                try reader.loadKeys()
                try reader.refreshContactsIfChanged(strict: true)
                return try reader.topActiveContacts(limit: limit, strict: true).map {
                    Candidate(
                        username: $0.username,
                        displayName: $0.displayName,
                        isGroup: $0.isGroup,
                        recentCount: $0.recentCount
                    )
                }
            },
            readMessages: { username, limit in
                try reader.getMessages(chatUsername: username, limit: limit).map {
                    Message(sender: $0.senderName, body: $0.text)
                }
            }
        )
    }

    init(readCandidates: @escaping CandidateReader, readMessages: @escaping MessageReader) {
        self.readCandidates = readCandidates
        self.readMessages = readMessages
    }

    /// Read candidates synchronously for legacy callers. New UI scans should
    /// use `scan`, which moves both candidate and message reads off the main
    /// actor and reports progress.
    func loadCandidates(limit: Int, excluding: Set<String> = []) throws -> [Candidate] {
        let requested = max(0, limit) + excluding.count
        return try readCandidates(requested)
            .filter { !excluding.contains($0.username) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Exposed for diagnostics and tests that need to assert a real reader
    /// error instead of observing an empty fallback.
    func readMessages(chatUsername: String, limit: Int) throws -> [Message] {
        try readMessages(chatUsername, limit)
    }

    /// Read all candidate message windows away from the caller's actor. A
    /// single unreadable chat does not discard the other results; its error is
    /// represented by its candidate in `failures` for the UI to report a
    /// count without exposing database paths or raw reader errors.
    func scan(
        limit: Int,
        messageLimit: Int,
        excluding: Set<String> = [],
        progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let readCandidates = self.readCandidates
        let readMessages = self.readMessages
        let requestedLimit = max(0, limit) + excluding.count
        let requestedMessageLimit = max(0, messageLimit)

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rawCandidates = try readCandidates(requestedLimit)
            try Task.checkCancellation()
            let candidates = rawCandidates
                .filter { !excluding.contains($0.username) }
                .prefix(max(0, limit))
                .map { $0 }

            var bundles: [MessageBundle] = []
            var failures: [MessageReadFailure] = []
            var emptyMessageCount = 0
            bundles.reserveCapacity(candidates.count)
            failures.reserveCapacity(candidates.count)

            for (index, candidate) in candidates.enumerated() {
                do {
                    try Task.checkCancellation()
                    let messages = try readMessages(candidate.username, requestedMessageLimit)
                    try Task.checkCancellation()
                    if messages.isEmpty {
                        emptyMessageCount += 1
                    } else {
                        bundles.append(MessageBundle(
                            candidateIndex: index,
                            candidate: candidate,
                            messages: messages
                        ))
                    }
                } catch {
                    if error is CancellationError { throw error }
                    failures.append(MessageReadFailure(candidate: candidate))
                }

                try Task.checkCancellation()
                await progress(Progress(
                    completed: index + 1,
                    total: candidates.count,
                    succeeded: bundles.count,
                    failed: failures.count,
                    empty: emptyMessageCount
                ))
            }

            return Result(
                candidates: candidates,
                messageBundles: bundles,
                failures: failures,
                emptyMessageCount: emptyMessageCount
            )
        }

        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }
}
