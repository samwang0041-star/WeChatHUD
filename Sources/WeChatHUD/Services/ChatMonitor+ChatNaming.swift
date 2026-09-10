import Foundation

/// Conversation naming: the single source of truth for what a chat is
/// called in the UI.
///
/// WeChat does not name every group (357 of 1180 rooms on the reference
/// account carry an empty `nick_name`/`remark`), so a name has to be
/// assembled from several sources, in priority order:
///
/// 1. the name the user chose here (`chat_aliases`)
/// 2. whatever WeChat reports (remark → nickname)
/// 3. members recovered from `chat_room`/`chatroom_member`
/// 4. a readable placeholder — never the raw `…@chatroom` id
extension ChatMonitor {

    /// Display name for a chat, honouring a user-chosen alias first.
    func displayName(for chatUsername: String) -> String {
        if let cached = displayNameCache[chatUsername] { return cached }
        let resolved = resolveDisplayName(for: chatUsername)
        displayNameCache[chatUsername] = resolved
        return resolved
    }

    private func resolveDisplayName(for chatUsername: String) -> String {
        if let alias = store.chatAlias(for: chatUsername), !alias.isEmpty {
            return alias
        }
        if let contactName = store.getContact(username: chatUsername)?.displayName,
           !contactName.isEmpty,
           !ContactIdentityIndex.isRawChatIdentifier(contactName) {
            return contactName
        }
        if let whitelistName = store.getWhitelistEntry(username: chatUsername)?.displayName,
           !whitelistName.isEmpty,
           !ContactIdentityIndex.isRawChatIdentifier(whitelistName) {
            return whitelistName
        }
        let resolved = reader.displayName(for: chatUsername)
        if resolved.isEmpty || ContactIdentityIndex.isRawChatIdentifier(resolved) {
            return chatUsername.contains("@chatroom")
                ? ContactIdentityIndex.unnamedGroupPlaceholder
                : chatUsername
        }
        return resolved
    }

    /// True when WeChat itself has no name for this chat and the label is
    /// therefore a placeholder or a member-derived guess.
    func hasOnlyFallbackName(chatUsername: String) -> Bool {
        if let alias = store.chatAlias(for: chatUsername), !alias.isEmpty { return false }
        // Ask WeChat, not the display path — a member-derived label is still a
        // fallback even though it reads like a name.
        return !reader.hasWeChatName(for: chatUsername)
    }

    /// Reader-level name for a raw identifier, bypassing the alias table.
    ///
    /// Used when a raw id appears in a field that is not the chat itself —
    /// the model sometimes echoes the room id into `commit_to`. Returns nil
    /// when nothing better than the identifier is known.
    nonisolated func canonicalDisplayName(for rawIdentifier: String) -> String? {
        guard ContactIdentityIndex.isRawChatIdentifier(rawIdentifier) else { return nil }
        let resolved = reader.displayName(for: rawIdentifier)
        guard !resolved.isEmpty,
              !ContactIdentityIndex.isRawChatIdentifier(resolved) else { return nil }
        return resolved
    }

    /// Display name for a commitment's "答应谁" field.
    func commitmentTargetName(_ commitTo: String, chatUsername: String) -> String {
        if ContactIdentityIndex.isRawChatIdentifier(commitTo) {
            return canonicalDisplayName(for: commitTo) ?? displayName(for: chatUsername)
        }
        return commitTo.isEmpty ? displayName(for: chatUsername) : commitTo
    }

    /// Give a conversation a name of the user's own. Persisted everywhere the
    /// name was already cached so old rows don't keep the old label.
    @discardableResult
    func renameChat(chatUsername: String, displayName: String) throws -> Int {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let previousName = store.chatAlias(for: chatUsername) ?? reader.displayName(for: chatUsername)
        try store.setChatAlias(username: chatUsername, displayName: trimmed, previousName: previousName)
        refreshNamesAfterRename()
        return store.propagateChatName(username: chatUsername, displayName: trimmed)
    }

    /// Drop a user-chosen name and fall back to WeChat's own label.
    func clearChatAlias(chatUsername: String) throws {
        try store.removeChatAlias(username: chatUsername)
        displayNameCache.removeValue(forKey: chatUsername)
        let resolved = displayName(for: chatUsername)
        store.propagateChatName(username: chatUsername, displayName: resolved)
        refreshNamesAfterRename()
    }

    /// Re-publish every list that displays a conversation name.
    func refreshNamesAfterRename() {
        displayNameCache.removeAll()
        reloadAIData()
        rebuildInbox()
    }

    /// Rewrite rows persisted while a raw WeChat id was still shown.
    ///
    /// Idempotent and cheap once repaired: only rows whose stored name is a
    /// raw identifier are considered. Called from the scan loop so it also
    /// covers data written by an older build before this fix existed.
    @discardableResult
    func repairStaleChatNames() -> Int {
        let rows = store.uninformativeChatNameRows()
        guard !rows.isEmpty else { return 0 }

        // Resolve each chat once — the same chat appears in many tables.
        var resolvedByChat: [String: String] = [:]
        var updates: [(table: String, keyColumn: String, nameColumn: String, key: String, oldName: String, newName: String)] = []
        for row in rows {
            let resolved: String
            if let cached = resolvedByChat[row.key] {
                resolved = cached
            } else {
                resolved = displayName(for: row.key)
                resolvedByChat[row.key] = resolved
            }
            // Nothing better than what is stored — leave the row alone rather
            // than churn the database on every scan.
            guard resolved != row.name,
                  !ContactIdentityIndex.isRawChatIdentifier(resolved) else { continue }
            updates.append((row.table, row.keyColumn, row.nameColumn, row.key, row.name, resolved))
        }
        return store.applyResolvedChatNames(updates)
    }

    /// Rewrite `commit_to` values that are raw chat ids.
    @discardableResult
    func repairStaleCommitTargets() -> Int {
        let rows = store.uninformativeCommitTargets()
        guard !rows.isEmpty else { return 0 }
        var updates: [(msgUID: String, oldTarget: String, newTarget: String)] = []
        for row in rows {
            guard let resolved = canonicalDisplayName(for: row.target) else { continue }
            updates.append((row.msgUID, row.target, resolved))
        }
        return store.applyResolvedCommitTargets(updates)
    }
}
