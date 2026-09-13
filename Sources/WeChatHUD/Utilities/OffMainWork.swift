import Foundation

/// Hop CPU / SQLite work off the caller's actor without `Task.detached`.
///
/// `Task.detached` is easy to misuse with captured `WeChatReader` / `HUDStore`
/// references. A plain global-queue hop keeps the same off-main behavior while
/// leaving cancellation checks to the surrounding async function between hops.
enum OffMainWork {
    static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
    }

    static func runThrowing<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
