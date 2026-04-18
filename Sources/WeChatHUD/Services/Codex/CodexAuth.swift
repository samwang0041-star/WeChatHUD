import Foundation

/// Profile extracted from codex CLI's auth.json — used by CodexTokenStore as
/// the source of truth for refresh, and by SettingsWindow to show the bound
/// account email.
struct CodexAuthProfile: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accountId: String      // → chatgpt-account-id header
    let email: String?         // for Settings UI display
    let accessExpiresAt: Date  // from JWT `exp` claim
}

/// Codex-side errors. Surfaced to UI strings via `errorDescription`.
enum CodexError: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case notChatGPTMode
    case missingTokens
    case invalidJWT
    case missingAccountId
    case authRefreshFailed(String)
    case authExpired
    case usageLimitReached
    case backendError(String)
    case responseFailed(String)
    case timeout
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "未检测到 codex 登录态，请在终端运行 `codex login`"
        case .notChatGPTMode:
            return "auth.json 不是 ChatGPT OAuth 模式，请用 `codex login` 重新登录"
        case .missingTokens:
            return "auth.json 缺少 access_token 或 refresh_token"
        case .invalidJWT:
            return "无法解析 access_token JWT"
        case .missingAccountId:
            return "JWT 中缺少 chatgpt_account_id"
        case .authRefreshFailed(let m):
            return "Token refresh 失败: \(m)"
        case .authExpired:
            return "Codex 登录态已过期，请重新运行 `codex login`"
        case .usageLimitReached:
            return "ChatGPT 用量上限已触达"
        case .backendError(let m):
            return "Codex 后端错误: \(m)"
        case .responseFailed(let m):
            return "Codex 响应失败: \(m)"
        case .timeout:
            return "Codex 请求超时"
        case .invalidResponse(let m):
            return "Codex 响应解析失败: \(m)"
        }
    }
}

/// Stateless helpers for reading codex CLI's auth.json and decoding the
/// embedded ChatGPT OAuth JWT. Mirrors pi-ai's
/// `dist/utils/oauth/openai-codex.js` + openclaw's `openai-codex-cli-auth.js`
/// behavior.
enum CodexAuth {

    // MARK: - Public

    /// Resolve codex CLI's home: `$CODEX_HOME` (with `~` expansion) or `~/.codex`.
    static func resolveCodexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configured.isEmpty { return home.appendingPathComponent(".codex") }
        if configured == "~" { return home }
        if configured.hasPrefix("~/") {
            return home.appendingPathComponent(String(configured.dropFirst(2)))
        }
        return URL(fileURLWithPath: configured)
    }

    /// Read and validate the codex CLI auth file. Throws `CodexError` for any
    /// missing/malformed input; returns a profile ready for use with
    /// `CodexTokenStore` / `CodexBackend` on success.
    static func readProfile(env: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexAuthProfile {
        let path = resolveCodexHome(env: env).appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw CodexError.notLoggedIn
        }
        let data = try Data(contentsOf: path)
        let raw = try JSONDecoder().decode(RawAuthFile.self, from: data)
        return try parseProfile(raw: raw)
    }

    /// Build a profile from a previously-decoded auth file (separated for testability).
    static func parseProfile(raw: RawAuthFile) throws -> CodexAuthProfile {
        guard raw.authMode == "chatgpt" else { throw CodexError.notChatGPTMode }
        guard let tokens = raw.tokens else { throw CodexError.missingTokens }
        guard let access = nonEmpty(tokens.accessToken),
              let refresh = nonEmpty(tokens.refreshToken)
        else { throw CodexError.missingTokens }

        let claims = try decodeJWTPayload(access)

        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let jwtAccountId = nonEmpty(authClaims?["chatgpt_account_id"] as? String)
        let fileAccountId = nonEmpty(tokens.accountId)
        guard let accountId = jwtAccountId ?? fileAccountId else {
            throw CodexError.missingAccountId
        }

        let profileClaims = claims["https://api.openai.com/profile"] as? [String: Any]
        let email = nonEmpty(profileClaims?["email"] as? String)

        let expiresAt = Date(timeIntervalSince1970: extractExp(claims))

        return CodexAuthProfile(
            accessToken: access,
            refreshToken: refresh,
            accountId: accountId,
            email: email,
            accessExpiresAt: expiresAt
        )
    }

    /// Split + decode a JWT (header.payload.signature) and return the payload
    /// claims dictionary. Throws `.invalidJWT` for any malformed input.
    static func decodeJWTPayload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CodexError.invalidJWT }
        guard let data = base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any]
        else { throw CodexError.invalidJWT }
        return json
    }

    /// Base64URL (RFC 4648 §5): URL-safe alphabet (`-` `_`) and no padding.
    static func base64URLDecode(_ s: String) -> Data? {
        var v = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let padding = v.count % 4
        if padding > 0 { v += String(repeating: "=", count: 4 - padding) }
        return Data(base64Encoded: v)
    }

    // MARK: - Helpers

    /// JWT `exp` is normally a number but spec allows numeric strings; handle both.
    private static func extractExp(_ claims: [String: Any]) -> TimeInterval {
        if let n = claims["exp"] as? Double { return n }
        if let n = claims["exp"] as? Int { return TimeInterval(n) }
        if let s = claims["exp"] as? String, let n = Double(s) { return n }
        return 0
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Raw auth.json shape

/// Direct mapping of the JSON in `~/.codex/auth.json`. Internal so tests can
/// build fixtures without writing real files.
struct RawAuthFile: Decodable, Sendable {
    let authMode: String?
    let tokens: RawAuthTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }

    struct RawAuthTokens: Decodable, Sendable {
        let accessToken: String?
        let refreshToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }
    }
}
