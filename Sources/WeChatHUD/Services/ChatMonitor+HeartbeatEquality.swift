import Foundation

/// Cadence + tolerance of the safety heartbeat. File-scope (not nested in the
/// MainActor-isolated ChatMonitor) so it stays usable from nonisolated policy
/// checks and tests.
struct SafetyTickSchedule: Equatable {
    let interval: TimeInterval
    let tolerance: TimeInterval

    /// 10 s while an autopilot send countdown is on screen — that countdown is
    /// rendered in whole seconds, so the tick must not drift. 30 s with nothing
    /// queued: there is no countdown to be accurate about, and the process pays
    /// a wake-up on every tick whether or not anything changed.
    static let countdownInterval: TimeInterval = 10
    static let idleInterval: TimeInterval = 30
    /// Slack handed to the OS. A timer with tolerance lets the kernel coalesce
    /// this wake-up with other timers instead of spinning the CPU up on the
    /// exact second — the standard way to make a heartbeat power-friendly.
    /// Capped at a fifth of the interval so the timer can never slip a whole
    /// period.
    static let maxTolerance: TimeInterval = 2

    static func make(countdownActive: Bool) -> SafetyTickSchedule {
        let interval = countdownActive ? countdownInterval : idleInterval
        return SafetyTickSchedule(interval: interval, tolerance: min(maxTolerance, interval / 5))
    }
}

// The safety heartbeat compares the previous autopilot snapshot against the
// new one before assigning (see ChatMonitor.publishAutopilotHeartbeat): an
// unconditional published assignment fires objectWillChange and re-renders
// every observing view even when nothing changed, which is exactly the idle
// HUD churn the heartbeat work removed.
//
// PendingSend and AutopilotService.SessionStats are plain value snapshots with
// no reference members, so a field-wise comparison is the whole story. The
// conformances live in the file that needs them rather than next to their
// declarations, keeping this performance change local instead of editing the
// model / service files for a comparison only this call site performs.

extension PendingSend: Equatable {
    static func == (lhs: PendingSend, rhs: PendingSend) -> Bool {
        lhs.id == rhs.id
            && lhs.chatUsername == rhs.chatUsername
            && lhs.chatName == rhs.chatName
            && lhs.senderName == rhs.senderName
            && lhs.replyText == rhs.replyText
            && lhs.confidence == rhs.confidence
            && lhs.risk == rhs.risk
            && lhs.reasoning == rhs.reasoning
            && lhs.styleScore == rhs.styleScore
            && lhs.scheduledSendTime == rhs.scheduledSendTime
            && lhs.createdAt == rhs.createdAt
            && lhs.peerLastMessage == rhs.peerLastMessage
            && lhs.topic == rhs.topic
            && lhs.autoSendAttempts == rhs.autoSendAttempts
            && lhs.manualOnlyReason == rhs.manualOnlyReason
    }
}

extension AutopilotService.SessionStats: Equatable {
    static func == (lhs: AutopilotService.SessionStats, rhs: AutopilotService.SessionStats) -> Bool {
        lhs.totalSent == rhs.totalSent
            && lhs.totalReadNoReply == rhs.totalReadNoReply
            && lhs.totalPending == rhs.totalPending
            && lhs.totalSkipped == rhs.totalSkipped
            && lhs.styleScoreSum == rhs.styleScoreSum
            && lhs.styleScoreCount == rhs.styleScoreCount
            && lhs.delaySum == rhs.delaySum
            && lhs.delayCount == rhs.delayCount
            && lhs.startedAt == rhs.startedAt
    }
}
