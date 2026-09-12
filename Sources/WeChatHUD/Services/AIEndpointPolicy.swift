import Foundation

/// Where an OpenAI-compatible endpoint is allowed to live.
///
/// Remote providers must speak HTTPS so a Bearer token never rides cleartext.
/// Loopback HTTP stays allowed for Ollama / LM Studio / Hermes.
enum AIEndpointPolicy {
    static func isLoopbackHost(_ host: String) -> Bool {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("[") {
            if let close = trimmed.firstIndex(of: "]") {
                trimmed = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            }
        }
        return ["localhost", "127.0.0.1", "::1"].contains(trimmed)
    }

    static func isLoopbackURL(_ url: URL) -> Bool {
        isLoopbackHost(url.host ?? "")
    }

    /// `normalized` is the output of `AIService.normalizeBaseURL`.
    static func validateNormalizedBaseURL(_ normalized: String) throws {
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased() else {
            throw AIError.invalidURL(normalized)
        }
        if scheme == "https" { return }
        if scheme == "http" {
            guard isLoopbackURL(url) else {
                throw AIError.insecureCleartext(normalized)
            }
            return
        }
        throw AIError.invalidURL(normalized)
    }
}
