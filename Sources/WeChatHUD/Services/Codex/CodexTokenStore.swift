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
/// **Never writes back to auth.json** — codex CLI owns that file. Rotated
/// refresh tokens ARE written to our own store (`codex-tokens.json`): the
/// server invalidates a refresh token on use, so keeping the successor only
/// in memory meant a restart — and the codex CLI itself — would present the
/// dead file token, get `invalid_grant`, and force a re-login.
actor CodexTokenStore {
    static let shared = CodexTokenStore()

    private let urlSession: URLSession
    private let envProvider: @Sendable () -> [String: String]
    /// Refresh `safetyMargin` seconds before the JWT `exp` to avoid mid-request expiry.
    private let safetyMargin: TimeInterval = 60
    /// App-owned rotated-token store. Written 0600 via atomic rename.
    private let persistedTokensURL: URL

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
        envProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        persistedTokensURL: URL? = nil
    ) {
        self.urlSession = urlSession
        self.envProvider = envProvider
        self.persistedTokensURL = persistedTokensURL
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.wechat-hud/codex-tokens.json")
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

    /// Called by CodexBackend when it receives HTTP 401: drop the access
    /// token, re-read auth.json + our rotated-token store, then force a
    /// refresh. An in-flight refresh is JOINED, not orphaned — superseding it
    /// would start a second POST on the same refresh_token candidates where
    /// rotation means only one can win.
    func refreshAfter401() async throws -> (access: String, accountId: String) {
        accessToken = nil
        accessExpiresAt = .distantPast
        try await loadOrRefresh(forceReread: true, forceRefresh: true)
        guard let access = accessToken, let acct = accountId else {
            throw CodexError.authExpired
        }
        return (access, acct)
    }

    /// Email of the bound ChatGPT account, if known. Used by Settings UI.
    func currentEmail() async -> String? { emailCached }

    // MARK: - Internals

    private func loadOrRefresh(forceReread: Bool, forceRefresh: Bool = false) async throws {
        if forceReread {
            // The app-owned store holds the token WE last rotated — newer
            // than auth.json's (which we never write). Seed from it first.
            if let persisted = Self.readPersistedTokens(at: persistedTokensURL) {
                if refreshToken == nil || !refreshTokenWasRotated {
                    refreshToken = persisted.refreshToken
                    // A persisted token is by definition one WE rotated —
                    // mark it so the auth.json block below can't clobber it
                    // with the dead pre-rotation token (we never write
                    // auth.json back, so it still holds the stale one).
                    refreshTokenWasRotated = true
                }
                if accountId == nil { accountId = persisted.accountId }
                if emailCached == nil { emailCached = persisted.email }
                if !forceRefresh,
                   Date() < persisted.accessExpiresAt.addingTimeInterval(-safetyMargin) {
                    accessToken = persisted.accessToken
                    accessExpiresAt = persisted.accessExpiresAt
                    refreshTokenWasRotated = true
                    if let profile = try? CodexAuth.readProfile(env: envProvider()) {
                        fileRefreshToken = profile.refreshToken
                    }
                    return
                }
            }
            // auth.json may be absent while our rotated token is still live
            // (user moved/deleted ~/.codex after we refreshed) — our store
            // stands alone in that case.
            let profile = try? CodexAuth.readProfile(env: envProvider())
            if let profile {
                accountId = profile.accountId
                emailCached = profile.email
            }
            if refreshToken == nil && profile == nil {
                throw CodexError.notLoggedIn
            }
            // Do not clobber a token this process already rotated. We never
            // write back to auth.json (codex CLI owns it), so after our own
            // refresh the file still holds the *older* token — adopting it
            // meant refreshing with a token the server had already invalidated,
            // and losing the only live one. The file's token stays available as
            // a fallback for the reverse case (the CLI rotated it).
            if let profile {
                if refreshToken == nil || !refreshTokenWasRotated {
                    refreshToken = profile.refreshToken
                }
                fileRefreshToken = profile.refreshToken
            }
            // If the access token in auth.json is itself still valid, use it
            // directly without burning a refresh — EXCEPT on the 401 path,
            // where this is the same token the server just refused; adopting
            // it would loop 401 → adopt → 401 until its exp runs out.
            if !forceRefresh, let profile,
               Date() < profile.accessExpiresAt.addingTimeInterval(-safetyMargin) {
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

        do {
            let result = try await task.value
            applyRefreshed(result)
        } catch {
            // Cross-process race: the codex CLI may have rotated auth.json
            // mid-flight, so every candidate we just tried is stale. Reread
            // once and retry with a token we have not tried before giving up
            // to authExpired (which forces a manual re-login). The persisted
            // store can hold a newer rotated token too — a second app
            // instance (Preview alongside the real build) refreshes the
            // shared file while this instance still holds a stale in-memory
            // token; retry the persisted tip before falling back to auth.json.
            if let persisted = Self.readPersistedTokens(at: persistedTokensURL),
               !candidates.contains(persisted.refreshToken) {
                refreshToken = persisted.refreshToken
                refreshTokenWasRotated = true
                do {
                    let retry = try await Self.networkRefresh(refreshToken: persisted.refreshToken, session: session)
                    applyRefreshed(retry)
                    return
                } catch { /* fall through to the auth.json retry */ }
            }
            if let profile = try? CodexAuth.readProfile(env: envProvider()),
               !profile.refreshToken.isEmpty,
               !candidates.contains(profile.refreshToken) {
                fileRefreshToken = profile.refreshToken
                let retry = try await Self.networkRefresh(refreshToken: profile.refreshToken, session: session)
                applyRefreshed(retry)
                return
            }
            throw error
        }
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
        // An unclamped expires_in of <= 0 would expire instantly and burn a
        // refresh on every call — bound it to a sane window.
        let expiresIn = min(max(result.expiresIn, 60), 86400)
        if let claims = try? CodexAuth.decodeJWTPayload(result.accessToken) {
            if let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init),
               exp > Date().timeIntervalSince1970 {
                accessExpiresAt = Date(timeIntervalSince1970: exp)
            } else {
                accessExpiresAt = Date().addingTimeInterval(expiresIn)
            }
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
               let acct = (auth["chatgpt_account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !acct.isEmpty {
                accountId = acct
            }
        } else {
            accessExpiresAt = Date().addingTimeInterval(expiresIn)
        }
        // Server rotates refresh_token on use — keep the newest, persisted.
        // In-memory-only persistence bricked the whole login on restart: the
        // file's stale token would fail invalid_grant and force re-login.
        refreshToken = result.refreshToken
        refreshTokenWasRotated = true
        if let acct = accountId {
            Self.writePersistedTokens(
                CodexPersistedTokens(
                    accessToken: result.accessToken,
                    refreshToken: result.refreshToken,
                    accessExpiresAt: accessExpiresAt,
                    accountId: acct,
                    email: emailCached
                ),
                at: persistedTokensURL
            )
        }
    }

    // MARK: - Persisted rotated tokens

    /// The rotated-token file this app owns — auth.json stays untouched.
    /// Same hardening shape as CodexAuth.assertSecureAuthFile.
    private struct CodexPersistedTokens: Codable {
        let accessToken: String
        let refreshToken: String
        let accessExpiresAt: Date
        let accountId: String
        let email: String?
    }

    private static func readPersistedTokens(at url: URL) -> CodexPersistedTokens? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_size > 0, info.st_size < 256 * 1024,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexPersistedTokens.self, from: data),
              !decoded.refreshToken.isEmpty, !decoded.accessToken.isEmpty
        else { return nil }
        return decoded
    }

    private static func writePersistedTokens(_ tokens: CodexPersistedTokens, at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let stage = url.appendingPathExtension(UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        guard let data = try? JSONEncoder().encode(tokens),
              fm.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: stage) else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(stage.path, url.path) == 0 else { return }
        } catch {
            try? handle.close()
        }
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
            // Never embed the OAuth error body — error_description can echo
            // submitted values, and this string reaches audit + UI.
            throw CodexError.authRefreshFailed("HTTP \(http.statusCode)")
        }
        guard let parsed = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw CodexError.authRefreshFailed("malformed JSON")
        }
        // RFC 6749 §6 allows the server to omit refresh_token (reuse the old
        // one) — requiring it would lose the rotated successor entirely.
        return RefreshedTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken ?? refreshToken,
            expiresIn: parsed.expiresIn
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
    let refreshToken: String?   // RFC 6749 §6: MAY be omitted (reuse old)
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        // expires_in may arrive as Int, Double, or a numeric string.
        if let n = try? c.decode(Double.self, forKey: .expiresIn) {
            expiresIn = n
        } else if let s = try? c.decode(String.self, forKey: .expiresIn), let n = Double(s) {
            expiresIn = n
        } else {
            expiresIn = 3600
        }
    }
}
