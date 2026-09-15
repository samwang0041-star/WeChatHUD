import Foundation

/// Finds private messages and group @-mentions in a date range that the user
/// never substantively answered.
///
/// This is not the live inbox. "今天" only scores recent windows and lets a
/// quiet thread age out; this walk is for "did anyone look for me last week
/// and I never wrote back". A reply *after* the range still counts — the
/// inbound has to fall inside the range, the outbound may be later.
enum MissedReplyFinder {
    enum Window: String, CaseIterable, Identifiable {
        case today
        case last3Days
        case last7Days
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .today: return "今天"
            case .last3Days: return "近 3 天"
            case .last7Days: return "近 7 天"
            case .custom: return "自选"
            }
        }

        /// Inclusive calendar days, clamped so the end never goes past `now`.
        func bounds(
            now: Date = Date(),
            calendar: Calendar = .current,
            customStart: Date = Date(),
            customEnd: Date = Date()
        ) -> (start: Date, end: Date) {
            let todayStart = calendar.startOfDay(for: now)
            switch self {
            case .today:
                return (todayStart, now)
            case .last3Days:
                let start = calendar.date(byAdding: .day, value: -2, to: todayStart) ?? todayStart
                return (start, now)
            case .last7Days:
                let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
                return (start, now)
            case .custom:
                let a = calendar.startOfDay(for: min(customStart, customEnd))
                let bDay = calendar.startOfDay(for: max(customStart, customEnd))
                let next = calendar.date(byAdding: .day, value: 1, to: bDay) ?? bDay
                let end = min(now, next.addingTimeInterval(-1))
                return (a, max(a, end))
            }
        }
    }

    struct Seed {
        let session: SessionInfo
        let chatName: String
        let isVIP: Bool
        var admission: AdmissionPolicy.Decision
        /// Messages from the range start through *now*, so a later reply can
        /// clear an inbound that landed inside the range.
        let timeline: [ReplyDebtScorer.TimelineEntry]
        let rangeStart: Date
        let rangeEnd: Date
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let chatUsername: String
        let chatName: String
        let senderName: String
        let preview: String
        let timestamp: Date
        let isGroup: Bool
        let isAtMention: Bool
        let isVIP: Bool
        let unrepliedCount: Int
        let sourceMessageID: String
        let sourceText: String

        var transcriptFocus: TranscriptFocus {
            TranscriptFocus(
                chatUsername: chatUsername,
                messageID: sourceMessageID,
                senderName: senderName,
                body: sourceText,
                timestamp: timestamp
            )
        }

        var contextNotification: HUDNotification {
            HUDNotification(
                chatUsername: chatUsername,
                chatName: chatName,
                senderUsername: "",
                senderName: senderName,
                attentionLevel: isVIP ? .vip : .watch,
                messageID: sourceMessageID,
                rawText: sourceText,
                snippet: preview,
                isAtMention: isAtMention,
                timestamp: timestamp,
                kind: isGroup ? .groupAt : .privateChat
            )
        }
    }

    static func build(seeds: [Seed]) -> [Item] {
        seeds.compactMap(buildItem).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.chatUsername < $1.chatUsername
        }
    }

    private static func buildItem(seed: Seed) -> Item? {
        guard seed.admission.isAdmitted else { return nil }
        let startTs = Int(seed.rangeStart.timeIntervalSince1970)
        let endTs = Int(seed.rangeEnd.timeIntervalSince1970)
        let ordered = seed.timeline.sorted {
            if $0.message.createTime != $1.message.createTime {
                return $0.message.createTime < $1.message.createTime
            }
            return $0.message.localId < $1.message.localId
        }
        let outbounds = ordered.filter { $0.isFromSelf }

        var unreplied: [ReplyDebtScorer.TimelineEntry] = []
        for inbound in ordered where !inbound.isFromSelf {
            let ts = inbound.message.createTime
            guard ts >= startTs, ts <= endTs else { continue }
            if seed.session.isGroup, !inbound.isAtMe { continue }
            if ReplyDebtScorer.isIgnorableInbound(inbound.message.text) { continue }
            if !MessageHelpers.isReadableAIContent(inbound.message.text, allowMediaPlaceholder: false) {
                continue
            }
            let answered = outbounds.contains { outbound in
                MessageHelpers.isSameOrAfter(outbound.message, inbound.message)
                    && !ImportanceDetector.isAckOnly(outbound.message.text)
            }
            if answered { continue }
            unreplied.append(inbound)
        }
        guard let first = unreplied.first else { return nil }

        return Item(
            id: "\(seed.session.username)|\(first.message.id)",
            chatUsername: seed.session.username,
            chatName: seed.chatName.isEmpty ? seed.session.username : seed.chatName,
            senderName: first.message.senderName,
            preview: String(first.message.text.prefix(80)),
            timestamp: Date(timeIntervalSince1970: Double(first.message.createTime)),
            isGroup: seed.session.isGroup,
            isAtMention: first.isAtMe,
            isVIP: seed.isVIP,
            unrepliedCount: unreplied.count,
            sourceMessageID: first.message.id,
            sourceText: first.message.text
        )
    }
}
