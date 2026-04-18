import Foundation
import Darwin  // utsname / uname for User-Agent parity with pi-ai

/// ChatGPT-backed Codex chat client. Mirrors pi-ai's
/// `openai-codex-responses` provider: same URL, same headers (down to the
/// `originator: pi` and `pi (Darwin ...)` User-Agent), same JSON body.
///
/// Entry point used by `AIService.send` when a slot's `providerID` is
/// `"openai-codex"`. Single-actor serialization keeps token refresh +
/// request-retry logic simple.
actor CodexBackend {
    static let shared = CodexBackend()

    private let urlSession: URLSession
    private let tokenStore: CodexTokenStore
    /// UUID generated once per CodexBackend lifetime, reused as HTTP
    /// `session_id` header AND body `prompt_cache_key` so consecutive
    /// requests hit OpenAI's prompt cache.
    private let sessionId: String
    private let userAgent: String

    init(
        urlSession: URLSession = .shared,
        tokenStore: CodexTokenStore = .shared,
        sessionIdOverride: String? = nil
    ) {
        self.urlSession = urlSession
        self.tokenStore = tokenStore
        self.sessionId = sessionIdOverride ?? UUID().uuidString
        self.userAgent = Self.buildUserAgent()
    }

    // MARK: - Public

    /// One chat turn → final assembled text. Retries once on HTTP 401 after
    /// forcing a fresh token read + refresh.
    func complete(system: String, user: String, model: String) async throws -> String {
        let (access, accountId) = try await tokenStore.validToken()
        do {
            return try await send(
                system: system, user: user, model: model,
                accessToken: access, accountId: accountId
            )
        } catch CodexError.authExpired {
            let (retryAccess, retryAccount) = try await tokenStore.refreshAfter401()
            return try await send(
                system: system, user: user, model: model,
                accessToken: retryAccess, accountId: retryAccount
            )
        }
    }

    // MARK: - Request

    private func send(
        system: String,
        user: String,
        model: String,
        accessToken: String,
        accountId: String
    ) async throws -> String {
        guard let url = URL(string: CodexConstants.backendURL) else {
            throw CodexError.backendError("invalid backend URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120

        // Headers — order/casing chosen to match pi-ai's buildSSEHeaders
        // exactly. URLSession normalizes casing on the wire but the
        // overall set is what matters.
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("pi", forHTTPHeaderField: "originator")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(sessionId, forHTTPHeaderField: "session_id")

        req.httpBody = try Self.buildRequestBody(
            system: system, user: user, model: model, sessionId: sessionId
        )

        let (bytes, response) = try await urlSession.bytes(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw CodexError.backendError("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return try await parseSSE(bytes: bytes)
        case 401:
            // Signal retry path; outer `complete` catches this.
            throw CodexError.authExpired
        case 429:
            throw CodexError.usageLimitReached
        default:
            let errBody = (try? await collectErrorBody(bytes)) ?? ""
            throw CodexError.backendError("HTTP \(http.statusCode): \(errBody)")
        }
    }

    /// Exact body shape from pi-ai `buildRequestBody`. Kept as a static so
    /// tests can assert against it without going through the actor.
    static func buildRequestBody(
        system: String,
        user: String,
        model: String,
        sessionId: String
    ) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": system,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": user]
                    ]
                ]
            ],
            "text": ["verbosity": "medium"],
            "include": ["reasoning.encrypted_content"],
            "prompt_cache_key": sessionId,
            "tool_choice": "auto",
            "parallel_tool_calls": true
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - SSE

    /// Parse the Responses API event stream. Only cares about
    /// `response.output_text.delta` (append), `response.completed` (done),
    /// and `response.failed` / `error` (throw). Other events ignored.
    private func parseSSE(bytes: URLSession.AsyncBytes) async throws -> String {
        var output = ""
        for try await line in bytes.lines {
            guard let payload = sseDataPayload(line) else { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let obj = parsed as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "response.output_text.delta":
                if let delta = obj["delta"] as? String {
                    output.append(delta)
                }
            case "response.completed", "response.done", "response.incomplete":
                return output
            case "response.failed":
                let msg = ((obj["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                throw CodexError.responseFailed(msg ?? "response failed")
            case "error":
                let msg = (obj["message"] as? String) ?? (obj["code"] as? String)
                throw CodexError.responseFailed(msg ?? "stream error")
            default:
                continue
            }
        }
        return output
    }

    /// Extract the payload from an SSE `data: ...` line. Returns nil for
    /// comments, `event:` / `id:` fields, and blank lines.
    private nonisolated func sseDataPayload(_ line: String) -> String? {
        if line.hasPrefix("data: ") { return String(line.dropFirst(6)) }
        if line.hasPrefix("data:") { return String(line.dropFirst(5)) }
        return nil
    }

    private func collectErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 16 * 1024 { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - User-Agent

    /// `pi (Darwin 25.3.0; arm64)` — bytewise identical to pi-ai's output
    /// on the same host. Uses POSIX `uname(3)`.
    nonisolated private static func buildUserAgent() -> String {
        var uts = utsname()
        guard uname(&uts) == 0 else {
            return "\(CodexConstants.userAgentPrefix) (Darwin; arm64)"
        }
        let sysname = cStringField(&uts.sysname)
        let release = cStringField(&uts.release)
        let machine = cStringField(&uts.machine)
        return "\(CodexConstants.userAgentPrefix) (\(sysname) \(release); \(machine))"
    }

    /// Convert a `utsname` fixed-size C char field (imported as a tuple of
    /// CChar) into a String by rebinding memory and reading until the null
    /// terminator.
    nonisolated private static func cStringField<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
