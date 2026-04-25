import Foundation

/// Protocol surface that retrospective services depend on. Real
/// `AIService` (actor) and `MockAIService` (test helper) both
/// conform to this so DI works without exposing the concrete actor
/// type. Plan M4.0.
protocol AIServiceProtocol: Sendable {
    func complete(system: String, user: String, options: CompleteOptions) async throws -> String
    func currentConfig() async -> AIConfig
}

extension AIService: AIServiceProtocol {
    // The actor's existing `func complete(system:user:options:) async throws -> String`
    // and `func currentConfig() -> AIConfig` already satisfy the protocol
    // (Swift auto-promotes the actor-isolated sync method to satisfy the
    // protocol's nonisolated async requirement).
}
