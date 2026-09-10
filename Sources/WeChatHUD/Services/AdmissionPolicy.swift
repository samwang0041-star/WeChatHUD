import Foundation

/// Decides which messages are allowed to reach the user.
///
/// Before this existed the answer lived in two places that did not agree:
/// the inbox listed every conversation with unread messages, while the
/// notification and AI queues only ever saw followed conversations. The user
/// could not tell why a message appeared, or why one did not.
///
/// One pure function now answers it, so the rule is inspectable, testable, and
/// identical across the inbox, the banners, and the analysis queues.
enum AdmissionPolicy {

    /// Why a message was let through. Surfaced in the UI so every row can
    /// explain itself instead of the user guessing.
    enum Admission: Equatable {
        /// The sender, or the conversation, is marked VIP.
        case vip
        /// The message mentions the user by name.
        case atMention
        /// The sender is one of the members the user follows inside this group.
        case watchedMember
        /// The conversation is on the follow list.
        case followed
        /// Nothing singled this out; the wide mode let it through.
        case everyChat
    }

    enum Suppression: Equatable {
        /// The user muted this person, here or everywhere.
        case mutedPerson
        /// Nothing selected this message and the net is narrow.
        case notFollowed
    }

    enum Decision: Equatable {
        case admit(Admission)
        case suppress(Suppression)

        var isAdmitted: Bool {
            if case .admit = self { return true }
            return false
        }
    }

    struct Context: Equatable {
        var mode: AdmissionMode
        var isGroup: Bool
        var chatIsFollowed: Bool
        var chatIsVIP: Bool
        var senderIsVIP: Bool
        var senderIsWatchedMember: Bool
        var senderIsMuted: Bool
        var isAtMention: Bool
    }

    /// Order matters and is the product decision:
    ///
    /// 1. A muted person is muted. This outranks VIP on purpose — muting is the
    ///    more recent, more specific instruction, and a user who muted someone
    ///    should not keep seeing them because of an older VIP flag.
    /// 2. An @ by name.
    /// 3. VIP people and VIP conversations.
    /// 4. Members followed inside this group.
    /// 5. A followed private conversation.
    /// 6. Everything, but only in the wide mode.
    ///
    /// Following a *group* deliberately does not admit the whole room. A room is
    /// followed because of the people in it; treating the follow itself as a
    /// reason would pour every busy group into the inbox and bury the messages
    /// the feature exists to surface.
    static func decide(_ context: Context) -> Decision {
        if context.senderIsMuted { return .suppress(.mutedPerson) }
        if context.isAtMention { return .admit(.atMention) }
        if context.senderIsVIP || context.chatIsVIP { return .admit(.vip) }
        if context.senderIsWatchedMember { return .admit(.watchedMember) }
        if context.chatIsFollowed && !context.isGroup { return .admit(.followed) }
        if context.mode == .all { return .admit(.everyChat) }
        return .suppress(.notFollowed)
    }

    /// Whether an admitted message should also interrupt with a banner.
    ///
    /// A group the user muted for @s still reaches the inbox — dropping it
    /// entirely would hide the one message they were probably waiting for. It
    /// just does not pop up.
    static func shouldRaiseBanner(
        decision: Decision,
        chatUsername: String,
        isAtMention: Bool,
        atMutedGroups: Set<String>
    ) -> Bool {
        guard decision.isAdmitted else { return false }
        if isAtMention, atMutedGroups.contains(chatUsername) { return false }
        return true
    }
}

/// Snapshot of every admission input, loaded once per scan.
///
/// Loading it once matters: the scan evaluates this for every message, and
/// re-reading the rules per message would put a query on the hot path.
struct AdmissionRules {
    let config: AdmissionConfig
    let followedChats: Set<String>
    let vipChats: Set<String>
    /// VIP people, tracked across every followed group — not just their own
    /// conversation.
    let vipPeople: Set<String>
    /// group username → members whose messages should surface.
    let watchedMembers: [String: Set<String>]
    let perChatMuted: [String: Set<String>]
    let globalMuted: Set<String>

    static func load(store: HUDStore) -> AdmissionRules {
        let whitelist = store.getWhitelist()
        return AdmissionRules(
            config: store.loadAdmissionConfig(),
            followedChats: Set(whitelist.map(\.id)),
            vipChats: Set(whitelist.filter { $0.attentionLevel == .vip }.map(\.id)),
            vipPeople: Set(
                whitelist
                    .filter { $0.attentionLevel == .vip && !$0.isGroup }
                    .map(\.id)
            ),
            watchedMembers: store.loadGroupMemberMap(),
            perChatMuted: store.loadIgnoredSenderMap(),
            globalMuted: store.loadGlobalIgnoredSenders()
        )
    }

    func isAtMuted(chatUsername: String) -> Bool {
        config.atMutedGroups.contains(chatUsername)
    }

    /// Muted in every conversation, or muted in this one.
    ///
    /// Matching happens on the canonical `username:`/`name:` identifier, with
    /// the raw username as a fallback so a rule created before the identifier
    /// scheme existed still lands.
    func isMuted(chatUsername: String, senderUsername: String, senderName: String) -> Bool {
        let identifier = HUDStore.senderIdentifier(
            senderUsername: senderUsername,
            senderName: senderName
        )
        if globalMuted.contains(identifier) { return true }
        if !senderUsername.isEmpty, globalMuted.contains("username:\(senderUsername.lowercased())") {
            return true
        }
        if perChatMuted[chatUsername]?.contains(identifier) == true { return true }
        if !senderUsername.isEmpty,
           perChatMuted[chatUsername]?.contains("username:\(senderUsername.lowercased())") == true {
            return true
        }
        return false
    }

    func context(
        chatUsername: String,
        isGroup: Bool,
        senderUsername: String,
        senderName: String,
        isAtMention: Bool
    ) -> AdmissionPolicy.Context {
        AdmissionPolicy.Context(
            mode: config.mode,
            isGroup: isGroup,
            chatIsFollowed: followedChats.contains(chatUsername),
            chatIsVIP: vipChats.contains(chatUsername),
            senderIsVIP: vipPeople.contains(senderUsername),
            senderIsWatchedMember: watchedMembers[chatUsername]?.contains(senderUsername) == true,
            senderIsMuted: isMuted(
                chatUsername: chatUsername,
                senderUsername: senderUsername,
                senderName: senderName
            ),
            isAtMention: isAtMention
        )
    }

    func decide(
        chatUsername: String,
        isGroup: Bool,
        senderUsername: String,
        senderName: String,
        isAtMention: Bool
    ) -> AdmissionPolicy.Decision {
        AdmissionPolicy.decide(context(
            chatUsername: chatUsername,
            isGroup: isGroup,
            senderUsername: senderUsername,
            senderName: senderName,
            isAtMention: isAtMention
        ))
    }

    /// Decide a whole conversation from its recent messages.
    ///
    /// The newest line in a busy group is rarely the @ that pulled the user in,
    /// so this looks for the newest message that is itself a reason to surface
    /// the conversation, and lets that one decide. Returns the reason, not just
    /// a boolean, so the UI can say why the row is there.
    func decision(
        chatUsername: String,
        isGroup: Bool,
        messages: [MessageInfo],
        isFromSelf: (MessageInfo) -> Bool,
        isAtMe: (MessageInfo) -> Bool
    ) -> AdmissionPolicy.Decision {
        let decisions = messages
            .filter { !isFromSelf($0) }
            .map { message in
                decide(
                    chatUsername: chatUsername,
                    isGroup: isGroup,
                    senderUsername: message.senderUsername,
                    senderName: message.senderName,
                    isAtMention: isAtMe(message)
                )
            }

        if let admitted = decisions.first(where: { $0.isAdmitted }) { return admitted }

        // Nothing got through. Report the most specific reason available: if the
        // only people who spoke are muted, the honest answer is "you muted
        // them", not a vague "nobody selected this".
        if decisions.contains(where: {
            if case .suppress(.mutedPerson) = $0 { return true }
            return false
        }) {
            return .suppress(.mutedPerson)
        }
        return .suppress(.notFollowed)
    }
}
