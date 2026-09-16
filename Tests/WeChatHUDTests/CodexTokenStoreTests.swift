import XCTest
@testable import WeChatHUD

/// Token-store behavior: cache, refresh triggering, 401 re-read, single-flight.
final class CodexTokenStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Cold start / cache

    func testValidTokenUsesCachedAccessIfAuthJSONStillFresh() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: 3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // No network handler — refresh would fail. Test asserts we never refresh.
        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        let (access, accountId) = try await store.validToken()
        XCTAssertFalse(access.isEmpty)
        XCTAssertEqual(accountId, "act_test")
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 0,
                       "Fresh access token should not trigger refresh")
    }

    func testValidTokenRefreshesWhenAuthJSONAccessExpired() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_refreshed"]
        ])
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": newJWT,
                "refresh_token": "r2",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        let (access, accountId) = try await store.validToken()
        XCTAssertEqual(access, newJWT)
        XCTAssertEqual(accountId, "act_refreshed")
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    // MARK: - Refresh wire format (fingerprint parity)

    func testRefreshRequestMatchesPiAIWireFormat() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "REFRESH_XYZ")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": newJWT,
                "refresh_token": "r_new",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        _ = try await store.validToken()

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let bodyString = try XCTUnwrap(req.httpBodyString)
        XCTAssertTrue(bodyString.contains("grant_type=refresh_token"), "body: \(bodyString)")
        XCTAssertTrue(bodyString.contains("refresh_token=REFRESH_XYZ"), "body: \(bodyString)")
        XCTAssertTrue(bodyString.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"), "body: \(bodyString)")
    }

    // MARK: - 401 recovery

    /// When this process rotated the refresh token itself, a later forced
    /// re-read must not fall back to the older token still sitting in
    /// auth.json: the server invalidated that one when it issued the new one,
    /// and using it would fail (and could clobber the only live token).
    func testRotatedTokenIsPreferredOverTheStaleFileToken() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r_file")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": firstJWT,
                "refresh_token": "r_rotated",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        // Our own refresh rotates r_file → r_rotated.
        _ = try await store.validToken()
        MockURLProtocol.capturedRequests.removeAll()

        let secondJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let bodyText = req.httpBodyString ?? ""
            XCTAssertTrue(
                bodyText.contains("refresh_token=r_rotated"),
                "the rotated token must be tried first, body: \(bodyText)"
            )
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": secondJWT,
                "refresh_token": "r_rotated_2",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let (access, _) = try await store.refreshAfter401()
        XCTAssertEqual(access, secondJWT)
    }

    func testRefreshCandidatesPreferTheFresherToken() {
        XCTAssertEqual(
            CodexTokenStore.refreshCandidates(inMemory: "r_new", fromFile: "r_old", inMemoryWasRotated: true),
            ["r_new", "r_old"]
        )
        // Not rotated by us → the file may have been refreshed by codex CLI.
        XCTAssertEqual(
            CodexTokenStore.refreshCandidates(inMemory: "r1", fromFile: "r2", inMemoryWasRotated: false),
            ["r2", "r1"]
        )
        XCTAssertEqual(
            CodexTokenStore.refreshCandidates(inMemory: "same", fromFile: "same", inMemoryWasRotated: true),
            ["same"]
        )
        XCTAssertEqual(
            CodexTokenStore.refreshCandidates(inMemory: nil, fromFile: "r_only", inMemoryWasRotated: false),
            ["r_only"]
        )
        XCTAssertTrue(
            CodexTokenStore.refreshCandidates(inMemory: nil, fromFile: nil, inMemoryWasRotated: false).isEmpty
        )
    }

    func testRefreshAfter401ForcesReReadOfAuthJSON() async throws {
        // First auth.json has an old refresh token; after 401, we rewrite the file
        // with a new refresh token and expect the next refresh to use the new one.
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: 3600, refreshToken: "r_first")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        // Seed the cache with the first-run token.
        _ = try await store.validToken()

        // Simulate codex CLI rotating the file while WeChatHUD was running.
        try JSONSerialization.data(
            withJSONObject: CodexTestSupport.makeAuthJSON(
                expOffset: -3600,  // force refresh
                refreshToken: "r_second"
            ),
            options: [.sortedKeys]
        ).write(to: dir.appendingPathComponent("auth.json"))

        let rotatedJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let bodyStr = req.httpBodyString ?? ""
            XCTAssertTrue(bodyStr.contains("refresh_token=r_second"),
                          "refreshAfter401 should use the rotated refresh_token, body: \(bodyStr)")
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": rotatedJWT,
                "refresh_token": "r_third",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let (access, _) = try await store.refreshAfter401()
        XCTAssertEqual(access, rotatedJWT)
    }

    // MARK: - Concurrent single-flight

    func testConcurrentValidTokenCallsCoalesceIntoOneRefresh() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            // Inject a small delay so concurrent callers actually race.
            Thread.sleep(forTimeInterval: 0.05)
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": newJWT,
                "refresh_token": "r2",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await store.validToken() }
            }
            try await group.waitForAll()
        }

        // Serialized refresh: exactly one network call, even with 8 racers.
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    // MARK: - Rotated-token persistence (R5)

    func testRotatedRefreshTokenPersistsAcrossStoreInstances() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistedURL = dir.appendingPathComponent("persisted-tokens.json")

        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": newJWT,
                "refresh_token": "r2",   // server rotated the refresh token
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: persistedURL
        )
        _ = try await store.validToken()

        // The rotated token must be on disk, owner-only.
        let attrs = try FileManager.default.attributesOfItem(atPath: persistedURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: persistedURL)
        ) as? [String: Any]
        XCTAssertEqual(persisted?["refreshToken"] as? String, "r2")

        // A NEW store instance (post-restart) must seed from the persisted
        // file, not the stale auth.json — no network needed since the
        // persisted access token is still fresh.
        MockURLProtocol.handler = { _ in
            XCTFail("fresh persisted access token must not refresh")
            return (HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, [Data()])
        }
        let store2 = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: persistedURL
        )
        let (access, accountId) = try await store2.validToken()
        XCTAssertEqual(access, newJWT)
        XCTAssertEqual(accountId, "act_test")
    }

    /// The restart-with-expired-access path: persisted holds our rotated r2
    /// but its access token is long dead; auth.json still carries the
    /// pre-rotation r1. The store must refresh with r2 — adopting r1 was the
    /// bug (refreshTokenWasRotated was only marked on the fresh-access early
    /// return, so the stale file token clobbered the live persisted one).
    func testRestartWithExpiredPersistedAccessRefreshesWithPersistedToken() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistedURL = dir.appendingPathComponent("persisted-tokens.json")

        let expiredJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 - 7200,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        let persisted: [String: Any] = [
            "accessToken": expiredJWT,
            // CodexPersistedTokens decodes Date via JSONDecoder's default —
            // timeIntervalSinceReferenceDate (2001 epoch), not Unix time.
            "accessExpiresAt": Date(timeIntervalSinceNow: -3600).timeIntervalSinceReferenceDate,
            "refreshToken": "r2",
            "accountId": "act_test",
            "email": "me@example.com"
        ]
        try JSONSerialization.data(withJSONObject: persisted)
            .write(to: persistedURL, options: .atomic)

        var seenRefreshTokens: [String] = []
        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let body = req.httpBodyString ?? ""
            if let match = body.range(of: "refresh_token=([^&]+)", options: .regularExpression) {
                seenRefreshTokens.append(String(body[match].dropFirst("refresh_token=".count)))
            }
            if body.contains("refresh_token=r2") {
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let payload: [String: Any] = [
                    "access_token": newJWT, "refresh_token": "r3", "expires_in": 3600
                ]
                return (response, [try JSONSerialization.data(withJSONObject: payload)])
            }
            let response = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, [Data(#"{"error":"invalid_grant"}"#.utf8)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: persistedURL
        )
        let (access, _) = try await store.validToken()
        XCTAssertEqual(access, newJWT)
        XCTAssertTrue(seenRefreshTokens.contains("r2"),
                      "the persisted rotated token must be tried, got \(seenRefreshTokens)")
        // r1 is server-dead — it may appear as a fallback candidate only
        // after r2 fails; it must never be preferred.
        if let first = seenRefreshTokens.first {
            XCTAssertEqual(first, "r2", "the stale auth.json token must not be tried first")
        }
    }

    func testRefreshAfter401DoesNotReadoptRevokedAccessToken() async throws {
        // auth.json's access token is locally fresh but server-revoked.
        // refreshAfter401 must force a REAL refresh — re-adopting it loops
        // 401 → adopt → 401 until its exp runs out.
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: 3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistedURL = dir.appendingPathComponent("persisted-tokens.json")

        // Seed a store so it holds an access token + a file refresh token.
        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: persistedURL
        )
        _ = try await store.validToken()   // adopts auth.json's access token
        let before = MockURLProtocol.capturedRequests.count

        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": newJWT,
                "refresh_token": "r2",
                "expires_in": 3600
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let (access, _) = try await store.refreshAfter401()
        XCTAssertEqual(access, newJWT,
                       "401 must force a real refresh, not re-adopt the revoked token")
        XCTAssertGreaterThan(MockURLProtocol.capturedRequests.count, before,
                             "a refresh call must have hit the network")
    }

    func testRefreshResponseWithoutRefreshTokenReusesOld() async throws {
        // RFC 6749 §6 — the server MAY omit refresh_token; decoding must not
        // fail and the existing token stays live.
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let newJWT = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "act_test"]
        ])
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: [String: Any] = [
                "access_token": newJWT,
                "expires_in": 3600     // no refresh_token field at all
            ]
            return (response, [try JSONSerialization.data(withJSONObject: body)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        let (access, _) = try await store.validToken()
        XCTAssertEqual(access, newJWT)
    }

    func testOAuthErrorBodyIsNotEmbeddedInError() async throws {
        let dir = try CodexTestSupport.writeAuthJSON(
            CodexTestSupport.makeAuthJSON(expOffset: -3600, refreshToken: "r1")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":"invalid_grant","error_description":"echoes-r1-secret"}"#
            return (response, [Data(body.utf8)])
        }

        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] },
            persistedTokensURL: dir.appendingPathComponent("persisted-tokens.json")
        )
        do {
            _ = try await store.validToken()
            XCTFail("expected refresh failure")
        } catch {
            let text = String(describing: error)
            XCTAssertFalse(text.contains("echoes-r1-secret"),
                           "OAuth error body must not leak into surfaced errors")
        }
    }
}

// MARK: - URLRequest body helper

private extension URLRequest {
    /// URLProtocol loses `httpBody` when converting to stream form. Try both.
    var httpBodyString: String? {
        if let data = httpBody { return String(data: data, encoding: .utf8) }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}
