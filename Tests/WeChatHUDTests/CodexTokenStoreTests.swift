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
            envProvider: { ["CODEX_HOME": dir.path] }
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
            envProvider: { ["CODEX_HOME": dir.path] }
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
            envProvider: { ["CODEX_HOME": dir.path] }
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
            envProvider: { ["CODEX_HOME": dir.path] }
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
            envProvider: { ["CODEX_HOME": dir.path] }
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
            envProvider: { ["CODEX_HOME": dir.path] }
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
