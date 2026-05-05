import Foundation

struct InsightRadarFinding: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case high = 3
        case medium = 2
        case low = 1

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Kind: String {
        case waiting
        case action
        case attitude
        case mood
        case tone
        case recall
        case ignored
        case blindSpot
        case relationship
        case pressure
    }

    enum Route: Equatable {
        case openChat(String)
        case expandExplanation
        case expandPressure
        case expandRelationships
        case expandMetrics
    }

    let id: String
    let severity: Severity
    let kind: Kind
    let source: String
    let title: String
    let evidence: String?
    let reason: String?
    let actionLabel: String
    let chatUsername: String?
    let route: Route
}

enum InsightRadar {
    static func buildFindings(
        chatInsights: [String: ChatInsightResult],
        chatNames: [String: String] = [:],
        briefing: GlobalBriefing? = nil,
        overview: ChatInsightEngine.GlobalOverview? = nil,
        limit: Int = 6
    ) -> [InsightRadarFinding] {
        var findings: [InsightRadarFinding] = []

        if let briefing {
            findings.append(contentsOf: briefingFindings(briefing, chatNames: chatNames))
        }

        let sortedInsights = chatInsights.sorted {
            displayName(for: $0.key, names: chatNames) < displayName(for: $1.key, names: chatNames)
        }

        for (chatUsername, result) in sortedInsights {
            let name = displayName(for: chatUsername, names: chatNames)
            findings.append(contentsOf: chatFindings(chatUsername: chatUsername, chatName: name, result: result))
        }

        if let overview {
            findings.append(contentsOf: overviewFindings(overview, chatNames: chatNames))
        }

        return findings
            .compactMap(sanitizedFinding)
            .deduplicatedByMeaning(chatNames: chatNames)
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.priorityGroup != rhs.priorityGroup { return lhs.priorityGroup < rhs.priorityGroup }
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.source < rhs.source
            }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    private static func briefingFindings(_ briefing: GlobalBriefing, chatNames: [String: String]) -> [InsightRadarFinding] {
        var findings: [InsightRadarFinding] = []

        for (idx, item) in briefing.actionRequired.enumerated() {
            let chatUsername = username(forDisplayName: item.source, names: chatNames)
            guard chatUsername != nil || isConcreteRadarSource(item.source) else { continue }
            findings.append(InsightRadarFinding(
                id: "briefing-action-\(idx)-\(item.source)",
                severity: item.urgency == "高" ? .high : .medium,
                kind: .action,
                source: item.source,
                title: item.what,
                evidence: item.waitingHours > 0 ? "已等待 \(formatHours(item.waitingHours))" : nil,
                reason: "简报从聊天里标出了一个需要确认的事项",
                actionLabel: chatUsername == nil ? "看处理建议" : "打开对话",
                chatUsername: chatUsername,
                route: chatUsername.map(InsightRadarFinding.Route.openChat) ?? .expandExplanation
            ))
        }

        for (idx, change) in briefing.darkSignals.toneChanges.prefix(2).enumerated() {
            let title = "\(change.person) 的语气有变化"
            let chatUsername = username(forDisplayName: change.person, names: chatNames)
            guard chatUsername != nil || isConcreteRadarSource(change.person) else { continue }
            findings.append(InsightRadarFinding(
                id: "briefing-tone-\(idx)-\(change.person)",
                severity: .medium,
                kind: .tone,
                source: change.person,
                title: title,
                evidence: change.change,
                reason: change.interpretation,
                actionLabel: chatUsername == nil ? "查看依据" : "打开对话",
                chatUsername: chatUsername,
                route: chatUsername.map(InsightRadarFinding.Route.openChat) ?? .expandExplanation
            ))
        }

        return findings
    }

    private static func chatFindings(
        chatUsername: String,
        chatName: String,
        result: ChatInsightResult
    ) -> [InsightRadarFinding] {
        var findings: [InsightRadarFinding] = []

        for (idx, item) in result.waitingForMe.enumerated() {
            findings.append(InsightRadarFinding(
                id: "wait-\(chatUsername)-\(idx)-\(item.source)",
                severity: item.waitingHours >= 2 ? .high : .medium,
                kind: .waiting,
                source: chatName,
                title: item.what,
                evidence: item.waitingHours > 0 ? "\(item.source) 已等 \(formatHours(item.waitingHours))" : item.source,
                reason: "对方在等你给答复或推进",
                actionLabel: "打开对话",
                chatUsername: chatUsername,
                route: .openChat(chatUsername)
            ))
        }

        if result.needsMyAttention {
            for (idx, item) in result.actionItems.enumerated() {
                findings.append(InsightRadarFinding(
                    id: "action-\(chatUsername)-\(idx)-\(item.what)",
                    severity: .high,
                    kind: .action,
                    source: chatName,
                    title: item.what,
                    evidence: item.deadline.map { "截止: \($0)" },
                    reason: item.who == "我" ? "行动项归属到你" : "\(item.who) 相关行动项",
                    actionLabel: "去推进",
                    chatUsername: chatUsername,
                    route: .openChat(chatUsername)
                ))
            }
        }

        for (idx, signal) in (result.attitudes ?? []).enumerated() where isMeaningfulAttitude(signal.attitude) {
            findings.append(InsightRadarFinding(
                id: "attitude-\(chatUsername)-\(idx)-\(signal.person)-\(signal.topic)",
                severity: isHardNegative(signal.attitude) ? .high : .medium,
                kind: .attitude,
                source: chatName,
                title: "\(signal.person) 对「\(signal.topic)」\(signal.attitude)",
                evidence: signal.evidence,
                reason: "态度信号比消息摘要更能解释后续推进阻力",
                actionLabel: "看上下文",
                chatUsername: chatUsername,
                route: .openChat(chatUsername)
            ))
        }

        if let shift = result.moodShift, !shift.trigger.trimmed.isEmpty {
            findings.append(InsightRadarFinding(
                id: "mood-\(chatUsername)-\(shift.time)-\(shift.trigger)",
                severity: .medium,
                kind: .mood,
                source: chatName,
                title: "情绪从\(shift.from)变为\(shift.to)",
                evidence: shift.trigger,
                reason: shift.time.isEmpty ? "情绪拐点可能影响回复方式" : "\(shift.time) 出现情绪拐点",
                actionLabel: "看变化",
                chatUsername: chatUsername,
                route: .openChat(chatUsername)
            ))
        }

        for (idx, change) in (result.toneChanges ?? []).enumerated() where !change.change.trimmed.isEmpty {
            findings.append(InsightRadarFinding(
                id: "tone-\(chatUsername)-\(idx)-\(change.person)",
                severity: .medium,
                kind: .tone,
                source: chatName,
                title: "\(change.person) 的语气变化",
                evidence: change.change,
                reason: change.interpretation,
                actionLabel: "看证据",
                chatUsername: chatUsername,
                route: .openChat(chatUsername)
            ))
        }

        for (idx, note) in (result.recalledNotes ?? []).enumerated() {
            findings.append(InsightRadarFinding(
                id: "recall-\(chatUsername)-\(idx)-\(note.person)",
                severity: .medium,
                kind: .recall,
                source: chatName,
                title: "\(note.person) 撤回过消息",
                evidence: note.originalContent ?? note.context,
                reason: note.interpretation,
                actionLabel: "看上下文",
                chatUsername: chatUsername,
                route: .openChat(chatUsername)
            ))
        }

        for (idx, note) in (result.ignoredNotes ?? []).enumerated() {
            findings.append(InsightRadarFinding(
                id: "ignored-\(chatUsername)-\(idx)-\(note.person)",
                severity: .medium,
                kind: .ignored,
                source: chatName,
                title: "\(note.person) 的话题可能被忽略",
                evidence: note.content,
                reason: note.interpretation,
                actionLabel: "补一句",
                chatUsername: chatUsername,
                route: .openChat(chatUsername)
            ))
        }

        return findings
    }

    private static func overviewFindings(
        _ overview: ChatInsightEngine.GlobalOverview,
        chatNames: [String: String]
    ) -> [InsightRadarFinding] {
        var findings: [InsightRadarFinding] = []

        for (idx, item) in overview.neglectedHighValue.prefix(3).enumerated() {
            let chatUsername = username(forDisplayName: item.name, names: chatNames)
            findings.append(InsightRadarFinding(
                id: "overview-neglected-\(idx)-\(item.name)",
                severity: .medium,
                kind: .relationship,
                source: item.name,
                title: "\(item.name) 最近互动少，适合补一句",
                evidence: "根据近期互动统计 · \(item.role)",
                reason: "这是高价值联系人，关系维护不能只靠未读提醒",
                actionLabel: chatUsername == nil ? "看关系清单" : "打开对话",
                chatUsername: chatUsername,
                route: chatUsername.map(InsightRadarFinding.Route.openChat) ?? .expandRelationships
            ))
        }

        for (idx, item) in overview.oneWayChats.prefix(2).enumerated() {
            let chatUsername = username(forDisplayName: item.name, names: chatNames)
            findings.append(InsightRadarFinding(
                id: "overview-oneway-\(idx)-\(item.name)",
                severity: .medium,
                kind: .relationship,
                source: item.name,
                title: "\(item.name) 发得多，你回复少",
                evidence: "对方 \(item.theirCount) / 你 \(item.myCount)",
                reason: "关系可能正在变成单向等待，适合确认是否需要回应",
                actionLabel: chatUsername == nil ? "看关系清单" : "打开对话",
                chatUsername: chatUsername,
                route: chatUsername.map(InsightRadarFinding.Route.openChat) ?? .expandRelationships
            ))
        }

        return findings
    }

    private static func displayName(for username: String, names: [String: String]) -> String {
        names[username] ?? username
    }

    private static func username(forDisplayName name: String, names: [String: String]) -> String? {
        if names.keys.contains(name) { return name }
        return names.first { $0.value == name }?.key
            ?? names.first { $0.value.localizedCaseInsensitiveContains(name) }?.key
    }

    private static func isMeaningfulAttitude(_ attitude: String) -> Bool {
        let text = attitude.trimmed
        guard !text.isEmpty else { return false }
        let neutralWords = ["正常", "中性", "平稳", "无明显", "未知"]
        return !neutralWords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func isHardNegative(_ attitude: String) -> Bool {
        let text = attitude.trimmed
        let words = ["反对", "拒绝", "抵触", "不满", "质疑", "回避", "敷衍", "催促"]
        return words.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func isConcreteRadarSource(_ source: String) -> Bool {
        let text = source.trimmed.lowercased()
        guard !text.isEmpty else { return false }
        let nonConcreteSources: Set<String> = ["全局", "系统", "简报", "未知", "无", "n/a", "null"]
        return !nonConcreteSources.contains(text)
    }

    private static func formatHours(_ hours: Double) -> String {
        if hours < 1 { return "\(Int(hours * 60)) 分钟" }
        if hours < 24 { return "\(Int(hours)) 小时" }
        return "\(Int(hours / 24)) 天"
    }

    private static func sanitizedFinding(_ finding: InsightRadarFinding) -> InsightRadarFinding? {
        guard let source = readableTrimmed(finding.source),
              let title = readableTrimmed(finding.title) else {
            return nil
        }

        let evidence = readableOptional(finding.evidence)
        let reason = readableOptional(finding.reason)
        let route = sanitizedRoute(finding.route, chatUsername: finding.chatUsername, kind: finding.kind)
        let chatUsername = route.chatUsername
        let actionLabel = readableTrimmed(finding.actionLabel) ?? defaultActionLabel(for: route)

        return InsightRadarFinding(
            id: finding.id,
            severity: finding.severity,
            kind: finding.kind,
            source: source,
            title: title,
            evidence: evidence,
            reason: reason,
            actionLabel: actionLabel,
            chatUsername: chatUsername,
            route: route
        )
    }

    private static func readableOptional(_ text: String?) -> String? {
        guard let text else { return nil }
        return readableTrimmed(text)
    }

    private static func readableTrimmed(_ text: String) -> String? {
        let trimmed = text.trimmed
        guard MessageHelpers.isReadableAIContent(trimmed, allowMediaPlaceholder: false) else {
            return nil
        }
        return trimmed
    }

    private static func sanitizedRoute(
        _ route: InsightRadarFinding.Route,
        chatUsername: String?,
        kind: InsightRadarFinding.Kind
    ) -> InsightRadarFinding.Route {
        switch route {
        case .openChat(let username):
            let target = username.trimmed
            if !target.isEmpty { return .openChat(target) }
        default:
            return route
        }

        if let chatUsername = chatUsername?.trimmed, !chatUsername.isEmpty {
            return .openChat(chatUsername)
        }
        return fallbackRoute(for: kind)
    }

    private static func fallbackRoute(for kind: InsightRadarFinding.Kind) -> InsightRadarFinding.Route {
        switch kind {
        case .pressure, .action, .waiting:
            return .expandPressure
        case .relationship:
            return .expandRelationships
        case .blindSpot:
            return .expandMetrics
        default:
            return .expandExplanation
        }
    }

    private static func defaultActionLabel(for route: InsightRadarFinding.Route) -> String {
        switch route {
        case .openChat:
            return "打开对话"
        case .expandPressure:
            return "看压力概览"
        case .expandRelationships:
            return "看关系清单"
        case .expandMetrics:
            return "查看概览"
        case .expandExplanation:
            return "查看依据"
        }
    }
}

private extension InsightRadarFinding {
    var priorityGroup: Int {
        switch kind {
        case .waiting, .action, .pressure:
            return 0
        case .attitude, .mood, .tone:
            return 1
        case .recall, .ignored:
            return 2
        case .relationship, .blindSpot:
            return 3
        }
    }
}

private extension InsightRadarFinding.Route {
    var chatUsername: String? {
        if case .openChat(let username) = self { return username }
        return nil
    }
}

extension InsightRadarFinding.Route {
    var isChatNavigation: Bool {
        if case .openChat = self { return true }
        return false
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == InsightRadarFinding {
    func deduplicatedByMeaning(chatNames: [String: String]) -> [InsightRadarFinding] {
        var resultByKey: [String: InsightRadarFinding] = [:]
        var order: [String] = []
        for item in self {
            let key = [
                item.kind.deduplicationGroup,
                item.semanticSubject(chatNames: chatNames),
                item.title.normalizedForRadarKey
            ].joined(separator: "|")

            if let existing = resultByKey[key] {
                resultByKey[key] = existing.preferred(over: item)
            } else {
                order.append(key)
                resultByKey[key] = item
            }
        }
        return order.compactMap { resultByKey[$0] }
    }
}

private extension InsightRadarFinding {
    func semanticSubject(chatNames: [String: String]) -> String {
        if let chatUsername { return chatUsername.normalizedForRadarKey }
        if chatNames.keys.contains(source) { return source.normalizedForRadarKey }
        if let match = chatNames.first(where: { $0.value == source })?.key {
            return match.normalizedForRadarKey
        }
        if let match = chatNames.first(where: { source.localizedCaseInsensitiveContains($0.value) })?.key {
            return match.normalizedForRadarKey
        }
        return source.normalizedForRadarKey
    }

    func preferred(over candidate: InsightRadarFinding) -> InsightRadarFinding {
        if candidate.severity != severity {
            return candidate.severity > severity ? candidate : self
        }
        if candidate.hasChatRoute != hasChatRoute {
            return candidate.hasChatRoute ? candidate : self
        }
        if candidate.evidence != nil && evidence == nil {
            return candidate
        }
        return self
    }

    var hasChatRoute: Bool {
        if case .openChat = route { return true }
        return false
    }
}

private extension InsightRadarFinding.Kind {
    var deduplicationGroup: String {
        switch self {
        case .waiting, .action:
            return "followup"
        default:
            return rawValue
        }
    }
}

private extension String {
    var normalizedForRadarKey: String {
        let lowered = lowercased()
            .replacingOccurrences(of: "yuriwong", with: "我")
            .replacingOccurrences(of: "yuri", with: "我")
            .replacingOccurrences(of: "哆啦", with: "我")
            .replacingOccurrences(of: "本人", with: "我")
            .replacingOccurrences(of: "自己", with: "我")
        return lowered
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }
}
