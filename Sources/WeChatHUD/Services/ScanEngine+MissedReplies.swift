import Foundation

extension ScanEngine {
    /// Walk followed chats plus recent group sessions and collect inbounds in
    /// `rangeStart...rangeEnd` that still have no substantive reply by `now`.
    ///
    /// The walk is capped, so it reports what it could not cover alongside the
    /// results; the page may not present a short scan as a clean bill of health.
    /// Whitelist entries are queued ahead of group sessions, so the ones that
    /// fall off the end are the un-followed groups.
    static func buildMissedReplyItems(
        reader: WeChatReader,
        admissionRules: AdmissionRules,
        whitelist: [WhitelistEntry],
        myUsername: String,
        myDisplayName: String,
        mySelfNames: Set<String>,
        rangeStart: Date,
        rangeEnd: Date,
        now: Date = Date(),
        maxChats: Int = 120,
        perChatLimit: Int = 400
    ) -> (items: [MissedReplyFinder.Item], coverage: MissedReplyFinder.Coverage) {
        let sessions: [SessionInfo]
        let groupsEnumerated: Bool
        do {
            sessions = try reader.getSessions()
            groupsEnumerated = true
        } catch {
            sessions = []
            groupsEnumerated = false
        }
        var sessionMap: [String: SessionInfo] = [:]
        for session in sessions {
            sessionMap[session.username] = session
        }

        var targets: [SessionInfo] = []
        var seen = Set<String>()
        func append(_ session: SessionInfo) {
            guard seen.insert(session.username).inserted else { return }
            targets.append(session)
        }

        for entry in whitelist {
            if let existing = sessionMap[entry.id] {
                append(existing)
            } else {
                append(SessionInfo(
                    username: entry.id,
                    isGroup: entry.isGroup,
                    unreadCount: 0,
                    lastTimestamp: 0
                ))
            }
        }
        for session in sessions where session.isGroup {
            append(session)
        }
        let unexaminedChats = max(0, targets.count - maxChats)
        if targets.count > maxChats {
            targets = Array(targets.prefix(maxChats))
        }

        let startTs = Int(rangeStart.timeIntervalSince1970)
        let endTs = Int(now.timeIntervalSince1970) + 1
        // Per chat, not one batch: a single SQL failure must not blank the
        // whole "没回的" page. But an empty result and a failed read are
        // different facts, and the page may not present the difference as
        // "nothing left unanswered" — hence the count.
        var unreadableChats = 0
        var batch: [String: [MessageInfo]] = [:]
        batch.reserveCapacity(targets.count)
        for target in targets {
            do {
                batch[target.username] = try reader.getMessages(
                    chatUsername: target.username,
                    limit: perChatLimit,
                    sinceLocalId: nil,
                    afterCursor: nil,
                    oldestFirst: false,
                    startTime: startTs,
                    endTime: endTs
                )
            } catch {
                unreadableChats += 1
                batch[target.username] = []
            }
        }

        let vipSet = Set(whitelist.filter { $0.attentionLevel == .vip }.map { $0.id })
        let nameByID = Dictionary(uniqueKeysWithValues: whitelist.map { ($0.id, $0.displayName) })

        let seeds: [MissedReplyFinder.Seed] = targets.compactMap { session -> MissedReplyFinder.Seed? in
            let messages = batch[session.username] ?? []
            guard !messages.isEmpty else { return nil }

            func fromSelf(_ msg: MessageInfo) -> Bool {
                MessageHelpers.isFromSelf(
                    msg,
                    chatUsername: session.username,
                    myUsername: myUsername,
                    myDisplayName: myDisplayName,
                    mySelfNames: mySelfNames
                )
            }
            func atMe(_ msg: MessageInfo) -> Bool {
                MessageHelpers.isAtMe(
                    msg.text,
                    myUsername: myUsername,
                    myDisplayName: myDisplayName,
                    mySelfNames: mySelfNames
                )
            }

            let timeline = messages.compactMap { msg -> ReplyDebtScorer.TimelineEntry? in
                if admissionRules.isMuted(
                    chatUsername: session.username,
                    senderUsername: msg.senderUsername,
                    senderName: msg.senderName
                ) { return nil }
                return ReplyDebtScorer.TimelineEntry(
                    message: msg,
                    isFromSelf: fromSelf(msg),
                    isAtMe: atMe(msg)
                )
            }
            guard !timeline.isEmpty else { return nil }

            let admission = admissionRules.decision(
                chatUsername: session.username,
                isGroup: session.isGroup,
                messages: messages,
                isFromSelf: fromSelf,
                isAtMe: atMe
            )

            let chatName = messages.first?.chatName
                ?? nameByID[session.username]
                ?? session.username

            return MissedReplyFinder.Seed(
                session: session,
                chatName: chatName,
                isVIP: vipSet.contains(session.username),
                admission: admission,
                timeline: timeline,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd
            )
        }

        return (
            items: MissedReplyFinder.build(seeds: seeds),
            coverage: MissedReplyFinder.Coverage(
                examinedChats: targets.count,
                unreadableChats: unreadableChats,
                unexaminedChats: unexaminedChats,
                groupSessionsUnavailable: !groupsEnumerated
            )
        )
    }
}
