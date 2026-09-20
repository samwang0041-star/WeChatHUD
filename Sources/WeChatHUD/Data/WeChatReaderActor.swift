import Foundation

/// Async facade over `WeChatReader` for scan/off-main callers.
///
/// SwiftUI still owns the `ObservableObject` reader. Scan paths hop through
/// this actor so mutable cache access has a clear isolation boundary while
/// the class + `NSRecursiveLock` migration continues.
actor WeChatReaderActor {
    /// Underlying reader. Still `@unchecked Sendable` with an internal lock;
    /// prefer actor methods from async scan code instead of capturing `reader`
    /// into detached work.
    nonisolated let reader: WeChatReader

    init(_ reader: WeChatReader) {
        self.reader = reader
    }

    /// - Returns: whether `contact.db` actually changed, i.e. whether a peer
    /// could have been renamed. The scan-apply tail uses this instead of
    /// asking again on the main actor, which would take the reader's DB lock
    /// there.
    @discardableResult
    func prepareForScan() throws -> Bool {
        // Marks are per-scan facts (see `WeChatReader.partialReadChats`), and
        // this is the one place every scan path starts from.
        reader.clearPartialReadMarks()
        try reader.loadKeys()
        return try reader.refreshContactsIfChanged()
    }

    func sessions() throws -> [SessionInfo] {
        try reader.getSessions()
    }

    func findMessageDBs() -> [String] {
        reader.findMessageDBs()
    }

    func refreshIfChanged(relPath: String) throws -> Bool {
        try reader.refreshIfChanged(relPath: relPath)
    }

    func messagesBatch(_ requests: [WeChatReader.MessageBatchRequest]) throws -> [String: [MessageInfo]] {
        try reader.getMessagesBatch(requests)
    }

    /// Whether the page just returned for this chat was assembled with at least
    /// one shard that could not be read. See `WeChatReader.partialReadChats` —
    /// a short page and a complete page are otherwise indistinguishable here,
    /// and the caller is about to persist a cursor.
    func didReadPartially(chatUsername: String) -> Bool {
        reader.didReadPartially(chatUsername: chatUsername)
    }

    func getMessages(
        chatUsername: String,
        limit: Int = 50,
        sinceLocalId: Int? = nil,
        afterCursor: (lastCreateTime: Int, lastLocalId: Int)? = nil,
        oldestFirst: Bool = false,
        startTime: Int? = nil,
        endTime: Int? = nil,
        beforeCursor: (lastCreateTime: Int, lastLocalId: Int)? = nil
    ) throws -> [MessageInfo] {
        try reader.getMessages(
            chatUsername: chatUsername,
            limit: limit,
            sinceLocalId: sinceLocalId,
            afterCursor: afterCursor,
            oldestFirst: oldestFirst,
            startTime: startTime,
            endTime: endTime,
            beforeCursor: beforeCursor
        )
    }

    func myUsername() -> String {
        reader.myUsername()
    }

    func displayName(for username: String) -> String {
        reader.displayName(for: username)
    }

    func mySelfNames() -> Set<String> {
        reader.mySelfNames
    }

    func dbDir() -> String {
        reader.dbDir
    }

    func hasAccountSwitched() -> Bool {
        reader.hasAccountSwitched()
    }

    func refreshContactsIfChanged(strict: Bool = false) throws -> Bool {
        try reader.refreshContactsIfChanged(strict: strict)
    }

    func allContacts() -> [String: String] {
        reader.allContacts()
    }

    func weChatRemark(for username: String) -> String? {
        reader.weChatRemark(for: username)
    }

    func weChatNickName(for username: String) -> String? {
        reader.weChatNickName(for: username)
    }

    func weChatSearchNames(for username: String) -> [String] {
        reader.weChatSearchNames(for: username)
    }

    func hasWeChatName(for username: String) -> Bool {
        reader.hasWeChatName(for: username)
    }

    func normalizeContactMentions(in text: String) -> String {
        reader.normalizeContactMentions(in: text)
    }

    func bulkMessageStats(
        chatUsernames: [String],
        selfNames: Set<String>,
        sinceTsEpoch: Int = 0,
        myUsername: String = "",
        myDisplayName: String = "",
        recentSinceTs: Int = 0
    ) -> [String: WeChatReader.BulkChatStats]? {
        reader.bulkMessageStats(
            chatUsernames: chatUsernames,
            selfNames: selfNames,
            sinceTsEpoch: sinceTsEpoch,
            myUsername: myUsername,
            myDisplayName: myDisplayName,
            recentSinceTs: recentSinceTs
        )
    }
}
