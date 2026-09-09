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
        cfg.provider = AIProviderSlot(
            providerID: "openai-codex",
            baseURL: "",
            model: "gpt-5.4",
            apiKey: ""
        )

        let service = AIService(config: cfg)
        // Call may fail (no real codex token in tests) but what matters is
        // that no URLRequest was issued to `/chat/completions`.
        _ = try? await service.complete(
            system: "sys",
            user: "hi",
            options: .default
        )

        // The call will fail (tests may or may not have ~/.codex/auth.json) but
        // under no circumstances should /chat/completions be hit — that's the
        // OpenAI-compat path and this is a Codex slot.
        let hitOpenAIPath = URLRequestRecorder.capturedRequests.contains { req in
            req.url?.absoluteString.contains("/chat/completions") ?? false
        }
        XCTAssertFalse(hitOpenAIPath, "Codex slot must not fall through to /chat/completions")

        // If anything was captured at all, it must be a Codex-side host. This
        // positive check is what catches "service bypasses AIService" regressions
        // — without it the negative assertion above would be vacuously true when
        // auth isn't configured on the runner.
        if let first = URLRequestRecorder.capturedRequests.first,
           let url = first.url?.absoluteString {
            XCTAssertTrue(
                url.contains("chatgpt.com/backend-api") || url.contains("auth.openai.com"),
                "Codex routing should only hit Codex-side hosts, got \(url)"
            )
        }
    }

    // MARK: - OpenAI-compat slot

    /// The OpenAI-compat path must build a POST to `/chat/completions`,
    /// carry the bearer token, and fold `CompleteOptions` into the URLRequest
    /// (timeout) and body (model override, temperature, max_tokens).
    func testOpenAISlotBuildsRequestWithOptions() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "test-model",
            apiKey: "sk-test"
        )
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

    func testCompletionMetadataUsesProviderReturnedModel() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "requested-model",
            apiKey: "sk-test"
        )

        let body = try JSONSerialization.data(withJSONObject: [
            "model": "actual-provider-model",
            "choices": [[
                "finish_reason": "stop",
                "message": ["role": "assistant", "content": "ok"]
            ]]
        ])
        URLRequestRecorder.stubbedResponse = (
            body,
            HTTPURLResponse(
                url: URL(string: "http://localhost:9999/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )

        let service = AIService(config: cfg)
        let result = try await service.completeWithMetadata(
            system: "sys",
            user: "hi",
            options: .default
        )

        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(result.model, "actual-provider-model")
    }

    /// Kimi Coding follows the same request shape as local Hermes: no
    /// `temperature`, no Qwen-style `enable_thinking`, and thinking controlled
    /// through Kimi's `thinking.type` field.
    func testKimiCodingSlotUsesHermesStableRequestShape() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "kimicode",
            baseURL: "https://api.kimi.com/coding/v1",
            model: "kimi-for-coding",
            apiKey: "sk-kimi-test"
        )

        let body = try JSONSerialization.data(withJSONObject: [
            "model": "kimi-for-coding",
            "choices": [[
                "finish_reason": "stop",
                "message": [
                    "role": "assistant",
                    "content": #"{"ok":true}"#,
                    "reasoning_content": "server thinking that should be ignored"
                ]
            ]]
        ])
        URLRequestRecorder.stubbedResponse = (
            body,
            HTTPURLResponse(
                url: URL(string: "https://api.kimi.com/coding/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )

        let service = AIService(config: cfg)
        let out = try await service.complete(
            system: "sys",
            user: "hi",
            options: CompleteOptions(timeout: 10, temperature: 0.1, maxTokens: 256, responseFormatJSON: true)
        )
        XCTAssertEqual(out, #"{"ok":true}"#)

        let req = try XCTUnwrap(URLRequestRecorder.capturedRequests.first)
        let url = try XCTUnwrap(req.url?.absoluteString)
        XCTAssertEqual(url, "https://api.kimi.com/coding/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "claude-code/0.1.0")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-kimi-test")
        XCTAssertEqual(req.timeoutInterval, 10)

        let parsed = try requestBodyJSON(req)
        XCTAssertEqual(parsed["model"] as? String, "kimi-for-coding")
        XCTAssertNil(parsed["temperature"], "Kimi/Moonshot temperature is server-managed")
        XCTAssertNil(parsed["enable_thinking"], "Kimi must not receive Qwen-style enable_thinking")
        XCTAssertEqual((parsed["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(parsed["reasoning_effort"], "Disabled thinking must not send reasoning_effort")
        XCTAssertEqual((parsed["response_format"] as? [String: Any])?["type"] as? String, "json_object")

        let messages = try XCTUnwrap(parsed["messages"] as? [[String: Any]])
        let systemMsg = try XCTUnwrap(messages.first { $0["role"] as? String == "system" })
        let systemContent = try XCTUnwrap(systemMsg["content"] as? String)
        XCTAssertTrue(
            systemContent.contains("不要进入 thinking 模式"),
            "System prompt must carry the global anti-thinking suffix, got: \(systemContent)"
        )
    }

    func testKimiThinkingRequestUsesHermesThinkingParameters() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "kimicode",
            baseURL: "https://api.kimi.com/coding/v1",
            model: "kimi-for-coding",
            apiKey: "sk-kimi-test"
        )

        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: "ok")

        let service = AIService(config: cfg)
        _ = try await service.complete(
            system: "sys",
            user: "hi",
            options: CompleteOptions(timeout: 10, temperature: 0.1, maxTokens: 256, thinkingEnabled: true)
        )

        let req = try XCTUnwrap(URLRequestRecorder.capturedRequests.first)
        let parsed = try requestBodyJSON(req)
        XCTAssertNil(parsed["temperature"], "Kimi/Moonshot temperature is server-managed")
        XCTAssertNil(parsed["enable_thinking"], "Kimi must not receive Qwen-style enable_thinking")
        XCTAssertEqual((parsed["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(parsed["reasoning_effort"] as? String, "medium")

        let messages = try XCTUnwrap(parsed["messages"] as? [[String: Any]])
        let systemMsg = try XCTUnwrap(messages.first { $0["role"] as? String == "system" })
        let systemContent = try XCTUnwrap(systemMsg["content"] as? String)
        XCTAssertFalse(systemContent.contains("不要进入 thinking 模式"))
    }

    func testDeepSeekJSONRequestDisablesThinkingAndUsesResponseFormat() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "sk-deepseek-test"
        )
        cfg.thinkingEnabled = true

        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: #"{"ok":true}"#)

        let service = AIService(config: cfg)
        _ = try await service.complete(
            system: "sys",
            user: "hi",
            options: CompleteOptions(timeout: 10, temperature: 0.1, maxTokens: 256, responseFormatJSON: true)
        )

        let req = try XCTUnwrap(URLRequestRecorder.capturedRequests.first)
        let parsed = try requestBodyJSON(req)
        XCTAssertNil(parsed["enable_thinking"], "DeepSeek must not receive Qwen/Kimi enable_thinking")
        XCTAssertEqual((parsed["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(parsed["reasoning_effort"], "JSON mode defaults to thinking disabled unless explicitly overridden")
        XCTAssertEqual((parsed["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual(parsed["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-deepseek-test")
    }

    func testDeepSeekThinkingRequestUsesOfficialThinkingParameters() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "sk-deepseek-test"
        )

        URLRequestRecorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: "ok")

        let service = AIService(config: cfg)
        _ = try await service.complete(
            system: "sys",
            user: "hi",
            options: CompleteOptions(timeout: 10, temperature: 0.1, maxTokens: 256, thinkingEnabled: true)
        )

        let req = try XCTUnwrap(URLRequestRecorder.capturedRequests.first)
        let parsed = try requestBodyJSON(req)
        XCTAssertEqual((parsed["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(parsed["reasoning_effort"] as? String, "high")
        let maxTok = (parsed["max_tokens"] as? Int)
            ?? Int((parsed["max_tokens"] as? Double) ?? -1)
        XCTAssertEqual(maxTok, 2048, "DeepSeek thinking should get the same safe output floor as Kimi")
    }

    func testEmptyCodexModelDoesNotFallbackToHardcodedModel() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "openai-codex",
            baseURL: "",
            model: "",
            apiKey: ""
        )

        let service = AIService(config: cfg)

        do {
            _ = try await service.complete(system: "sys", user: "hi", options: .default)
            XCTFail("Expected empty Codex model to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AI model is empty"))
        }
        XCTAssertTrue(URLRequestRecorder.capturedRequests.isEmpty)
    }

    func testLengthFinishReasonReportsTruncation() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "sk-deepseek-test"
        )

        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "finish_reason": "length",
                "message": [
                    "role": "assistant",
                    "content": NSNull(),
                    "reasoning_content": "reasoning only"
                ]
            ]]
        ])
        URLRequestRecorder.stubbedResponse = (
            body,
            HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )

        let service = AIService(config: cfg)
        do {
            _ = try await service.complete(system: "sys", user: "hi", options: .default)
            XCTFail("Expected truncation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("finish_reason=length"))
        }
    }

    func testLengthFinishReasonWithPartialContentReportsTruncation() async throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "sk-deepseek-test"
        )

        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "finish_reason": "length",
                "message": [
                    "role": "assistant",
                    "content": "{\"partial\":true"
                ]
            ]]
        ])
        URLRequestRecorder.stubbedResponse = (
            body,
            HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )

        let service = AIService(config: cfg)
        do {
            _ = try await service.complete(system: "sys", user: "hi", options: .default)
            XCTFail("Expected partial truncation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("finish_reason=length"))
        }
    }

    private func requestBodyJSON(_ req: URLRequest) throws -> [String: Any] {
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
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    }
}
