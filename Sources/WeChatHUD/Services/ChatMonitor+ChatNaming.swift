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
        let resolved = reader.displayName(for: chatUsername)
        // The reader's last resort is to hand back the username itself, and it
        // does that whenever its contact cache is empty — right after an
        // account switch, before the first contact refresh. Such an echo is not
        // "raw" by shape for a legacy weixinid, so the old check let it through
        // and the UI printed an account id over a name already in hud.sqlite3.
       if resolved.isEmpty || resolved == chatUsername
           || ContactIdentityIndex.isRawChatIdentifier(resolved) {
            switch store.storedDisplayName(chatUsername) {
            case .value(let storedName):
                return storedName
            case .unreadable:
                // A failed read is not 「this chat has no name」. Printing the
                // username or 未命名 would overwrite a name that is still in sqlite.
                return ContactIdentityIndex.unreadableNamePlaceholder
            case .absent:
                // Nothing readable anywhere. Returning the raw username puts an
                // account id on screen (the daily report showed "preview-colleague"
                // next to fully named rows). The placeholder keeps the row
                // honest about not knowing the name yet; callers that show it
                // alongside real names do not have to special-case it.
                if ContactIdentityIndex.isRawChatIdentifier(chatUsername), !MessageHelpers.isGroupChat(chatUsername) {
                    return ContactIdentityIndex.unnamedContactPlaceholder
                }
                return MessageHelpers.isGroupChat(chatUsername)
                    ? ContactIdentityIndex.unnamedGroupPlaceholder
                    : chatUsername
            }
       }
        return resolved
    }

    /// Names to type into WeChat search. Live remark first, then nickname,
    /// stale stored labels, username. Old remarks must not be the only query —
    /// WeChat search matches the current remark. Deliberately no HUD alias:
    /// an alias exists only in HUD's database, so WeChat can never match it
    /// to the right chat — but it can match a same-named stranger.
    func weChatSearchNames(for chatUsername: String) -> [String] {
        _ = try? reader.refreshContactsIfChanged()
        displayNameCache.removeValue(forKey: chatUsername)
        // propagateChatName writes a user-chosen alias INTO contacts and
        // whitelist display_name, so a "stored" name can be a HUD-only
        // label. The alias specifically must not reach WeChat search —
        // it can match a same-named stranger. Other stored names came
        // from WeChat itself and remain valid fallbacks.
       let alias = store.chatAlias(for: chatUsername)
        let stored: [String]
        switch store.storedDisplayName(chatUsername) {
        case .value(let name):
            stored = name == alias ? [] : [name]
        case .absent, .unreadable:
            stored = []
        }
        return WeChatOpenSearch.names(
            liveRemark: reader.weChatRemark(for: chatUsername),
            liveNick: reader.weChatNickName(for: chatUsername),
            stored: stored,
            username: chatUsername
        )
    }

    /// Names that are safe to *search with* and to validate the opened chat
    /// against when the goal is delivering a message.
    ///
    /// `weChatSearchNames` also feeds the HUD alias into the same array, and
    /// that array is both the search input and the accepted-title set. A HUD
    /// alias exists only in HUD's own database — WeChat never shows it — so
    /// typing it into WeChat search can land on a same-named stranger, and the
    /// title check would then confirm that stranger as the intended chat. This
    /// path keeps the array to names WeChat itself resolves (live remark →
    /// nickname → username).
    func weChatSendSearchNames(for chatUsername: String) -> [String] {
        _ = try? reader.refreshContactsIfChanged()
        return reader.weChatSearchNames(for: chatUsername)
    }

    /// Gap between the historical-data repairs below. Same reasoning as
    /// `staleArchiveSweepInterval`: they are whole-table scans over data that
    /// is minutes-to-days old, and once a row is repaired it never becomes
    /// stale again — so running them per scan buys nothing and costs a write
    /// transaction plus a `LIKE '%…@chatroom'` sweep over 15 tables each time.
    static let chatRepairInterval: TimeInterval = 3600

    private func shouldRepairChatData(now: Date) -> Bool {
        guard let last = lastChatRepairAt else { return true }
        return now.timeIntervalSince(last) >= ChatMonitor.chatRepairInterval
    }

    /// Run the persisted-name refresh and the three historical repairs, at most
    /// once per `chatRepairInterval` — or immediately when the contact database
    /// actually changed, which is the only event that can rename a peer.
    ///
    /// All four used to run on every scan apply. With FSEvents at 0.0s latency
    /// plus the 10s heartbeat that is 6-10 times a minute while WeChat is
    /// active, on the main actor, and the work grows with the tables it sweeps:
    /// the island (CADisplayLink) started dropping frames within hours of
    /// uptime and kept degrading the longer the app ran.
    @discardableResult
    func repairPersistedChatDataIfNeeded(
        contactsChanged: Bool,
        now: Date = Date()
    ) -> Int {
        guard contactsChanged || shouldRepairChatData(now: now) else { return 0 }
        if shouldRepairChatData(now: now) { lastChatRepairAt = now }
        // `refreshLiveWeChatDisplayNames` re-detects the contact file itself;
        // when we were woken by a change the caller already refreshed it.
        let refreshedNames = contactsChanged
            ? refreshLiveWeChatDisplayNamesSkippingDetection()
            : refreshLiveWeChatDisplayNames()
        if refreshedNames > 0 {
            print("[WCHUD] refreshed \(refreshedNames) WeChat display names")
        }
        // Rows written before the naming fallback existed still carry raw
        // `…@chatroom` ids. Repair before reloading so the published lists
        // already show readable names.
        let repairedNames = repairStaleChatNames()
        if repairedNames > 0 {
            print("[WCHUD] repaired \(repairedNames) persisted chat name rows")
        }
        let repairedTargets = repairStaleCommitTargets()
        if repairedTargets > 0 {
            print("[WCHUD] repaired \(repairedTargets) commitment target rows")
        }
        let repairedInquiries = repairInvertedInquiryRecords()
        if repairedInquiries.commitments + repairedInquiries.discussions > 0 {
            print("[WCHUD] repaired inverted inquiries: commitments=\(repairedInquiries.commitments) discussions=\(repairedInquiries.discussions)")
        }
        return refreshedNames + repairedNames + repairedTargets
            + repairedInquiries.commitments + repairedInquiries.discussions
    }

    /// Keep whitelist/contact labels on the current WeChat remark so the
    /// UI and search do not stay on a renamed 备注.
    @discardableResult
    func refreshLiveWeChatDisplayNames() -> Int {
        _ = try? reader.refreshContactsIfChanged()
        return refreshLiveWeChatDisplayNamesSkippingDetection()
    }

    /// The same pass without re-asking the reader whether contact.db moved —
    /// for callers that just asked.
    @discardableResult
    private func refreshLiveWeChatDisplayNamesSkippingDetection() -> Int {
        displayNameCache.removeAll()
        var changed = 0
        for entry in store.getWhitelist() {
            if let alias = store.chatAlias(for: entry.id), !alias.isEmpty { continue }
            let live = reader.displayName(for: entry.id)
            guard !live.isEmpty,
                  live != entry.displayName,
                  !ContactIdentityIndex.isRawChatIdentifier(live) else { continue }
            _ = store.propagateChatName(username: entry.id, displayName: live, previousName: entry.displayName)
            changed += 1
        }
        return changed
    }

    func openWeChatChat(_ chatUsername: String) {
        WeChatLauncher.openChat(
            named: displayName(for: chatUsername),
            searchNames: weChatSearchNames(for: chatUsername)
        )
    }

    func openWeChatChatAndPaste(_ chatUsername: String, text: String) {
        // Drafts use the send-safe names: a pasted draft in a same-named
        // stranger's chat is one Enter away from a missend.
        WeChatLauncher.openChatAndPaste(
            named: displayName(for: chatUsername),
            text: text,
            searchNames: weChatSendSearchNames(for: chatUsername)
        )
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
        // setChatAlias now writes the alias AND propagates in one
        // transaction — a second propagate here only rewrote the same rows.
        let changed = try store.setChatAlias(
            username: chatUsername, displayName: trimmed, previousName: previousName
        )
        refreshNamesAfterRename()
        return changed
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
        Self.repairStaleChatNames(store: store, resolve: { [weak self] username in
            self?.displayName(for: username)
        })
    }

    /// The row-level repair, separated from the resolver.
    ///
    /// This used to exist only as a copy inside the test file ("mirrors
    /// ChatMonitor's repair loop"), which meant the loop the app actually runs
    /// — including its "only write a name that improves the row" rule — was
    /// never exercised. The monitor passes its own resolver; tests pass a stub.
    @discardableResult
    static func repairStaleChatNames(store: HUDStore, resolve: (String) -> String?) -> Int {
        let rows = store.uninformativeChatNameRows()
        guard !rows.isEmpty else { return 0 }

        // Resolve each chat once — the same chat appears in many tables.
        var resolvedByChat: [String: String] = [:]
        var unresolvable: Set<String> = []
        var updates: [(table: String, keyColumn: String, nameColumn: String, key: String, oldName: String, newName: String)] = []
        for row in rows {
            let resolved: String?
            if unresolvable.contains(row.key) {
                resolved = nil
            } else if let cached = resolvedByChat[row.key] {
                resolved = cached
            } else {
                resolved = resolve(row.key)
                if let resolved {
                    resolvedByChat[row.key] = resolved
                } else {
                    unresolvable.insert(row.key)
                }
            }
            // Nothing better than what is stored — leave the row alone rather
            // than churn the database on every scan.
            guard let resolved,
                  resolved != row.name,
                  !ContactIdentityIndex.isRawChatIdentifier(resolved) else { continue }
            updates.append((row.table, row.keyColumn, row.nameColumn, row.key, row.name, resolved))
        }
        return store.applyResolvedChatNames(updates)
    }

    /// Rewrite `commit_to` values that are raw chat ids.
    @discardableResult
    func repairStaleCommitTargets() -> Int {
        Self.repairStaleCommitTargets(store: store, resolve: { [weak self] target in
            self?.canonicalDisplayName(for: target)
        })
    }

    /// Rewrite `commit_to` values that are raw chat ids. Same split as
    /// `repairStaleChatNames` so the loop itself is testable.
    @discardableResult
    static func repairStaleCommitTargets(store: HUDStore, resolve: (String) -> String?) -> Int {
        let rows = store.uninformativeCommitTargets()
        guard !rows.isEmpty else { return 0 }
        var updates: [(msgUID: String, oldTarget: String, newTarget: String)] = []
        for row in rows {
            guard let resolved = resolve(row.target) else { continue }
            updates.append((row.msgUID, row.target, resolved))
        }
        return store.applyResolvedCommitTargets(updates)
    }

    /// Drop persisted commitments/todos that inverted a user question into a promise.
    @discardableResult
    func repairInvertedInquiryRecords() -> (commitments: Int, discussions: Int) {
        Self.repairInvertedInquiryRecords(store: store)
    }

    @discardableResult
    static func repairInvertedInquiryRecords(store: HUDStore) -> (commitments: Int, discussions: Int) {
        var cancelled = 0
        for commitment in store.loadCommitments() where commitment.status == .pending || commitment.status == .overdue {
            guard MessageFeatureExtractor.isInvertedInquiryRecord(
                sourceText: commitment.sourceText,
                summary: commitment.content
            ) else { continue }
            let changes = (try? store.updateCommitmentStatus(msgUID: commitment.msgUID, status: .cancelled)) ?? 0
            if changes > 0 { cancelled += 1 }
        }
        var reclassified = 0
        for item in store.loadDiscussionItems(status: .pending) {
            guard let repaired = MessageFeatureExtractor.repairedInquiryDiscussion(
                kind: item.kind, owner: item.owner, content: item.content
            ) else { continue }
            guard repaired.kind != item.kind || repaired.owner != item.owner || repaired.content != item.content else { continue }
            if (try? store.repairDiscussionItemDirection(
                id: item.id, kind: repaired.kind, owner: repaired.owner, content: repaired.content
            )) == true {
                reclassified += 1
            }
        }
        return (cancelled, reclassified)
    }
}
