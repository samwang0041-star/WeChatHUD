import Foundation

/// One ambient fact for the collapsed island. The left mark, buddy, and
/// spoken status all read this — they must not advertise three different
/// stories at once.
struct CompactIslandInput {
    var sync: SyncStatus
    var actions: [CompactIslandAction]
    var noticeCount: Int
    var aiActive: Bool
    var autopilotActive: Bool
    var idleMinutes: Int
    var worstVIPTier: VIPAlertTier
}

struct CompactIslandAction: Equatable {
    var priority: InboxPriority
    var isVIP: Bool
    var isOverdue: Bool
}

enum CompactIslandPhase: Equatable {
    case connectionProblem
    case urgent(priority: InboxPriority, count: Int)
    case working(Working)
    case waiting(count: Int)
    case notices(count: Int)
    case quiet(sleepy: Bool)

    enum Working: Equatable {
        case syncing
        case analyzing
    }
}

enum CompactIslandMark: Equatable {
    case warning
    case dot(Kind)

    enum Kind: Equatable {
        case urgentP0
        case urgentP1
        case working
        case waiting
        case notices
        case quiet
    }
}

enum CompactIslandGlow: Equatable {
    case none
    case attention
    case critical
}

struct CompactIslandSnapshot: Equatable {
    var phase: CompactIslandPhase
    var mark: CompactIslandMark
    var badge: String?
    var buddy: BuddyMood
    var glow: CompactIslandGlow
    var spoken: String
}

enum CompactIslandPolicy {
    static func snapshot(_ input: CompactIslandInput) -> CompactIslandSnapshot {
        let phase = phase(for: input)
        return CompactIslandSnapshot(
            phase: phase,
            mark: mark(for: phase),
            badge: badge(for: phase),
            buddy: buddy(for: phase, autopilot: input.autopilotActive),
            glow: glow(for: phase, tier: input.worstVIPTier),
            spoken: spoken(for: phase)
        )
    }

    static func snapshot(
        items: [InboxItem],
        sync: SyncStatus,
        aiActive: Bool,
        autopilotActive: Bool,
        idleMinutes: Int,
        vipTiers: [String: VIPAlertTier]
    ) -> CompactIslandSnapshot {
        let surfaced = items.filter(\.surfacesInCompact)
        let actions = surfaced.filter(\.participatesInActionQueue)
        let notices = surfaced.filter { !$0.participatesInActionQueue }
        let vipGlowTier = actions
            .filter { $0.isVIP && ($0.priority == .p0 || $0.isOverdue) }
            .compactMap { vipTiers[$0.chatUsername] }
            .max() ?? .none
        return snapshot(CompactIslandInput(
            sync: sync,
            actions: actions.map {
                CompactIslandAction(priority: $0.priority, isVIP: $0.isVIP, isOverdue: $0.isOverdue)
            },
            noticeCount: notices.count,
            aiActive: aiActive,
            autopilotActive: autopilotActive,
            idleMinutes: idleMinutes,
            worstVIPTier: vipGlowTier
        ))
    }

    private static func phase(for input: CompactIslandInput) -> CompactIslandPhase {
        if isConnectionProblem(input.sync) {
            return .connectionProblem
        }
        let count = input.actions.count
        if let top = input.actions.min(by: { $0.priority < $1.priority }), top.priority == .p0 {
            return .urgent(priority: .p0, count: count)
        }
        if input.actions.contains(where: { $0.priority == .p1 }) {
            return .urgent(priority: .p1, count: count)
        }
        if input.aiActive {
            return .working(.analyzing)
        }
        if count > 0 {
            return .waiting(count: count)
        }
        if input.noticeCount > 0 {
            return .notices(count: input.noticeCount)
        }
        return .quiet(sleepy: input.idleMinutes >= 5)
    }

    private static func isConnectionProblem(_ sync: SyncStatus) -> Bool {
        switch sync {
        case .waitingForWeChat, .accountSwitched, .error, .stale:
            return true
        case .ok, .idle, .syncing:
            return false
        }
    }

    private static func mark(for phase: CompactIslandPhase) -> CompactIslandMark {
        switch phase {
        case .connectionProblem: return .warning
        case .urgent(let priority, _):
            return .dot(priority == .p0 ? .urgentP0 : .urgentP1)
        case .working: return .dot(.working)
        case .waiting: return .dot(.waiting)
        case .notices: return .dot(.notices)
        case .quiet: return .dot(.quiet)
        }
    }

    private static func badge(for phase: CompactIslandPhase) -> String? {
        let count: Int
        switch phase {
        case .urgent(_, let n), .waiting(let n), .notices(let n):
            count = n
        default:
            return nil
        }
        guard count > 1 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    private static func buddy(for phase: CompactIslandPhase, autopilot: Bool) -> BuddyMood {
        let base: BuddyMood
        switch phase {
        case .connectionProblem: base = .error
        case .urgent(let priority, _): base = priority == .p0 ? .urgent : .pending
        case .working(.syncing): base = .scanning
        case .working(.analyzing): base = .analyzing
        case .waiting: base = .pending
        case .notices: base = .idle
        case .quiet(let sleepy): base = sleepy ? .sleepy : .idle
        }
        guard autopilot else { return base }
        switch base {
        case .idle, .pending, .sleepy, .browsing, .celebrating:
            return .autopiloting
        case .scanning, .urgent, .error, .analyzing, .autopiloting:
            return base
        }
    }

    private static func glow(for phase: CompactIslandPhase, tier: VIPAlertTier) -> CompactIslandGlow {
        guard case .urgent = phase, tier >= .t2 else { return .none }
        return tier >= .t3 ? .critical : .attention
    }

    private static func spoken(for phase: CompactIslandPhase) -> String {
        switch phase {
        case .connectionProblem:
            return "微信还连不上。移入查看，平时不打扰。"
        case .urgent(let priority, let count):
            let what = priority == .p0 ? "有需要尽快处理的事" : "有待回复的消息"
            return "\(what)，共 \(count) 项。移入查看，平时不打扰。"
        case .working(.analyzing):
            return "AI 正在整理。移入查看，平时不打扰。"
        case .working(.syncing):
            return "正在同步微信。移入查看，平时不打扰。"
        case .waiting(let count):
            // "收起" is internal state vocabulary — a spoken/tooltip
            // label should just say what's inside.
            return "\(count) 项待处理。移入查看，平时不打扰。"
        case .notices(let count):
            return "有 \(count) 条群里的新消息。移入查看，平时不打扰。"
        case .quiet:
            return "暂无待处理。移入查看，平时不打扰。"
        }
    }
}
