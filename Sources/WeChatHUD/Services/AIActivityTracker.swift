import Foundation

/// Tracks active AI API calls across all services.
/// UI can observe `activeTasks` to show what's currently running.
@MainActor
final class AIActivityTracker: ObservableObject {
    static let shared = AIActivityTracker()

    struct TaskInfo: Identifiable {
        let id: String          // unique key, e.g. "classifier:chat123"
        let label: String       // human-readable, e.g. "消息分类"
        let startedAt: Date
    }

    @Published private(set) var activeTasks: [String: TaskInfo] = [:]

    var isActive: Bool { !activeTasks.isEmpty }
    var taskList: [TaskInfo] { Array(activeTasks.values).sorted { $0.startedAt < $1.startedAt } }

    nonisolated func begin(_ id: String, label: String) {
        Task { @MainActor in
            activeTasks[id] = TaskInfo(id: id, label: label, startedAt: Date())
        }
    }

    nonisolated func end(_ id: String) {
        Task { @MainActor in
            activeTasks.removeValue(forKey: id)
        }
    }

    /// Convenience: run an async block with automatic begin/end tracking.
    nonisolated func track<T>(_ id: String, label: String, _ body: () async throws -> T) async rethrows -> T {
        begin(id, label: label)
        defer { end(id) }
        return try await body()
    }
}
