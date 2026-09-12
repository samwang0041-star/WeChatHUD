import Foundation
import Combine

/// Compact-island inputs that actually change what the wings show.
/// ChatMonitor publishes this only when the value differs, so scan ticks
/// that only flip extraction flags do not redraw the island.
struct IslandLiveInput: Equatable {
    var sync: SyncStatus
    var actions: [CompactIslandAction]
    var noticeCount: Int
    var autopilotActive: Bool
    var vipGlowTier: VIPAlertTier
}

@MainActor
final class IslandPresentation: ObservableObject {
    @Published private(set) var live = IslandLiveInput(
        sync: .idle,
        actions: [],
        noticeCount: 0,
        autopilotActive: false,
        vipGlowTier: .none
    )

    func publish(_ next: IslandLiveInput) {
        let stabilized = Self.stabilizing(next, previous: live)
        guard stabilized != live else { return }
        live = stabilized
    }

    /// Background scans flip `ChatMonitor` to `.syncing`. The island must
    /// keep the last real status so a 10-second tick does not hide badges.
    /// This is the deliberate anti-flicker design, not an accident: `.syncing`
    /// therefore never reaches `CompactIslandPolicy`, which is why the policy
    /// has no syncing "working" phase. Add one there only after removing this
    /// rewrite.
    static func stabilizing(_ next: IslandLiveInput, previous: IslandLiveInput) -> IslandLiveInput {
        var next = next
        if case .syncing = next.sync {
            if case .syncing = previous.sync {
                next.sync = .idle
            } else {
                next.sync = previous.sync
            }
        }
        return next
    }

    static func liveInput(
        items: [InboxItem],
        sync: SyncStatus,
        autopilotActive: Bool,
        vipTiers: [String: VIPAlertTier]
    ) -> IslandLiveInput {
        let surfaced = items.filter(\.surfacesInCompact)
        let actions = surfaced.filter(\.participatesInActionQueue)
        let notices = surfaced.filter { !$0.participatesInActionQueue }
        let vipGlowTier = actions
            .filter { $0.isVIP && ($0.priority == .p0 || $0.isOverdue) }
            .compactMap { vipTiers[$0.chatUsername] }
            .max() ?? .none
        return IslandLiveInput(
            sync: sync,
            actions: actions.map {
                CompactIslandAction(priority: $0.priority, isVIP: $0.isVIP, isOverdue: $0.isOverdue)
            },
            noticeCount: notices.count,
            autopilotActive: autopilotActive,
            vipGlowTier: vipGlowTier
        )
    }
}

struct WorkspaceBadgeCounts: Equatable {
    var tasks = 0
    var commitments = 0
    var drafts = 0
    var pendingReplies = 0

    /// Sidebar 待办 badge. Matches the island default and 今天「我要做」:
    /// live pending work assigned to me, not info memos and not the whole dump.
    static func taskCount(_ items: [DiscussionItem]) -> Int {
        items.filter { $0.status == .pending && $0.kind != .info && $0.owner == .mine }.count
    }
}

@MainActor
final class WorkspaceBadges: ObservableObject {
    @Published private(set) var counts = WorkspaceBadgeCounts()

    func publish(_ next: WorkspaceBadgeCounts) {
        guard next != counts else { return }
        counts = next
    }
}
