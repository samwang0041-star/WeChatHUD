import CryptoKit
import Foundation

/// 关系雷达: cross-day / cross-week attitude, tone, silence, and relationship
/// trend. Input is accumulated 单聊分析 facts (topics / decisions / waiting /
/// mood / volume) — never the forbidden single-day inference fields.
enum RelationshipRadarService {
    static let defaultWindowDays = 30

    static func dayString(from date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    static func point(
        from result: ChatInsightResult,
        chatUsername: String,
        day: String,
        messageCount: Int,
        myMessageCount: Int
    ) -> DailyInsightPoint {
        DailyInsightPoint(
            chatUsername: chatUsername,
            day: day,
            headline: Redactor.applyMasks(result.headline),
            topics: result.topics.map { Redactor.applyMasks($0.name) },
            decisions: result.decisions.map(Redactor.applyMasks),
            waitingCount: result.waitingForMe.count,
            overallMood: Redactor.applyMasks(result.overallMood),
            messageCount: messageCount,
            myMessageCount: myMessageCount,
            insight: Redactor.applyMasks(result.insight)
        )
    }

    static func buildSnapshot(
        chatUsername: String,
        points: [DailyInsightPoint],
        now: Date = Date(),
        windowDays: Int = defaultWindowDays,
        calendar: Calendar = .current
    ) -> RelationshipRadarSnapshot {
        let sorted = points.sorted { $0.day < $1.day }
        let hashes = sorted.map { point in
            AIAuditPrivacy.sha256Hex("\(point.day)|\(point.headline)|\(point.topics.joined(separator: ","))")
        }

        let lastDay = sorted.last?.day
        let silenceDays: Int
        if let lastDay, let lastDate = parseDay(lastDay, calendar: calendar) {
            let today = calendar.startOfDay(for: now)
            let last = calendar.startOfDay(for: lastDate)
            silenceDays = max(0, calendar.dateComponents([.day], from: last, to: today).day ?? 0)
        } else {
            silenceDays = windowDays
        }

        let moods = sorted.map(\.overallMood).filter { !$0.isEmpty }
        var toneChanges: [RadarToneChange] = []
        if moods.count >= 2 {
            for index in 1..<moods.count where moods[index] != moods[index - 1] {
                toneChanges.append(RadarToneChange(
                    from: moods[index - 1],
                    to: moods[index],
                    aroundDay: sorted[min(index, sorted.count - 1)].day
                ))
            }
        }
        let moodShift: String?
        if let first = moods.first, let last = moods.last, first != last {
            moodShift = "\(first) → \(last)"
        } else {
            moodShift = nil
        }

        let mid = max(sorted.count / 2, 1)
        let early = Array(sorted.prefix(mid))
        let lateSlice = sorted.count == 1 ? sorted : Array(sorted.suffix(max(sorted.count - mid, 1)))

        let earlyWait = average(early.map { Double($0.waitingCount) })
        let lateWait = average(lateSlice.map { Double($0.waitingCount) })
        let earlyMine = average(early.map(\.replyShare))
        let lateMine = average(lateSlice.map(\.replyShare))

        let attitudeTrend: String
        let relationshipTrend: String
        if sorted.count < 2 {
            attitudeTrend = RelationshipRadarKind.attitudeUnknown
            relationshipTrend = RelationshipRadarKind.trendStable
        } else if lateWait > earlyWait + 0.6 && lateMine + 0.08 < earlyMine {
            attitudeTrend = RelationshipRadarKind.attitudeCooling
            relationshipTrend = RelationshipRadarKind.trendDeteriorating
        } else if lateWait + 0.6 < earlyWait && lateMine > earlyMine + 0.08 {
            attitudeTrend = RelationshipRadarKind.attitudeWarming
            relationshipTrend = RelationshipRadarKind.trendImproving
        } else if abs(lateWait - earlyWait) > 0.8 || abs(lateMine - earlyMine) > 0.12 {
            attitudeTrend = RelationshipRadarKind.attitudeMixed
            relationshipTrend = RelationshipRadarKind.trendStable
        } else {
            attitudeTrend = RelationshipRadarKind.attitudeStable
            relationshipTrend = RelationshipRadarKind.trendStable
        }

        var darkSignals: [String] = []
        if silenceDays >= 7 {
            darkSignals.append("连续 \(silenceDays) 天没有可分析的往来")
        }
        if let last = sorted.last, last.waitingCount >= 2 {
            darkSignals.append("最近一天仍有 \(last.waitingCount) 件等你处理")
        }
        if let last = sorted.last, last.messageCount >= 8, last.replyShare < 0.2 {
            darkSignals.append("最近沟通明显单向")
        }

        let summary = Redactor.applyMasks(buildSummary(
            attitudeTrend: attitudeTrend,
            relationshipTrend: relationshipTrend,
            silenceDays: silenceDays,
            toneChanges: toneChanges,
            topics: sorted.suffix(3).flatMap(\.topics)
        ))

        return RelationshipRadarSnapshot(
            chatUsername: chatUsername,
            generatedAt: now,
            windowDays: windowDays,
            attitudeTrend: attitudeTrend,
            toneChanges: toneChanges,
            moodShift: moodShift.map(Redactor.applyMasks),
            silenceDays: silenceDays,
            relationshipTrend: relationshipTrend,
            darkSignals: darkSignals.map(Redactor.applyMasks),
            summary: summary,
            evidenceHashes: hashes
        )
    }

    static func refresh(
        store: HUDStore,
        chatUsername: String,
        now: Date = Date(),
        windowDays: Int = defaultWindowDays
    ) throws -> RelationshipRadarSnapshot {
        let since = dayString(from: Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? now)
        let points = store.loadDailyInsightPoints(
            chatUsername: chatUsername,
            sinceDay: since,
            limit: windowDays + 5
        )
        let snapshot = buildSnapshot(
            chatUsername: chatUsername,
            points: points,
            now: now,
            windowDays: windowDays
        )
        try store.saveRelationshipRadarSnapshot(snapshot)
        return snapshot
    }

    static func briefingSummaries(from snapshots: [RelationshipRadarSnapshot], limit: Int = 8) -> [String] {
        snapshots.prefix(limit).map(\.briefingLine)
    }

    static let lastRefreshSettingKey = "relationshipRadar.lastRefreshAt"
    static let defaultRefreshInterval: TimeInterval = 15 * 60

    /// Recompute snapshots for every chat that already has daily facts.
    /// No AI, no outbound send. `minInterval` skips a scan-tick hop that
    /// landed too soon after the last refresh; pass `force: true` from the
    /// dedicated pane's refresh button.
    @discardableResult
    static func refreshAll(
        store: HUDStore,
        now: Date = Date(),
        windowDays: Int = defaultWindowDays,
        minInterval: TimeInterval = defaultRefreshInterval,
        force: Bool = false
    ) throws -> Int {
        if !force,
           let raw = store.getSetting(lastRefreshSettingKey),
           let last = TimeInterval(raw),
           now.timeIntervalSince1970 - last < minInterval {
            return 0
        }
        let usernames = store.loadDailyInsightChatUsernames()
        var count = 0
        for username in usernames {
            _ = try refresh(store: store, chatUsername: username, now: now, windowDays: windowDays)
            count += 1
        }
        try store.setSetting(lastRefreshSettingKey, value: String(Int(now.timeIntervalSince1970)))
        return count
    }

    static func ranked(_ snapshots: [RelationshipRadarSnapshot]) -> [RelationshipRadarSnapshot] {
        snapshots.sorted { lhs, rhs in
            let left = attentionRank(lhs)
            let right = attentionRank(rhs)
            if left != right { return left < right }
            if lhs.silenceDays != rhs.silenceDays { return lhs.silenceDays > rhs.silenceDays }
            return lhs.generatedAt > rhs.generatedAt
        }
    }

    static func attentionRank(_ snapshot: RelationshipRadarSnapshot) -> Int {
        if snapshot.relationshipTrend == RelationshipRadarKind.trendDeteriorating
            || snapshot.attitudeTrend == RelationshipRadarKind.attitudeCooling {
            return 0
        }
        if snapshot.silenceDays >= 7 { return 1 }
        if snapshot.attitudeTrend == RelationshipRadarKind.attitudeMixed { return 2 }
        if snapshot.relationshipTrend == RelationshipRadarKind.trendImproving { return 3 }
        return 4
    }

    static func trendLabel(_ raw: String) -> String { chineseTrend(raw) }
    static func attitudeLabel(_ raw: String) -> String { chineseAttitude(raw) }

    static func displayName(for username: String, store: HUDStore) -> String {
        if let alias = store.chatAlias(for: username), !alias.isEmpty { return alias }
        if let entry = store.getWhitelistEntry(username: username), !entry.displayName.isEmpty {
            return entry.displayName
        }
        if let contact = store.getContact(username: username), !contact.displayName.isEmpty {
            return contact.displayName
        }
        return username
    }

    private static func buildSummary(
        attitudeTrend: String,
        relationshipTrend: String,
        silenceDays: Int,
        toneChanges: [RadarToneChange],
        topics: [String]
    ) -> String {
        var parts: [String] = []
        parts.append("关系\(chineseTrend(relationshipTrend))，态度\(chineseAttitude(attitudeTrend))")
        if silenceDays >= 3 {
            parts.append("已有\(silenceDays)天没有新的单聊事实")
        }
        if let lastTone = toneChanges.last {
            parts.append("语气从\(lastTone.from)转到\(lastTone.to)")
        }
        if !topics.isEmpty {
            parts.append("近期话题: \(topics.suffix(3).joined(separator: "、"))")
        }
        return parts.joined(separator: "。")
    }

    private static func chineseTrend(_ raw: String) -> String {
        switch raw {
        case RelationshipRadarKind.trendImproving: return "回暖"
        case RelationshipRadarKind.trendDeteriorating: return "转淡"
        default: return "平稳"
        }
    }

    private static func chineseAttitude(_ raw: String) -> String {
        switch raw {
        case RelationshipRadarKind.attitudeWarming: return "升温"
        case RelationshipRadarKind.attitudeCooling: return "降温"
        case RelationshipRadarKind.attitudeMixed: return "有起伏"
        case RelationshipRadarKind.attitudeUnknown: return "样本不足"
        default: return "稳定"
        }
    }

    private static func parseDay(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

private extension DailyInsightPoint {
    var replyShare: Double {
        guard messageCount > 0 else { return 0 }
        return Double(myMessageCount) / Double(messageCount)
    }
}
