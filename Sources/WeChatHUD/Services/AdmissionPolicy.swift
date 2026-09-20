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
    ///
    /// `rulesUnreadable` fails the *outward* half closed: the mute lists arrive
    /// empty when the tables cannot be read, so 「这个人不要提醒我」 is silently
    /// un-honored for the duration. A row in the inbox is recoverable; an
    /// interruption the user switched off is not, and it is the one thing here
    /// that cannot be taken back.
    static func shouldRaiseBanner(
        decision: Decision,
        chatUsername: String,
        isAtMention: Bool,
        atMutedGroups: Set<String>,
        rulesUnreadable: Bool
    ) -> Bool {
        guard decision.isAdmitted else { return false }
        if rulesUnreadable { return false }
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
    /// The bulk follow-list read failed, so `followedChats` is empty for a
    /// reason that has nothing to do with the user. `decide` cannot express
    /// 「我这次没读到」, and its 「没关注」 answer is destructive downstream: the
    /// classification worker deletes the queue row it was given. Callers that
    /// delete on a negative verdict have to check this first. Defaults to
    /// `false` so a hand-built snapshot in a test stays honest about the case it
    /// means to cover.
    var followingUnreadable: Bool = false
    /// The mute / group-watch rule tables could not be read, so `perChatMuted`,
    /// `globalMuted` and `watchedMembers` are empty for a reason that has nothing to
    /// do with the user. Destructive in *both* directions: an empty mute set admits
    /// senders the user muted, and an empty watch list un-admits chats whose messages
    /// this scan then marks as already seen.
    var rulesUnreadable: Bool = false

    /// The one question every consumer that deletes work or moves a watermark has to
    /// ask before acting on a negative verdict.
    var scopeUnreadable: Bool { followingUnreadable || rulesUnreadable }

    static func load(store: HUDStore) -> AdmissionRules {
        let whitelist: [WhitelistEntry]
        let unreadable: Bool
        switch store.whitelistAllRead() {
        case .value(let entries):
            whitelist = entries
            unreadable = false
        case .unreadable:
            whitelist = []
            unreadable = true
        }
        // `.corrupt` deliberately not folded in: a half-written row is permanent,
        // and holding the watermark forever for it trades a data-loss bug for a
        // frozen app. It needs a visible 「设置读不懂，请重存」 affordance instead.
        let configUnreadable: Bool
        switch store.admissionConfigRead() {
        case .unreadable: configUnreadable = true
        default: configUnreadable = false
        }
        let memberRules = store.groupMemberRulesRead()
        let ignoredRules = store.ignoredSendersRead()
        let perChatMuted: [String: Set<String>]
        let globalMutedSet: Set<String>
        if let ignoredRules {
            perChatMuted = ignoredRules.reduce(into: [String: Set<String>]()) { acc, rule in
                if rule.scope == .chat {
                    acc[rule.chatUsername, default: []].insert(rule.senderIdentifier)
                }
            }
            globalMutedSet = Set(ignoredRules.filter { $0.scope == .global }.map(\.senderIdentifier))
        } else {
            perChatMuted = [:]
            globalMutedSet = []
        }
        let watched: [String: Set<String>] = memberRules?.reduce(
            into: [String: Set<String>]()) { acc, rule in
            acc[rule.chatUsername, default: []].insert(rule.senderUsername)
        } ?? [:]
        return AdmissionRules(
            config: store.loadAdmissionConfig(),
            followedChats: Set(whitelist.map(\.id)),
            vipChats: Set(whitelist.filter { $0.attentionLevel == .vip }.map(\.id)),
            vipPeople: Set(
                whitelist
                    .filter { $0.attentionLevel == .vip && !$0.isGroup }
                    .map(\.id)
            ),
            watchedMembers: watched,
            perChatMuted: perChatMuted,
            globalMuted: globalMutedSet,
            followingUnreadable: unreadable,
            rulesUnreadable: memberRules == nil || ignoredRules == nil || configUnreadable
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
