# AI Transport Unification — Codex Works Everywhere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route all 16 AI services through `AIService.complete(...)` so the Codex (ChatGPT OAuth) provider works for every AI feature, not just the two paths that currently use `AIService`.

**Architecture:** Extend `AIService` with a general-purpose `complete(system:user:options:)` method that either (a) forwards to `CodexBackend` when the active slot's `providerID == "openai-codex"`, or (b) builds the existing OpenAI-compatible `/chat/completions` request. Each of the 16 services drops its private `call()` / `callModel()` HTTP method and calls `aiService.complete(...)` instead. Per-service state (timeout, system prompt, temperature, max tokens, audit role) becomes a `CompleteOptions` value passed per call. `AIAudit` writing stays inside each service so the `role` field keeps its meaning.

**Tech Stack:** Swift 6 strict concurrency, URLSession, swift-testing (XCTest where already used).

---

## Background

**Root cause investigation** (from 2026-04-18 session):

- `AIService.send()` at `Sources/WeChatHUD/Services/AIService.swift:62` is the only place that checks `slot.providerID == "openai-codex"` and routes to `CodexBackend`.
- `ChatAnalyzer`, `AIClassifier`, `AutoReplyGenerator`, and 13 other services build their own `URLRequest(url: "\(baseURL)/chat/completions")` — they never check the providerID, so when the user selects Codex:
  - `config.baseURL == ""` (Codex's URL is hardcoded in `CodexBackend`, intentionally empty in `AIProviderSlot`)
  - `normalizeURL("")` → `"http:///v1"`
  - The request fails immediately (invalid host)
  - The UI shows the generic `"分析失败，可能是 AI 服务超时"` fallback
- Currently only `ChatMonitor.swift:1249` (rolling summary) and `GroupContextBriefingService` actually support Codex.

**Services to migrate (16):**

ChatAnalyzer, AutopilotService, VIPAggregator, DiscussionTracker, ContextAnalyzer, CommitmentTracker, RecallAnalyzer, AutoReplyGenerator, AIWhitelistCategorizer, AIReplySuggester, AIInboxSummarizer, AIGroupCatchup, AIDailyRetrospector, AIClassifier, AIChatInsight, AIBriefingGenerator.

**Services that already go through AIService (no work needed):** `RelationshipInferrer`, `GroupContextBriefingService`, `StyleProfiler` (not in AI path).

---

## File Structure

**New:**
- None — everything extends existing files.

**Modified:**
- `Sources/WeChatHUD/Services/AIService.swift` — add `CompleteOptions`, rewrite `send()` to take options
- `Sources/WeChatHUD/Services/ChatMonitor.swift` — update service constructions + drop per-service `updateConfig` propagation
- `Sources/WeChatHUD/App/AppDelegate.swift` — no changes expected (already holds `aiService`)
- 16 service files — drop private `call()` / `callModel()`, inject `AIService`, wrap audit writes around `aiService.complete(...)`
- `Tests/WeChatHUDTests/AIServiceTests.swift` (create if missing) — cover both Codex and OpenAI paths

**Deleted:**
- Per-service `normalizeURL(_:)`, `stripThinking(_:)`, and private HTTP call methods (12+ duplicated copies).

---

## Phase 1: Unified Transport API

### Task 1: Add `CompleteOptions` struct and unified `complete(system:user:options:)` in AIService

**Files:**
- Modify: `Sources/WeChatHUD/Services/AIService.swift`

**Why this task:** Creates the single choke point that every service will call. After this task the old `complete(system:user:)` API remains (thin wrapper over the new one) so nothing else breaks yet.

- [ ] **Step 1: Add `CompleteOptions` struct above the `AIService` actor declaration**

```swift
/// Per-call knobs for `AIService.complete`. Every service that used to build
/// its own URLRequest now passes one of these so timeout / temperature /
/// system-side tweaks travel alongside the prompt.
///
/// Codex path ignores `temperature`, `maxTokens`, and `extraSystemSuffix` —
/// pi-ai's Responses API request body is fixed. OpenAI-compatible path honors
/// every field.
struct CompleteOptions {
    var timeout: TimeInterval = 120
    var temperature: Double? = nil   // nil → use AIConfig.temperature
    var maxTokens: Int? = nil        // nil → use AIConfig.maxTokens
    var modelOverride: String? = nil // nil → use slot.model
    /// Appended to the system prompt for non-Codex providers. Default carries
    /// the Qwen thinking-suppression hint — migrated services whose own
    /// system prompt already embeds a similar instruction MUST pass
    /// `extraSystemSuffix: nil` to avoid double-prompting.
    var extraSystemSuffix: String? = "\n\n不要进入 thinking 模式，不要输出 <think> 标签或思维过程。"
    /// When true, the request body includes `"enable_thinking": false`
    /// (suppresses Qwen-style thinking output). When false, the field is
    /// omitted — useful for providers that reject unknown keys. Default true
    /// matches prior behavior.
    var emitEnableThinkingFlag: Bool = true

    static let `default` = CompleteOptions()
}
```

- [ ] **Step 2: Replace `send(slot:system:user:)` in AIService.swift with a variant that accepts `CompleteOptions`**

Delete the existing `send` (lines ~58-123) and replace with:

```swift
private func send(
    slot: AIProviderSlot,
    system: String,
    user: String,
    options: CompleteOptions
) async throws -> String {
    if slot.providerID == "openai-codex" {
        let model = (options.modelOverride ?? slot.model)
            .trimmingCharacters(in: .whitespaces)
        let resolvedModel = model.isEmpty ? "gpt-5.4" : model
        return try await CodexBackend.shared.complete(
            system: system, user: user, model: resolvedModel
        )
    }

    let baseURL = normalizeURL(slot.baseURL)
    guard let url = URL(string: "\(baseURL)/chat/completions") else {
        throw AIError.invalidURL(slot.baseURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !slot.apiKey.isEmpty {
        request.setValue("Bearer \(slot.apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.timeoutInterval = options.timeout

    let effectiveSystem = system + (options.extraSystemSuffix ?? "")
    let model = options.modelOverride ?? slot.model

    var body: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": effectiveSystem],
            ["role": "user", "content": user]
        ],
        "temperature": options.temperature ?? config.temperature,
        "max_tokens": options.maxTokens ?? config.maxTokens,
        "stream": false
    ]
    if options.emitEnableThinkingFlag {
        body["enable_thinking"] = false
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw AIError.requestFailed("No HTTP response")
    }
    guard httpResponse.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AIError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String else {
        throw AIError.parseFailed("Cannot parse response")
    }

    return stripThinking(content)
}
```

- [ ] **Step 3: Add the new public `complete(system:user:options:)` entry point**

Add immediately after the existing `complete(system:user:)`:

```swift
/// Unified completion entry point. All services should call this instead
/// of building their own `/chat/completions` request. Routes to Codex when
/// the active slot is `openai-codex`, otherwise OpenAI-compatible.
///
/// `.auto` mode is preserved: primary slot is tried first and the fallback
/// slot takes over on failure.
func complete(
    system: String,
    user: String,
    options: CompleteOptions
) async throws -> String {
    let primary = config.primarySlot
    let fallback = config.fallbackSlot

    do {
        return try await send(slot: primary, system: system, user: user, options: options)
    } catch {
        if let fb = fallback, !fb.baseURL.isEmpty || fb.providerID == "openai-codex" {
            print("[WCHUD-AI] primary failed (\(error.localizedDescription)), trying fallback…")
            return try await send(slot: fb, system: system, user: user, options: options)
        }
        throw error
    }
}
```

- [ ] **Step 4: Rewrite the existing `complete(system:user:)` to delegate to the new one**

Replace the old body with:

```swift
func complete(system: String, user: String) async throws -> String {
    try await complete(system: system, user: user, options: .default)
}
```

- [ ] **Step 5: Update `testSlot` to use the new `send` signature**

```swift
func testSlot(_ slot: AIProviderSlot) async throws -> String {
    try await send(
        slot: slot,
        system: "Reply with OK.",
        user: "Test",
        options: .default
    )
}
```

- [ ] **Step 6: Build and run all existing tests**

Run: `swift build -c debug && swift test 2>&1 | tail -30`
Expected: build succeeds, all 350 tests still pass (no behavior change yet — only the existing callers use the default options).

- [ ] **Step 7: Commit**

```bash
git add Sources/WeChatHUD/Services/AIService.swift
git commit -m "feat(AIService): add CompleteOptions + unified complete(system:user:options:)

Prep for migrating the 16 services that currently bypass AIService. No behavior change — existing complete(system:user:) delegates to the new one with defaults."
```

---

### Task 2: Add `AIServiceTests` covering both the Codex and OpenAI-compat paths

**Files:**
- Create or Modify: `Tests/WeChatHUDTests/AIServiceTests.swift`

**Why this task:** Before rewiring 16 services, prove the new `complete(system:user:options:)` actually routes to Codex when the slot says so. Uses a fake `URLProtocol` so the test doesn't hit the network.

- [ ] **Step 1: Locate the existing AIService test file (if any)**

Run: `ls Tests/WeChatHUDTests/ | grep -i ai`

Expected: some files exist (e.g. `AIConfigTests.swift`, `AIClassifierTests.swift`). If a file named `AIServiceTests.swift` exists, extend it; otherwise create it.

- [ ] **Step 2: Write a failing test that asserts Codex routing fires for `openai-codex` slots**

Append to `Tests/WeChatHUDTests/AIServiceTests.swift`:

```swift
import Testing
@testable import WeChatHUD

@Suite("AIService.complete options routing")
struct AIServiceCompleteOptionsTests {

    @Test("openai-codex slot dispatches to CodexBackend path (no /chat/completions)")
    func codexSlotSkipsOpenAIPath() async throws {
        // Build a config whose primary slot is Codex. Even if we don't
        // actually reach ChatGPT in the test, the OpenAI path must not be
        // invoked (no URLRequest to /chat/completions).
        var cfg = AIConfig()
        cfg.cloudProvider = AIProviderSlot(
            providerID: "openai-codex",
            baseURL: "",
            model: "gpt-5.4",
            apiKey: ""
        )
        cfg.activeMode = .cloud

        let recorder = URLRequestRecorder.install()
        defer { recorder.uninstall() }

        let service = AIService(config: cfg)
        // The call will fail (no real codex token in tests) but what we
        // assert is that no URLRequest was issued to "/chat/completions".
        _ = try? await service.complete(
            system: "sys", user: "hi",
            options: .default
        )

        #expect(recorder.capturedRequests.allSatisfy { req in
            !(req.url?.absoluteString.contains("/chat/completions") ?? false)
        })
    }

    @Test("OpenAI-compat slot builds a /chat/completions request honoring CompleteOptions")
    func openAISlotBuildsRequestWithOptions() async throws {
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

        let recorder = URLRequestRecorder.install()
        recorder.stubbedResponse = URLRequestRecorder.makeChatCompletionsResponse(content: "ok")
        defer { recorder.uninstall() }

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
        #expect(out == "ok")

        let req = try #require(recorder.capturedRequests.first)
        let url = try #require(req.url?.absoluteString)
        #expect(url.hasSuffix("/chat/completions"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.timeoutInterval == 10)

        let body = try #require(req.httpBody)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect((parsed["model"] as? String) == "override-model")
        #expect((parsed["temperature"] as? Double) == 0.1)
        #expect((parsed["max_tokens"] as? Int) == 42)
    }
}
```

- [ ] **Step 3: Add a lightweight `URLRequestRecorder` helper if one doesn't exist**

If `URLRequestRecorder` isn't already in `Tests/WeChatHUDTests/Helpers/`, create `Tests/WeChatHUDTests/Helpers/URLRequestRecorder.swift`:

```swift
import Foundation

/// Installs a `URLProtocol` that captures every URLSession.shared request and
/// optionally stubs the response body. Used by AIService tests so we can
/// verify request shape without hitting the network.
final class URLRequestRecorder: URLProtocol {
    static var capturedRequests: [URLRequest] = []
    static var stubbedResponse: (Data, URLResponse)? = nil
    static var installed = false

    static func install() -> URLRequestRecorder.Type {
        capturedRequests = []
        stubbedResponse = nil
        URLProtocol.registerClass(URLRequestRecorder.self)
        installed = true
        return URLRequestRecorder.self
    }

    static func uninstall() {
        URLProtocol.unregisterClass(URLRequestRecorder.self)
        capturedRequests = []
        stubbedResponse = nil
        installed = false
    }

    static func makeChatCompletionsResponse(content: String) -> (Data, URLResponse) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["role": "assistant", "content": content]
            ]]
        ])
        let resp = HTTPURLResponse(
            url: URL(string: "http://test/chat/completions")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, resp)
    }

    override class func canInit(with request: URLRequest) -> Bool { installed }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        URLRequestRecorder.capturedRequests.append(request)
        if let (data, resp) = URLRequestRecorder.stubbedResponse {
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() {}
}
```

Note: both tests above reference `URLRequestRecorder.install()` / `.capturedRequests` / `.stubbedResponse` at the type level. The `install()` return value is only to let callers write `defer { recorder.uninstall() }`. Keep the API surface identical to the test usage.

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter AIServiceCompleteOptionsTests`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/WeChatHUDTests/AIServiceTests.swift Tests/WeChatHUDTests/Helpers/URLRequestRecorder.swift
git commit -m "test(AIService): cover Codex vs OpenAI-compat routing in complete(options:)"
```

---

## Phase 2: Migrate the 16 services

### Migration Pattern (read once; every Phase 2 task follows this shape)

**What gets deleted from each service:**

1. The private `call(_:)` / `callModel(_:)` HTTP method (30-60 lines).
2. `private func normalizeURL(_:)` — handled by AIService.
3. `private func stripThinking(_:)` — handled by AIService.
4. `private var config: AIConfig` — replaced with `private let aiService: AIService`.
5. `func updateConfig(_ cfg: AIConfig)` — removed; AIService owns config and auto-refreshes for all dependents.

**What gets added:**

1. Constructor takes `aiService: AIService` instead of `config: AIConfig`.
2. A thin `call(system:user:)` wrapper that:
   - Starts an `AIActivityTracker` span,
   - Calls `try await aiService.complete(system:user:options:)`,
   - On success writes `AIAudit` with `.ok`,
   - On failure writes `AIAudit` with `.httpError` and returns `""` (or whatever the empty-sentinel was).
3. Audit role + system prompt + `CompleteOptions` values are the **per-service specifics** each task lists.

**Template for the replacement call method (adapt per service):**

```swift
private func call(_ userPrompt: String) async -> String {
    let started = Date()
    let trackID = "<prefix>:\(UUID().uuidString.prefix(8))"
    AIActivityTracker.shared.begin(trackID, label: "<label>")
    defer { AIActivityTracker.shared.end(trackID) }

    do {
        let content = try await aiService.complete(
            system: "<system prompt — STRIPPED of thinking-suppression text>",
            user: userPrompt,
            options: CompleteOptions(
                timeout: <N>,
                temperature: <T or nil>,
                maxTokens: <M or nil>
                // extraSystemSuffix defaults to the thinking-suppression hint;
                // pass `extraSystemSuffix: nil` if the service's migrated
                // system prompt already handles thinking on its own, or if
                // you want the raw prompt verbatim. See Task 3 for an example.
            )
        )
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        writeAudit(input: userPrompt, output: content, latencyMs: latencyMs, status: .ok, error: nil)
        return content
    } catch {
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let status: AIAuditStatus = (error as? URLError)?.code == .timedOut ? .timeout : .httpError
        writeAudit(input: userPrompt, output: "", latencyMs: latencyMs, status: status, error: error.localizedDescription)
        return ""
    }
}
```

**Wiring update after each migration (done inside each task):**

- In `ChatMonitor.swift`, find the `lazy var` for the service and change the constructor argument from `config: store.loadAIConfig()` to `aiService: aiService ?? AIService(config: store.loadAIConfig())`. (The `??` preserves the current optional-aiService contract. See Task 19 for eventually making it non-optional.)
- Remove the corresponding `await <service>.updateConfig(cfg)` line in `refreshReplySuggesterConfig()`.

Every Phase 2 task ends with:

```bash
swift build 2>&1 | tail -5            # must build
swift test 2>&1 | tail -30            # all 350 tests still green
git add -A && git commit -m "refactor(<service>): route through AIService.complete (Codex support)"
```

---

### Task 3: Migrate `ChatAnalyzer`

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatAnalyzer.swift`
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift:155-157, 1798`

**Per-service specifics:**
- Audit role: `.chatAnalyzer`
- Prompt version: `"group_analysis_v1"` or `"private_analysis_v1"` (already passed to `writeAudit` — preserve)
- Timeout: `60`
- Temperature: `0.2` (was forced in existing constructor)
- Max tokens: `512`
- System prompt: `"你是一个消息分析助手，严格按要求输出 JSON。"`
- Track label: `"聊天分析"`, track prefix: `"chatanalyzer"`

Note: `ChatAnalyzer` has TWO analysis paths (group + private) each with a retry on strict prompt. The existing `call(_:)` is shared between them — keep it shared, just replace its HTTP body with the template above.

- [ ] **Step 1: Change init signature and stored property**

```swift
// Before (lines 34-45)
private let store: HUDStore
private var config: AIConfig
private let promptLoader: PromptLoader

init(store: HUDStore, config: AIConfig, promptLoader: PromptLoader = PromptLoader()) {
    self.store = store
    var cfg = config
    cfg.maxTokens = 512
    cfg.temperature = 0.2
    self.config = cfg
    self.promptLoader = promptLoader
}

func updateConfig(_ newConfig: AIConfig) {
    var cfg = newConfig
    cfg.maxTokens = 512
    cfg.temperature = 0.2
    self.config = cfg
}

// After
private let store: HUDStore
private let aiService: AIService
private let promptLoader: PromptLoader

init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
    self.store = store
    self.aiService = aiService
    self.promptLoader = promptLoader
}
```

Delete `updateConfig(_:)` entirely.

- [ ] **Step 2: Replace `call(_:)`, delete `normalizeURL`, `stripThinking`**

Delete lines 194-256 (`call`) and lines 305-319 (`normalizeURL` + `stripThinking`). Insert at the same place as `call`:

```swift
private func call(_ userPrompt: String) async -> String {
    let started = Date()
    let trackID = "chatanalyzer:\(UUID().uuidString.prefix(8))"
    AIActivityTracker.shared.begin(trackID, label: "聊天分析")
    defer { AIActivityTracker.shared.end(trackID) }

    do {
        let content = try await aiService.complete(
            system: "你是一个消息分析助手，严格按要求输出 JSON。",
            user: userPrompt,
            options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 512)
        )
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        writeAudit(input: userPrompt, output: content, latencyMs: latencyMs, status: .ok, error: nil)
        return content
    } catch {
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let status: AIAuditStatus = (error as? URLError)?.code == .timedOut ? .timeout : .httpError
        writeAudit(input: userPrompt, output: "", latencyMs: latencyMs, status: status, error: error.localizedDescription)
        return ""
    }
}
```

`parseJSON(_:)`, `formatMessages(_:)`, and the public `analyzeGroup` / `analyzePrivate` methods stay as-is.

- [ ] **Step 3: Update `ChatMonitor.swift` instantiation + drop `updateConfig` propagation**

At `ChatMonitor.swift:155-157`:

```swift
// Before
private lazy var chatAnalyzer: ChatAnalyzer = {
    ChatAnalyzer(store: store, config: store.loadAIConfig())
}()

// After
private lazy var chatAnalyzer: ChatAnalyzer = {
    ChatAnalyzer(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

At `ChatMonitor.swift:1798`, delete the line:

```swift
await chatAnalyzer.updateConfig(cfg)
```

- [ ] **Step 4: Build + run all tests**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30`
Expected: build succeeds; all 350 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(ChatAnalyzer): route through AIService.complete (Codex support)"
```

---

### Task 4: Migrate `AIClassifier`

**Files:**
- Modify: `Sources/WeChatHUD/Services/AIClassifier.swift`
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift:101-103, 1800`

**Per-service specifics:**
- Audit role: `.classifier`
- Timeout: `30`
- Temperature: from config (pass `nil`)
- Max tokens: from config (pass `nil`)
- System prompt: `"你是一个微信消息分类器。严格按要求输出 JSON。"`
- Track label: `"消息分类"`, prefix: `"classifier"`

`AIClassifier.callModel` returns a `ModelResponse` struct with `text` + `error`. Preserve that shape — just have the unified helper populate it from the `aiService.complete` result.

- [ ] **Step 1: Swap init signature**

```swift
// Before (line 23)
init(store: HUDStore, config: AIConfig = AIConfig(), promptLoader: PromptLoader = PromptLoader()) {
    self.store = store
    self.config = config
    self.promptLoader = promptLoader
}

// After
init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
    self.store = store
    self.aiService = aiService
    self.promptLoader = promptLoader
}
```

Change `private var config: AIConfig` to `private let aiService: AIService`. Delete `updateConfig(_:)`.

- [ ] **Step 2: Replace `callModel(userPrompt:)`**

Delete lines 117-172, replace with:

```swift
private func callModel(userPrompt: String) async -> ModelResponse {
    let trackID = "classifier:\(UUID().uuidString.prefix(8))"
    AIActivityTracker.shared.begin(trackID, label: "消息分类")
    defer { AIActivityTracker.shared.end(trackID) }

    do {
        let content = try await aiService.complete(
            system: "你是一个微信消息分类器。严格按要求输出 JSON。",
            user: userPrompt,
            options: CompleteOptions(timeout: 30)
        )
        return ModelResponse(text: content, error: nil)
    } catch {
        return ModelResponse(text: "", error: error.localizedDescription)
    }
}
```

Delete `normalizeURL` + `stripThinking` at the bottom of the file.

- [ ] **Step 3: Update ChatMonitor wiring**

At `ChatMonitor.swift:101-103`:

```swift
private lazy var aiClassifier: AIClassifier = {
    AIClassifier(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

Delete `ChatMonitor.swift:1800` (`await aiClassifier.updateConfig(cfg)`).

- [ ] **Step 4: Build + test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(AIClassifier): route through AIService.complete (Codex support)"
```

---

### Task 5: Migrate `VIPAggregator`

**Per-service specifics:**
- Audit role: `.vipAggregator`
- Timeout: `60`
- System prompt: reuse whatever is currently hardcoded in its `callModel` (read the file to copy verbatim)
- Track label: `"VIP 摘要"`, prefix: `"vip"`

Constructor currently: `init(store: HUDStore, promptLoader: PromptLoader = PromptLoader())` — takes no AIConfig. Investigate how it currently loads config (probably reads from `store.loadAIConfig()` at each call). After migration it gets `aiService` via init and loses its config lookup.

- [ ] **Step 1: Read current `Sources/WeChatHUD/Services/VIPAggregator.swift` `callModel` to capture the system prompt verbatim** (keep it identical — don't paraphrase)

- [ ] **Step 2: Add `private let aiService: AIService` + update init to accept it**

```swift
init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
    self.store = store
    self.aiService = aiService
    self.promptLoader = promptLoader
}
```

- [ ] **Step 3: Replace `callModel(_:)` with the template above (timeout 60, role `.vipAggregator`)**

- [ ] **Step 4: Delete `normalizeURL` + `stripThinking` + any per-service `config` field**

- [ ] **Step 5: Update `ChatMonitor.swift:111-113`**

```swift
private lazy var vipAggregator: VIPAggregator = {
    VIPAggregator(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(VIPAggregator): route through AIService.complete (Codex support)"
```

---

### Task 6: Migrate `DiscussionTracker`

**Per-service specifics:**
- Audit role: `.contextAnalyzer` (verify — may be a dedicated role; if not, use `.contextAnalyzer` or add `case discussionTracker` to `AIRole`)
- Timeout: `45`
- System prompt: copy verbatim from the file
- Track label: `"讨论追踪"`, prefix: `"discussion"`

If `AIRole` lacks a `.discussionTracker` case, add it to `Sources/WeChatHUD/Data/Models.swift:960-974`:

```swift
case discussionTracker = "discussion_tracker"
```

- [ ] **Step 1: Read current `DiscussionTracker.swift` to capture system prompt + current audit role**

- [ ] **Step 2: Add `AIRole.discussionTracker` case if missing, with raw value `"discussion_tracker"`** (leave existing rows in DB unaffected since they carry their old string)

- [ ] **Step 3: Swap init signature to take `aiService: AIService`**

- [ ] **Step 4: Replace `callModel` with the template (timeout 45)**

- [ ] **Step 5: Update `ChatMonitor.swift:107-109`**

```swift
private lazy var discussionTracker: DiscussionTracker = {
    DiscussionTracker(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 6: Delete `normalizeURL` / `stripThinking`**

- [ ] **Step 7: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(DiscussionTracker): route through AIService.complete (Codex support)"
```

---

### Task 7: Migrate `ContextAnalyzer`

**Per-service specifics:**
- Audit role: `.contextAnalyzer`
- Timeout: `45`
- System prompt: copy verbatim from file
- Track label: `"上下文分析"`, prefix: `"context"`

- [ ] **Step 1: Read file, capture prompt**
- [ ] **Step 2: Swap init signature to `aiService: AIService`** (currently `init(store: HUDStore, promptLoader: PromptLoader = PromptLoader())` — add `aiService` param)
- [ ] **Step 3: Replace `callModel(_:)` with template (timeout 45)**
- [ ] **Step 4: Update `ChatMonitor.swift` where `contextAnalyzer` is constructed (grep for `ContextAnalyzer(`)**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(ContextAnalyzer): route through AIService.complete (Codex support)"
```

---

### Task 8: Migrate `CommitmentTracker`

**Per-service specifics:**
- Audit role: `.commitmentTracker`
- Timeout: `30`
- Temperature: `0.05` (explicit — services sets it low for factual extraction)
- System prompt: copy verbatim from file
- Track label: `"承诺识别"`, prefix: `"commitment"`

- [ ] **Step 1: Read file, capture prompt + confirm temperature 0.05 is used**
- [ ] **Step 2: Swap init signature to `aiService: AIService`**
- [ ] **Step 3: Replace `callModel(_:)` with template (timeout 30, temperature 0.05)**
- [ ] **Step 4: Update `ChatMonitor.swift:104-106`**

```swift
private lazy var commitmentTracker: CommitmentTracker = {
    CommitmentTracker(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(CommitmentTracker): route through AIService.complete (Codex support)"
```

---

### Task 9: Migrate `RecallAnalyzer`

**Per-service specifics:**
- Audit role: `.recallAnalyzer`
- Timeout: `30`
- System prompt: copy verbatim from file
- Track label: `"撤回分析"`, prefix: `"recall"`

- [ ] **Step 1: Read file, capture prompt**
- [ ] **Step 2: Swap init signature to `aiService: AIService`**
- [ ] **Step 3: Replace `callModel(_:)` with template (timeout 30)**
- [ ] **Step 4: Update `ChatMonitor.swift:114-116`**

```swift
private lazy var recallAnalyzer: RecallAnalyzer = {
    RecallAnalyzer(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(RecallAnalyzer): route through AIService.complete (Codex support)"
```

---

### Task 10: Migrate `AutoReplyGenerator`

**Per-service specifics:**
- Audit role: `.replyGenerator`
- Timeout: `60`
- System prompt: copy verbatim from file
- Track label: `"自动回复"`, prefix: `"autoreply"`
- Returns `Decision` (JSON) — the service's own parser keeps working since we still return the raw string.

- [ ] **Step 1: Read file, capture prompt**
- [ ] **Step 2: Swap init signature to `aiService: AIService`**
- [ ] **Step 3: Replace `call(_:)` with template (timeout 60)**
- [ ] **Step 4: Find where `AutoReplyGenerator(...)` is constructed (likely in `AutopilotService`) and update**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Check `AutopilotService.swift:385` (`await generator.updateConfig(config)`) — delete if the generator no longer has `updateConfig`**
- [ ] **Step 7: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AutoReplyGenerator): route through AIService.complete (Codex support)"
```

---

### Task 11: Migrate `AIWhitelistCategorizer`

**Per-service specifics:**
- Audit role: `.classifier` or `.briefer` (check the current `writeAudit` call — use whatever is there)
- Timeout: `60`
- System prompt: copy verbatim from file
- Track label: `"白名单分类"`, prefix: `"categorizer"`

- [ ] **Step 1: Read file, capture prompt + current audit role**
- [ ] **Step 2: Swap init signature to `aiService: AIService`**
- [ ] **Step 3: Replace `call(_:)` with template (timeout 60)**
- [ ] **Step 4: Find construction site and update (grep `AIWhitelistCategorizer(`)**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIWhitelistCategorizer): route through AIService.complete (Codex support)"
```

---

### Task 12: Migrate `AIReplySuggester`

**Per-service specifics:**
- Audit role: `.replyGenerator`
- Timeout: `60`
- System prompt: copy verbatim from file
- Track label: `"回复建议"`, prefix: `"replysug"`

- [ ] **Step 1: Read file, capture prompt**
- [ ] **Step 2: Swap init signature to `aiService: AIService`**
- [ ] **Step 3: Replace `call(_:)` with template (timeout 60)**
- [ ] **Step 4: Update `ChatMonitor.swift:117-119`**

```swift
private lazy var replySuggester: AIReplySuggester = {
    AIReplySuggester(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 5: Delete `ChatMonitor.swift:1797` (`await replySuggester.updateConfig(cfg)`)**
- [ ] **Step 6: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 7: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIReplySuggester): route through AIService.complete (Codex support)"
```

---

### Task 13: Migrate `AIInboxSummarizer`

**Per-service specifics:**
- Audit role: `.summarizer`
- Timeout: `30`
- System prompt: copy verbatim from file
- Track label: `"收件摘要"`, prefix: `"inbox"`

- [ ] **Step 1: Swap init signature to `aiService: AIService`**
- [ ] **Step 2: Replace `call(_:)` with template; preserve the `CallResult(text:error:)` return shape by wrapping the success/error branches**

```swift
private func call(_ userPrompt: String) async -> CallResult {
    let trackID = "inbox:\(UUID().uuidString.prefix(8))"
    AIActivityTracker.shared.begin(trackID, label: "收件摘要")
    defer { AIActivityTracker.shared.end(trackID) }
    do {
        let content = try await aiService.complete(
            system: "你是用户的微信消息管家。只输出摘要文本，不要任何其他内容。",
            user: userPrompt,
            options: CompleteOptions(timeout: 30)
        )
        return CallResult(text: content, error: nil)
    } catch {
        return CallResult(text: nil, error: error.localizedDescription)
    }
}
```

- [ ] **Step 3: Update `ChatMonitor.swift:161-163`**

```swift
private lazy var inboxSummarizer: AIInboxSummarizer = {
    AIInboxSummarizer(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 4: Delete `ChatMonitor.swift:1802` (`await inboxSummarizer.updateConfig(cfg)`)**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIInboxSummarizer): route through AIService.complete (Codex support)"
```

---

### Task 14: Migrate `AIGroupCatchup`

**Per-service specifics:**
- Audit role: `.groupDigestor`
- Timeout: `60`
- System prompt: copy verbatim
- Track label: `"群聊追赶"`, prefix: `"catchup"`

- [ ] **Step 1: Swap init signature to `aiService: AIService`**
- [ ] **Step 2: Replace `call(_:)` with template**
- [ ] **Step 3: Update `ChatMonitor.swift` where `aiGroupCatchup` is constructed (line ~99)**
- [ ] **Step 4: Delete `ChatMonitor.swift:1805` (`await aiGroupCatchup.updateConfig(cfg)`)**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIGroupCatchup): route through AIService.complete (Codex support)"
```

---

### Task 15: Migrate `AIDailyRetrospector`

**Per-service specifics:**
- Audit role: `.retrospector`
- Timeout: `90`
- System prompt: copy verbatim
- Track label: `"日报/周报"`, prefix: `"retro"`

- [ ] **Step 1: Swap init signature to `aiService: AIService`**
- [ ] **Step 2: Replace `call(_:)` with template (timeout 90)**
- [ ] **Step 3: Update `ChatMonitor.swift:149-151`**

```swift
private lazy var dailyRetrospector: AIDailyRetrospector = {
    AIDailyRetrospector(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 4: Delete `ChatMonitor.swift:1803` (`await dailyRetrospector.updateConfig(cfg)`)**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIDailyRetrospector): route through AIService.complete (Codex support)"
```

---

### Task 16: Migrate `AIChatInsight`

**Per-service specifics:**
- Audit role: check file — use existing role
- Timeout: `60`
- System prompt: copy verbatim
- Track label: `"对话洞察"`, prefix: `"insight"`

- [ ] **Step 1: Read file, capture prompt + current audit role**
- [ ] **Step 2: Swap init signature to `aiService: AIService`**
- [ ] **Step 3: Replace `call(_:)` with template (timeout 60)**
- [ ] **Step 4: Update `ChatMonitor.swift:164-166`**

```swift
private lazy var chatInsightService: AIChatInsight = {
    AIChatInsight(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 5: Delete `ChatMonitor.swift:1804` (`await chatInsightService.updateConfig(cfg)`)**
- [ ] **Step 6: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 7: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIChatInsight): route through AIService.complete (Codex support)"
```

---

### Task 17: Migrate `AIBriefingGenerator`

**Per-service specifics:**
- Audit role: `.briefer`
- Timeout: `60`
- System prompt: copy verbatim
- Track label: `"简报"`, prefix: `"brief"`

- [ ] **Step 1: Swap init signature to `aiService: AIService`**
- [ ] **Step 2: Replace `call(_:)` with template (timeout 60)**
- [ ] **Step 3: Update `ChatMonitor.swift:152-154`**

```swift
private lazy var briefingGenerator: AIBriefingGenerator = {
    AIBriefingGenerator(store: store, aiService: aiService ?? AIService(config: store.loadAIConfig()))
}()
```

- [ ] **Step 4: Delete `ChatMonitor.swift:1801` (`await briefingGenerator.updateConfig(cfg)`)**
- [ ] **Step 5: Delete `normalizeURL` / `stripThinking`**
- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AIBriefingGenerator): route through AIService.complete (Codex support)"
```

---

### Task 18: Migrate `AutopilotService`

**Per-service specifics:**
- Audit role: `.autopilot`
- Timeout: `30`
- System prompt: copy verbatim (there are 2 prompts inside — `refreshMemoryAfterSend` at line ~897 and another at ~1101; each uses its own system/user)
- Note: `AutopilotService` doesn't currently write to `AIAudit` (only to its own `autopilot_log`) — **skip the audit wrapper here**, just do the `complete(...)` call.

- [ ] **Step 1: Swap init signature**

```swift
// Before (line 91)
init(store: HUDStore, reader: WeChatReader, config: AIConfig) {

// After
init(store: HUDStore, reader: WeChatReader, aiService: AIService) {
```

Also drop the stored `config` property (if present) and `updateConfig`. The `AutoReplyGenerator` nested inside takes `aiService` after Task 10.

- [ ] **Step 2: Replace the TWO URLRequest call sites (lines ~897, ~1101) with `aiService.complete(...)` calls** — no audit wrapper, just plain calls with `CompleteOptions(timeout: 30)` and the system prompts copied verbatim

- [ ] **Step 3: Delete `AppDelegate.swift:319` (`await self.monitor.autopilotService?.updateConfig(cfg)`)** — AIService already gets the new config on line 318

- [ ] **Step 4: Find where `AutopilotService(...)` is constructed (grep `AutopilotService(`) and update to pass `aiService`**

- [ ] **Step 5: Build + test + commit**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -30
git add -A && git commit -m "refactor(AutopilotService): route through AIService.complete (Codex support)"
```

---

## Phase 3: Cleanup + End-to-End Verification

### Task 19: Remove the `aiService: AIService?` optional and clean up defensive fallbacks

**Files:**
- Modify: `Sources/WeChatHUD/Services/ChatMonitor.swift`
- Modify: `Sources/WeChatHUD/Services/ScanEngine.swift`

**Why this task:** Every production code path creates `AIService` in `AppDelegate.applicationDidFinishLaunching` before `ChatMonitor` is built. After Phase 2, every lazy service construction has an `aiService ?? AIService(config: store.loadAIConfig())` fallback — wasteful because that fallback AIService would never get config updates. Dropping the `?` kills the fallbacks and makes the invariant explicit.

- [ ] **Step 1: Change `ChatMonitor.swift:97` from `private let aiService: AIService?` to `private let aiService: AIService`**

- [ ] **Step 2: Change `ChatMonitor.swift:253` from `aiService: AIService? = nil` to `aiService: AIService`**

- [ ] **Step 3: Delete every `aiService ?? AIService(...)` fallback introduced in Phase 2 — replace with `aiService:` straight through**

Run: `grep -n 'aiService ?? AIService' Sources/WeChatHUD/Services/ChatMonitor.swift`
For each match, replace `aiService ?? AIService(config: store.loadAIConfig())` with `aiService`.

- [ ] **Step 4: Update `ScanEngine.swift:33` if needed (`aiService: AIService?` → `AIService`)**

Check `Sources/WeChatHUD/Services/ScanEngine.swift` and any other callers. If a test constructs `ChatMonitor` without `aiService`, update the test to pass a mock `AIService` or the real one with an empty config.

- [ ] **Step 5: Build + test**

Run: `swift build 2>&1 | tail -10 && swift test 2>&1 | tail -30`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(ChatMonitor): require non-optional AIService now that every AI path needs it"
```

---

### Task 20: End-to-end smoke test — trigger the original bug with Codex selected

**Why this task:** The report started with a user-visible failure in the action panel. Verify the fix at the level where the bug was reported.

- [ ] **Step 1: Build and run the app**

```bash
make app && make run
```

- [ ] **Step 2: In Settings → AI, switch activeMode to "仅线上" and pick `openai-codex` as the cloud provider; confirm codex login shows an account email**

- [ ] **Step 3: Click a whitelisted chat row in the inbox so the action panel opens**

Expected: the analysis renders (e.g., group topics / private intent) instead of `"分析失败，可能是 AI 服务超时"`.

- [ ] **Step 4: Check `Console.app` (or stderr) for `[WCHUD]` lines confirming ChatAnalyzer completed successfully and no "request error" log fired**

- [ ] **Step 5: Rotate through all the migrated features once (or at least a representative set): reply suggestions, group catchup, VIP digest, daily retrospective, inbox summary**

- [ ] **Step 6: Record the result. If any feature still shows a timeout/error, capture the screenshot + `Console` tail and return to Phase 1 diagnostics**

No commit needed — this task only verifies.

---

### Task 21: Final verification — zero regressions

- [ ] **Step 1: Build release**

Run: `swift build -c release 2>&1 | tail -20`
Expected: zero new warnings beyond the pre-existing Swift 6 strict-concurrency warnings captured in CLAUDE.md.

- [ ] **Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all 350 tests pass (plus the 2 new `AIServiceCompleteOptionsTests` from Task 2 = 352).

- [ ] **Step 3: Inspect the final diff for any lingering `chat/completions` string literal outside `AIService.swift` and `CodexBackend.swift` (tests may still have some)**

Run: `grep -rn 'chat/completions' Sources/ | grep -v AIService.swift | grep -v CodexBackend.swift`
Expected: zero matches.

- [ ] **Step 4: Summary commit / tag**

No code changes required here — if all above is clean, the previous commits carry the refactor. Optionally:

```bash
git log --oneline origin/main..HEAD
# Expected: ~19 commits, one per migrated service + foundation + cleanup
```

---

## Risk Register

| Risk | Mitigation |
|------|-----------|
| Existing per-service tests mock URLSession and break after migration | Phase 2 tasks re-run `swift test` after every migration; fix tests to mock `AIService` or use the `URLRequestRecorder` helper |
| `AIService` actor serialization slows down parallel prefetching | Actor re-entrant: async methods release the lock during `await`, so concurrent HTTP dispatch is unaffected. Verify Task 20 doesn't regress inbox prefetch perf |
| Some services inject custom response-format flags we missed | Phase 2 tasks all say "copy system prompt verbatim" — read the file before editing, don't paraphrase. If a task hits a body field not covered by `CompleteOptions`, extend `CompleteOptions` first and update Task 1 |
| Config hot-reload fans out to only `aiService` now, not per-service | Task 19 confirms no service holds a stale `AIConfig` copy — if they did, settings changes would stop propagating |
| AutopilotService didn't write AIAudit and the migration template assumes it does | Task 18 explicitly notes "skip the audit wrapper" for AutopilotService |

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-ai-transport-unification.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. 21 tasks, ~4-6 hours total with review overhead.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints (e.g. after Phase 1, after Phase 2 is half done, after full Phase 2, after Phase 3).

Which approach?
