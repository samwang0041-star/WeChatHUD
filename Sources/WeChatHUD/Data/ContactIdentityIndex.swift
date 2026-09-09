import Foundation

struct ContactIdentityIndex {
    struct Record: Equatable {
        let username: String
        let nickName: String
        let remark: String
    }

    static let empty = ContactIdentityIndex(
        displayNameByUsername: [:], weChatNameByUsername: [:], canonicalUsernameByAlias: [:]
    )

    let displayNameByUsername: [String: String]
    /// The name WeChat itself reports (remark → nickname); empty when WeChat
    /// has none. Separate from `displayNameByUsername`, which may hold a
    /// placeholder or a member-derived label instead.
    let weChatNameByUsername: [String: String]
    private let canonicalUsernameByAlias: [String: String]

    /// Placeholder used when a group has no name anywhere in WeChat's
    /// databases (357 of this account's 1180 groups). Never leak the raw
    /// `…@chatroom` id into the UI: it is meaningless to the user.
    static let unnamedGroupPlaceholder = "未命名群聊"

    /// Builds the user-facing label for a group member list, e.g.
    /// `群聊 · 赖豪、张沛、索洛诺勋`. Group names come from WeChat, so a
    /// nameless group is only identifiable by who is in it.
    static func memberDerivedGroupLabel(memberNames: [String], maxMembers: Int = 3) -> String? {
        let cleaned: [String] = memberNames.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // A wxid/alias is not a human-readable name — it is the very
            // thing we are trying to avoid showing.
            guard !trimmed.contains("@chatroom") else { return nil }
            guard !trimmed.hasPrefix("wxid_") else { return nil }
            return trimmed
        }
        var seen = Set<String>()
        let unique = cleaned.filter { seen.insert(normalizeAlias($0)).inserted }
        guard !unique.isEmpty else { return nil }
        let shown = unique.prefix(maxMembers).joined(separator: "、")
        let suffix = unique.count > maxMembers ? " 等" : ""
        return "群聊 · \(shown)\(suffix)"
    }

    static func build(records: [Record]) -> ContactIdentityIndex {
        var displayNames: [String: String] = [:]
        var weChatNames: [String: String] = [:]
        var aliasBuckets: [String: Set<String>] = [:]

        func addAlias(_ alias: String, username: String) {
            let key = normalizeAlias(alias)
            guard !key.isEmpty else { return }
            aliasBuckets[key, default: []].insert(username)
        }

        for record in records {
            let username = record.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { continue }

            let fallback = username.contains("@chatroom") ? Self.unnamedGroupPlaceholder : username
            let display = record.remark.trimmedNonEmpty
                ?? record.nickName.trimmedNonEmpty
                ?? fallback
            displayNames[username] = display
            weChatNames[username] = record.remark.trimmedNonEmpty ?? record.nickName.trimmedNonEmpty ?? ""

            addAlias(username, username: username)
            if let shortId = WeChatReader.legacyShortUsername(for: username) {
                addAlias(shortId, username: username)
            }
            addAlias(record.nickName, username: username)
            addAlias(record.remark, username: username)
            addAlias(display, username: username)
        }

        var canonical: [String: String] = [:]
        for (alias, usernames) in aliasBuckets where usernames.count == 1 {
            canonical[alias] = usernames.first
        }

        return ContactIdentityIndex(
            displayNameByUsername: displayNames,
            weChatNameByUsername: weChatNames,
            canonicalUsernameByAlias: canonical
        )
    }

    func canonicalUsername(for raw: String) -> String? {
        let key = Self.normalizeAlias(raw)
        guard !key.isEmpty else { return nil }
        return canonicalUsernameByAlias[key]
    }

    func displayName(for raw: String) -> String? {
        if let exact = displayNameByUsername[raw] {
            return exact
        }
        if let canonical = canonicalUsername(for: raw) {
            return displayNameByUsername[canonical]
        }
        return nil
    }

    func normalizeMentions(in text: String) -> String {
        guard text.contains("@") else { return text }

        let pattern = #"@([^\s:：,，。；;、]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let aliasRange = match.range(at: 1)
            guard aliasRange.location != NSNotFound else { continue }
            let alias = nsText.substring(with: aliasRange)
            guard let display = displayName(for: alias), display != alias else { continue }
            if let range = Range(aliasRange, in: result) {
                result.replaceSubrange(range, with: display)
            }
        }
        return result
    }

    static func normalizeAlias(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .lowercased()
    }

    /// True when a stored display name is really a WeChat identifier
    /// (`43753159251@chatroom`, `wxid_abc`, `…@openim`) rather than a name a
    /// person could read.
    static func isRawChatIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("@chatroom") || trimmed.contains("@openim") || trimmed.contains("@im.chatroom") {
            return true
        }
        return trimmed.hasPrefix("wxid_")
    }

    /// True when a stored name carries no information about which chat it is:
    /// either a raw identifier or the bare placeholder. Such a row is worth
    /// re-resolving once a member-derived name becomes available.
    static func isUninformativeChatName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == unnamedGroupPlaceholder || isRawChatIdentifier(trimmed)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
