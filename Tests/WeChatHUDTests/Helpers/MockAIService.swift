import Foundation
@testable import WeChatHUD

/// Substring-routed mock for `AIServiceProtocol`. Use `setRoute(needle:response:)`
/// to register canned JSON for prompts containing a substring; first match wins.
/// `setShouldThrow(_:)` makes `complete` throw the given error.
actor MockAIService: AIServiceProtocol {
    private var routes: [(needle: String, response: String)] = []
    private(set) var calls: [(system: String, user: String, options: CompleteOptions)] = []
    var defaultResponse: String = "{}"
    var shouldThrow: Error? = nil
    var configToReturn: AIConfig = AIConfig()

    nonisolated init() {}

    func setRoute(needle: String, response: String) {
        routes.append((needle, response))
    }

    func setDefaultResponse(_ s: String) { defaultResponse = s }

    func setShouldThrow(_ err: Error) { shouldThrow = err }

    func setConfig(_ c: AIConfig) { configToReturn = c }

    // MARK: - AIServiceProtocol

    func complete(system: String, user: String, options: CompleteOptions) async throws -> String {
        calls.append((system, user, options))
        if let err = shouldThrow { throw err }
        for r in routes where user.contains(r.needle) { return r.response }
        return defaultResponse
    }

    func currentConfig() async -> AIConfig {
        configToReturn
    }
}
