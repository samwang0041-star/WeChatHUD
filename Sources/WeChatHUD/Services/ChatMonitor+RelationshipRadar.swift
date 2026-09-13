import Foundation

extension ChatMonitor {
    /// Rebuild relationship-radar snapshots from stored daily facts after a
    /// successful scan. Deterministic, no AI, no outbound WeChat send.
    /// Silence days in particular only move when wall-clock time advances,
    /// so a scan tick is the right heartbeat — not a new model call.
    func refreshRelationshipRadarAfterScan(now: Date = Date()) async {
        let storeRef = store
        _ = await Self.runOffMain {
            (try? RelationshipRadarService.refreshAll(store: storeRef, now: now)) ?? 0
        }
    }
}
