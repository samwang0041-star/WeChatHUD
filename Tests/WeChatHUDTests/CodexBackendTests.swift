import XCTest
@testable import WeChatHUD

/// Tests CodexBackend's HTTP fingerprint (URL/headers/body matches pi-ai
/// byte-for-byte where feasible) plus SSE response assembly and error paths.
final class CodexBackendTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Body shape (pi-ai parity)

    func testBuildRequestBodyMatchesPiAIFieldSet() throws {
        let data = try CodexBackend.buildRequestBody(
            system: "You are helpful.",
            user: "Hello",
            model: "gpt-5.4",
            sessionId: "session-xyz"
        )
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let body = try XCTUnwrap(obj)

        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "You are helpful.")
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(body["prompt_cache_key"] as? String, "session-xyz")

        let text = body["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "medium")

        let include = body["include"] as? [String]
        XCTAssertEqual(include, ["reasoning.encrypted_content"])

        let input = body["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 1)
        XCTAssertEqual(input?.first?["type"] as? String, "message")
        XCTAssertEqual(input?.first?["role"] as? String, "user")
        let content = input?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "input_text")
        XCTAssertEqual(content?.first?["text"] as? String, "Hello")
    }

    // MARK: - Header fingerprint

    func testRequestHeadersMatchOpenClawFingerprint() async throws {
        let (store, expectedAccess) = await makeStoreWithValidToken(accountId: "act_42")

        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
            return (response, [body.data(using: .utf8)!])
        }

        let backend = CodexBackend(
            urlSession: CodexTestSupport.mockSession(),
            tokenStore: store,
            sessionIdOverride: "sess-test-001"
        )
        _ = try await backend.complete(system: "sys", user: "usr", model: "gpt-5.4")

        let req = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(req.httpMethod, "POST")

        let h = { req.value(forHTTPHeaderField: $0) }
        XCTAssertEqual(h("Authorization"), "Bearer \(expectedAccess)")
        XCTAssertEqual(h("chatgpt-account-id"), "act_42")
        XCTAssertEqual(h("originator"), "pi")
        XCTAssertEqual(h("OpenAI-Beta"), "responses=experimental")
        // URLSession lowercases standard header names; tolerate either case.
        XCTAssertEqual(h("accept") ?? h("Accept"), "text/event-stream")
        XCTAssertEqual(h("content-type") ?? h("Content-Type"), "application/json")
        XCTAssertEqual(h("session_id"), "sess-test-001")

        let ua = try XCTUnwrap(h("User-Agent"))
        XCTAssertTrue(ua.hasPrefix("pi ("), "User-Agent must match 'pi (...)' format, got: \(ua)")
        XCTAssertTrue(ua.contains("Darwin") || ua.contains(";"), "UA should contain platform info: \(ua)")
    }

    // MARK: - SSE parsing

    func testSSEParsingAccumulatesDeltasAndHaltsOnCompleted() async throws {
        let (store, _) = await makeStoreWithValidToken()
        let sse = """
        event: response.created
        data: {"type":"response.created"}

        data: {"type":"response.output_text.delta","delta":"Hello"}

        data: {"type":"response.output_text.delta","delta":", world"}

        data: {"type":"response.output_text.delta","delta":"!"}

        data: {"type":"response.completed"}

        """
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, [sse.data(using: .utf8)!])
        }

        let backend = CodexBackend(
            urlSession: CodexTestSupport.mockSession(),
            tokenStore: store
        )
        let out = try await backend.complete(system: "", user: "", model: "gpt-5.4")
        XCTAssertEqual(out, "Hello, world!")
    }

    func testSSEPropagatesResponseFailedEvent() async throws {
        let (store, _) = await makeStoreWithValidToken()
        let sse = """
        data: {"type":"response.failed","response":{"error":{"message":"rate limited internally"}}}

        """
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, [sse.data(using: .utf8)!])
        }

        let backend = CodexBackend(
            urlSession: CodexTestSupport.mockSession(),
            tokenStore: store
        )
        do {
            _ = try await backend.complete(system: "", user: "", model: "gpt-5.4")
            XCTFail("Expected responseFailed error")
        } catch CodexError.responseFailed(let msg) {
            XCTAssertTrue(msg.contains("rate limited"), "got: \(msg)")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - HTTP status handling

    func testHTTP429MapsToUsageLimit() async throws {
        let (store, _) = await makeStoreWithValidToken()
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (response, [Data("{\"error\":\"usage limit\"}".utf8)])
        }

        let backend = CodexBackend(
            urlSession: CodexTestSupport.mockSession(),
            tokenStore: store
        )
        do {
            _ = try await backend.complete(system: "", user: "", model: "gpt-5.4")
            XCTFail("Expected usageLimitReached")
        } catch CodexError.usageLimitReached {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testHTTP5xxMapsToBackendError() async throws {
        let (store, _) = await makeStoreWithValidToken()
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, [Data("{\"error\":\"unavailable\"}".utf8)])
        }

        let backend = CodexBackend(
            urlSession: CodexTestSupport.mockSession(),
            tokenStore: store
        )
        do {
            _ = try await backend.complete(system: "", user: "", model: "gpt-5.4")
            XCTFail("Expected backendError")
        } catch CodexError.backendError(let msg) {
            XCTAssertTrue(msg.contains("503"), "got: \(msg)")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    /// Build a token store whose cached access token is a real (decodable) JWT
    /// bound to `accountId`. Returns the store and the exact JWT string so tests
    /// can assert `Authorization: Bearer <jwt>`.
    private func makeStoreWithValidToken(accountId: String = "act_test") async -> (CodexTokenStore, String) {
        let jwt = CodexTestSupport.makeJWT(payload: [
            "exp": Date().timeIntervalSince1970 + 3600,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountId]
        ])
        var json = CodexTestSupport.makeAuthJSON(accountId: accountId, expOffset: 3600)
        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = jwt
        json["tokens"] = tokens

        let dir: URL
        do {
            dir = try CodexTestSupport.writeAuthJSON(json)
        } catch {
            XCTFail("Failed to prep auth.json: \(error)")
            return (CodexTokenStore(), jwt)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = CodexTokenStore(
            urlSession: CodexTestSupport.mockSession(),
            envProvider: { ["CODEX_HOME": dir.path] }
        )
        return (store, jwt)
    }
}
