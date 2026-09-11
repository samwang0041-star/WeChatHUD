import Foundation

/// Constants shared across the Codex layer. Hardcoded to match
/// codex-cli + pi-ai exactly so OpenAI sees an identical client.
enum CodexConstants {
    /// codex-cli's official OAuth client ID; reused by pi-ai/openclaw.
    static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let oauthTokenURL = "https://auth.openai.com/oauth/token"
    static let backendURL = "https://chatgpt.com/backend-api/codex/responses"
    /// User-Agent prefix matching pi-ai's `pi (<platform> <release>; <arch>)`.
    static let userAgentPrefix = "pi"
}

/// Tokens returned by `auth.openai.com/oauth/token`.
struct RefreshedTokens: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
}

/// Holds the live ChatGPT OAuth access token used by CodexBackend.
///
/// On cold start (or after a 401) reads codex CLI's `auth.json` to seed the
/// refresh token; thereafter keeps a refreshed access token in memory.
/// **Never writes back to auth.json** — codex CLI owns that file.
actor CodexTokenStore {
    static let shared = CodexTokenStore()

    private let urlSession: URLSession
    private let envProvider: @Sendable () -> [String: String]
    /// Refresh `safetyMargin` seconds before the JWT `exp` to avoid mid-request expiry.
    private let safetyMargin: TimeInterval = 60

    private var accessToken: String?
    private var accessExpiresAt: Date = .distantPast
    private var refreshToken: String?
    /// The refresh token as it appears on disk, kept alongside the in-memory
    /// one so a failed refresh can fall back instead of overwriting it.
    private var fileRefreshToken: String?
    /// True when `refreshToken` came from a server rotation in this process
    /// (the response body carries a new `refresh_token` on every use).
    private var refreshTokenWasRotated = false
    private var accountId: String?
    private var emailCached: String?

    /// In-flight refresh — concurrent callers await the same task instead of
    /// burning multiple refreshes on the same refresh_token.
    private var refreshInFlight: Task<RefreshedTokens, Error>?

    init(
        urlSession: URLSession = .shared,
        envProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.urlSession = urlSession
        self.envProvider = envProvider
    }

    // MARK: - Public

    /// Return a valid (access, accountId) pair. Reads auth.json on first call,
    /// refreshes when within `safetyMargin` of expiry.
    func validToken() async throws -> (access: String, accountId: String) {
        if let access = accessToken, let acct = accountId,
           Date() < accessExpiresAt.addingTimeInterval(-safetyMargin) {
            return (access, acct)
        }
        try await loadOrRefresh(forceReread: refreshToken == nil)
        guard let access = accessToken, let acct = accountId else {
            throw CodexError.authExpired
        }
        return (access, acct)
    }

    /// Called by CodexBackend when it receives HTTP 401: drop the cache, re-read
    /// auth.json (codex CLI may have rotated the refresh token more recently),
    /// then force a refresh. Returns the new (access, accountId).
    func refreshAfter401() async throws -> (access: String, accountId: String) {
        accessToken = nil
        accessExpiresAt = .distantPast
        refreshInFlight = nil
        try await loadOrRefresh(forceReread: true)
        guard let access = accessToken, let acct = accountId else {
            throw CodexError.authExpired
        }
        return (access, acct)
    }

    /// Email of the bound ChatGPT account, if known. Used by Settings UI.
    func currentEmail() async -> String? { emailCached }

    // MARK: - Internals

    private func loadOrRefresh(forceReread: Bool) async throws {
        if forceReread {
            let profile = try CodexAuth.readProfile(env: envProvider())
            accountId = profile.accountId
            emailCached = profile.email
            // Do not clobber a token this process already rotated. We never
            // write back to auth.json (codex CLI owns it), so after our own
            // refresh the file still holds the *older* token — adopting it
            // meant refreshing with a token the server had already invalidated,
            // and losing the only live one. The file's token stays available as
            // a fallback for the reverse case (the CLI rotated it).
            if refreshToken == nil || !refreshTokenWasRotated {
                refreshToken = profile.refreshToken
            }
            fileRefreshToken = profile.refreshToken
            // If the access token in auth.json is itself still valid, use it
            // directly without burning a refresh.
            if Date() < profile.accessExpiresAt.addingTimeInterval(-safetyMargin) {
                accessToken = profile.accessToken
                accessExpiresAt = profile.accessExpiresAt
                return
            }
        }
        try await performRefresh()
    }

    private func performRefresh() async throws {
        if let inFlight = refreshInFlight {
            let result = try await inFlight.value
            applyRefreshed(result)
            return
        }
        let candidates = Self.refreshCandidates(
            inMemory: refreshToken,
            fromFile: fileRefreshToken,
            inMemoryWasRotated: refreshTokenWasRotated
        )
        guard !candidates.isEmpty else { throw CodexError.authExpired }

        let session = urlSession
        let task = Task<RefreshedTokens, Error>.detached(priority: .userInitiated) {
            var lastError: Error = CodexError.authExpired
            for candidate in candidates {
                do {
                    return try await Self.networkRefresh(refreshToken: candidate, session: session)
                } catch {
                    // A token the server has already rotated away answers
                    // invalid_grant; the other candidate may still be live.
                    lastError = error
                }
            }
            throw lastError
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }

        let result = try await task.value
        applyRefreshed(result)
    }

    /// Ordered refresh-token candidates for a single refresh attempt.
    ///
    /// The token that most likely works goes first. If this process already
    /// rotated the token, the in-memory one is newer than the file's; if it has
    /// not, the file's token is the fresher of the two (codex CLI may have
    /// logged in again since we read it).
    static func refreshCandidates(
        inMemory: String?,
        fromFile: String?,
        inMemoryWasRotated: Bool
    ) -> [String] {
        var out: [String] = []
        func add(_ token: String?) {
            guard let token, !token.isEmpty, !out.contains(token) else { return }
            out.append(token)
        }
        if inMemoryWasRotated {
            add(inMemory)
            add(fromFile)
        } else {
            add(fromFile)
            add(inMemory)
        }
        return out
    }

    private func applyRefreshed(_ result: RefreshedTokens) {
        accessToken = result.accessToken
        // Prefer the JWT `exp` claim for accuracy; fall back to `expires_in`.
        if let claims = try? CodexAuth.decodeJWTPayload(result.accessToken) {
            if let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init) {
                accessExpiresAt = Date(timeIntervalSince1970: exp)
            } else {
                accessExpiresAt = Date().addingTimeInterval(result.expiresIn)
            }
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
               let acct = (auth["chatgpt_account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !acct.isEmpty {
                accountId = acct
            }
        } else {
            accessExpiresAt = Date().addingTimeInterval(result.expiresIn)
        }
        // Server rotates refresh_token on use — keep the newest in memory.
        refreshToken = result.refreshToken
        refreshTokenWasRotated = true
    }

    // MARK: - Network

    /// Hits `auth.openai.com/oauth/token` with the same form payload codex-cli
    /// uses. Static + nonisolated so it can run on a detached task without
    /// re-entering the actor.
    nonisolated private static func networkRefresh(
        refreshToken: String,
        session: URLSession
    ) async throws -> RefreshedTokens {
        guard let url = URL(string: CodexConstants.oauthTokenURL) else {
            throw CodexError.authRefreshFailed("invalid OAuth URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": CodexConstants.oauthClientID
        ]
        req.httpBody = formEncode(form).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CodexError.authRefreshFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexError.authRefreshFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CodexError.authRefreshFailed("HTTP \(http.statusCode): \(body)")
        }
        guard let parsed = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw CodexError.authRefreshFailed("malformed JSON")
        }
        return RefreshedTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresIn: TimeInterval(parsed.expiresIn)
        )
    }

    /// `application/x-www-form-urlencoded` body builder. Percent-encodes both
    /// keys and values per RFC 3986 unreserved set.
    nonisolated private static func formEncode(_ pairs: [String: String]) -> String {
        pairs.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.sorted().joined(separator: "&")
    }

    nonisolated private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Refresh response shape

private struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
