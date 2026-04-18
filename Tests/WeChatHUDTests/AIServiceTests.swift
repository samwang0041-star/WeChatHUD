import XCTest
@testable import WeChatHUD

/// Locks in `AIService.complete(system:user:options:)` routing behavior
/// ahead of the downstream migration: `openai-codex` slots must go through
/// `CodexBackend` (never `/chat/completions`), and OpenAI-compatible slots
/// must build a `/chat/completions` request that honors `CompleteOptions`.
final class AIServiceCompleteOptionsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLRequestRecorder.install()
    }

    override func tearDown() {
        URLRequestRecorder.uninstall()
        super.tearDown()
    }

    // MARK: - Codex slot

    /// A Codex slot must never hit the OpenAI-compat `/chat/completions`
    /// endpoint — the call is routed through `CodexBackend`, which either
    /// fails fast on missing `~/.codex/auth.json` or talks to
    /// `chatgpt.com/backend-api/codex/responses`.
    func testCodexSlotSkipsOpenAIPath() async throws {
        var cfg = AIConfig()
        cfg.cloudProvider = AIProviderSlot(
            providerID: "openai-codex",
            baseURL: "",
            model: "gpt-5.4",
            apiKey: ""
        )
        cfg.activeMode = .cloud

        let service = AIService(config: cfg)
        // Call may fail (no real codex token in tests) but what matters is
        // that no URLRequest was issued to `/chat/completions`.
        _ = try? await service.complete(
            system: "sys",
            user: "hi",
            options: .default
        )

        let hitOpenAI = URLRequestRecorder.capturedRequests.contains { req in
            req.url?.absoluteString.contains("/chat/completions") ?? false
        }
        XCTAssertFalse(
            hitOpenAI,
            "Codex slot must not issue an OpenAI-compat /chat/completions request"
        )
    }

    // MARK: - OpenAI-compat slot

    /// The OpenAI-compat path must build a POST to `/chat/completions`,
    /// carry the bearer token, and fold `CompleteOptions` into the URLRequest
    /// (timeout) and body (model override, temperature, max_tokens).
    func testOpenAISlotBuildsRequestWithOptions() async throws {
        var cfg = AIConfig()
        cfg.cloudProvider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "test-model",
            apiKey: "sk-test"
        )
        cfg.activeMode = .cloud
        cfg.temperature = 0.5
        cfg.maxTokens = 100

        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: "ok")

        let service = AIService(config: cfg)
        let out = try await service.complete(
            system: "sys",
            user: "hi",
            options: CompleteOptions(
                timeout: 10,
                temperature: 0.1,
                maxTokens: 42,
                modelOverride: "override-model"
            )
        )
        XCTAssertEqual(out, "ok")

        let req = try XCTUnwrap(URLRequestRecorder.capturedRequests.first)
        let url = try XCTUnwrap(req.url?.absoluteString)
        XCTAssertTrue(
            url.hasSuffix("/chat/completions"),
            "expected URL to end with /chat/completions, got \(url)"
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.timeoutInterval, 10)

        // URLProtocol often exposes httpBodyStream instead of httpBody; read
        // from whichever is populated.
        let bodyData: Data = {
            if let d = req.httpBody { return d }
            if let s = req.httpBodyStream {
                s.open()
                defer { s.close() }
                var buf = Data()
                let chunk = 4096
                var tmp = [UInt8](repeating: 0, count: chunk)
                while s.hasBytesAvailable {
                    let n = s.read(&tmp, maxLength: chunk)
                    if n <= 0 { break }
                    buf.append(tmp, count: n)
                }
                return buf
            }
            return Data()
        }()

        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(parsed["model"] as? String, "override-model")

        // Numeric JSON values come back as NSNumber / Double depending on
        // platform — coerce via Double to make the comparison robust.
        let temp = (parsed["temperature"] as? Double)
            ?? Double(parsed["temperature"] as? Int ?? -1)
        XCTAssertEqual(temp, 0.1, accuracy: 1e-9)
        let maxTok = (parsed["max_tokens"] as? Int)
            ?? Int((parsed["max_tokens"] as? Double) ?? -1)
        XCTAssertEqual(maxTok, 42)
    }
}
