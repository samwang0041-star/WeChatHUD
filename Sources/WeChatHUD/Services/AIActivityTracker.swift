import Foundation

/// Tracks active AI API calls across all services.
/// UI can observe `activeTasks` to show what's currently running.
@MainActor
final class AIActivityTracker: ObservableObject {
    nonisolated static let shared = AIActivityTracker()

    struct TaskInfo: Identifiable {
        let id: String
        let label: String
        let detail: String       // e.g. model name, chat name
        let startedAt: Date
        var endedAt: Date?

        var isActive: Bool { endedAt == nil }
        func elapsed(now: Date) -> TimeInterval {
            now.timeIntervalSince(startedAt)
        }
    }

    @Published private(set) var activeTasks: [String: TaskInfo] = [:]
    @Published private(set) var recentCompleted: [TaskInfo] = []  // last N finished

    nonisolated init() {}

    var isActive: Bool { !activeTasks.isEmpty }

    var taskList: [TaskInfo] {
        Array(activeTasks.values).sorted { $0.startedAt < $1.startedAt }
    }

    /// All tasks: active first, then recent completed (reversed)
    var allTasks: [TaskInfo] {
        taskList + recentCompleted
    }

    nonisolated func begin(_ id: String, label: String, detail: String = "") {
        Task { @MainActor in
            activeTasks[id] = TaskInfo(id: id, label: label, detail: detail, startedAt: Date())
        }
    }

    nonisolated func end(_ id: String) {
        Task { @MainActor in
            guard var task = activeTasks.removeValue(forKey: id) else { return }
            task.endedAt = Date()
            recentCompleted.insert(task, at: 0)
            if recentCompleted.count > 10 { recentCompleted.removeLast() }
        }
    }
}
