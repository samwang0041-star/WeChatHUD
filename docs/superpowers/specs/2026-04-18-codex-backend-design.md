# Codex Backend Integration — 复刻 OpenClaw 调用机制

**日期**: 2026-04-18
**状态**: Approved, in implementation

## 背景

WeChatHUD 现在的 14 个 AI service 全部走 OpenAI 兼容的 `/chat/completions`，需要付费 API key（DashScope/DeepSeek/SiliconFlow/OpenAI 等）。OpenClaw 通过读取 codex CLI 本地 OAuth token 实现"蹭 ChatGPT 订阅"调 `gpt-5.4`。本设计在 WeChatHUD 内复刻 OpenClaw 的应用层调用指纹，让用户的 ChatGPT 订阅可以直接驱动 WeChatHUD。

## 核心决策

| 维度 | 决策 |
|---|---|
| 集成方式 | **新增 provider** (id="openai-codex")，与现有 OpenAI 兼容 slot 平级 |
| API 暴露 | **纯适配器** — 在 `AIService.send()` 内分流，14 个 service 一行不改 |
| 网络指纹 | **应用层 100% 一致**（Swift URLSession，TLS 握手层不强求） |
| 启用方式 | **自动识别** — Settings provider picker 默认列出 Codex 选项，选中后校验 `~/.codex/auth.json` |
| Token 持久化 | **只读 auth.json，不写回** — 避免和 codex CLI 抢着改文件 |

## 架构

```
AIClassifier / AIInboxSummarizer / 其他 12 个 service
    └─> AIService.complete(system, user)
          └─> [if slot.providerID == "openai-codex"]
                └─> CodexBackend.complete(system, user)
                      ├─> CodexTokenStore.validAccessToken()
                      │     ├─> [if expired] CodexAuth.refreshToken()
                      │     │     └─> POST auth.openai.com/oauth/token
                      │     └─> 返回有效 access token
                      └─> POST chatgpt.com/backend-api/codex/responses
                            ├─> SSE 流接收
                            └─> 拼装为 String 返回
```

## 文件清单

```
Sources/WeChatHUD/Services/Codex/                     [新增目录]
├── CodexAuth.swift                  读 auth.json + JWT 解码
├── CodexTokenStore.swift            access token 缓存 + refresh
└── CodexBackend.swift               HTTP 请求 + SSE 解析

Sources/WeChatHUD/Services/AIService.swift            [修改] send() 内部分流
Sources/WeChatHUD/Data/Models.swift                   [修改] AIProvider.builtIn 加 openai-codex
Sources/WeChatHUD/App/SettingsWindow.swift            [修改] 选中 codex 时隐藏 apiKey/baseURL，显示登录邮箱

Tests/WeChatHUDTests/CodexAuthTests.swift             [新增]
Tests/WeChatHUDTests/CodexTokenStoreTests.swift       [新增]
Tests/WeChatHUDTests/CodexBackendTests.swift          [新增]
```

## 请求指纹规范（核心 — 必须严格执行）

### 1. Token 刷新

```
POST https://auth.openai.com/oauth/token
Headers:
  Content-Type: application/x-www-form-urlencoded

Body (form-urlencoded):
  grant_type=refresh_token
  refresh_token=<从 ~/.codex/auth.json 的 tokens.refresh_token 读>
  client_id=app_EMoamEEZ73f0CkXaXp7hrann

Response (JSON):
  { access_token, refresh_token, expires_in }  // expires_in 是秒
```

**注意**：refresh response 里也会带新的 refresh_token（rotating）。我们**只更新内存里的 access**，refresh_token 仍然以 auth.json 当前值为准——下次启动重新读，避免和 codex CLI 互相覆盖。

### 2. 聊天请求

```
POST https://chatgpt.com/backend-api/codex/responses

Headers (顺序见下；URLSession 不保证顺序但全部要在):
  Authorization: Bearer <access_token>
  chatgpt-account-id: <从 access_token JWT 的 https://api.openai.com/auth.chatgpt_account_id 提取>
  originator: pi
  User-Agent: pi (<uname.sysname> <uname.release>; <uname.machine>)
              举例: pi (Darwin 25.3.0; arm64)
  OpenAI-Beta: responses=experimental
  accept: text/event-stream
  content-type: application/json
  session_id: <UUID v4，进程生命周期内固定>

Body (JSON):
{
  "model": "gpt-5.4",
  "store": false,
  "stream": true,
  "instructions": "<system prompt>",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [{ "type": "input_text", "text": "<user prompt>" }]
    }
  ],
  "text": { "verbosity": "medium" },
  "include": ["reasoning.encrypted_content"],
  "prompt_cache_key": "<同 session_id>",
  "tool_choice": "auto",
  "parallel_tool_calls": true
}
```

**字段来源**：每个字段都从 `@mariozechner/pi-ai/dist/providers/openai-codex-responses.js` 第 200-228 行（buildRequestBody）和第 708-728 行（buildSSEHeaders）逐字段对齐。包括看着可疑但必须有的 `text.verbosity`、`include`、`tool_choice`、`parallel_tool_calls`——缺了 OpenAI 后端可能拒绝或行为偏差。

### 3. SSE 响应解析

服务端返回 `Content-Type: text/event-stream`。每个事件格式：
```
data: {"type": "...", ...}\n\n
```

需要处理的事件类型：
- `response.output_text.delta` — 字段 `delta` 是字符串增量，累加到结果
- `response.output_text.done` — 当前 output 块结束（不必处理，等下一个事件）
- `response.completed` — 正常结束，停止累加
- `response.failed` — 失败，从 `response.error.message` 抽错误信息抛
- `error` — 顶层错误，从 `message` 抽错误信息抛

其他事件（`response.created`、`response.in_progress`、`response.output_item.added` 等）忽略。

### 4. session_id 策略

`CodexBackend` 单例在 init 时生成一个 UUID v4，整个进程生命周期复用。同时作为：
- HTTP header `session_id`
- Body 的 `prompt_cache_key`

理由：OpenAI 后端用 `prompt_cache_key` 做 prompt cache。复用同一个 key，连续调用能命中缓存，省 token 也省延迟。pi-ai 也是这么做的。

## Token 缓存策略

`CodexTokenStore` 是 actor，状态：
```swift
private var cachedAccess: String?
private var cachedExpiry: Date?
private var refreshTask: Task<String, Error>?  // 防止并发 refresh
```

行为：
1. **首次调用 `validAccessToken()`**：
   - 调 `CodexAuth.readAuthFile()` 读 auth.json
   - 用 access_token 的 JWT exp claim 算过期时间
   - 如果 access 还有 ≥ 60 秒有效期，缓存返回
   - 否则用 refresh_token 走 refresh 流程
2. **后续调用**：
   - 缓存有效 → 直接返回
   - 缓存过期 → refresh
3. **并发请求 refresh**：用 `refreshTask` 单例化，所有等待同一个 task
4. **被通知 401**（来自 CodexBackend）：
   - 清空缓存
   - 重读 auth.json（可能 codex CLI 已经 rotate 过更新的 refresh_token）
   - 强制 refresh 一次
   - 返回新 token；如果还失败，抛 `.codexAuthExpired`

## 错误处理

| 场景 | 行为 |
|---|---|
| `~/.codex/auth.json` 不存在 | 抛 `.codexNotLoggedIn`，UI 显示 "先在终端运行 `codex login`" |
| auth.json 存在但 `auth_mode != "chatgpt"` | 抛 `.codexNotChatGPTMode`，提示用户用 ChatGPT OAuth 登录而非 API key |
| Token refresh HTTP 4xx (refresh_token invalid) | 抛 `.codexAuthExpired`，提示重新 `codex login` |
| Token refresh HTTP 5xx / 网络 | 抛 `.codexBackendError`，让 AIService 走 fallback slot |
| Codex chat HTTP 401 | 触发 TokenStore re-read + refresh，重试一次；仍失败抛 `.codexAuthExpired` |
| Codex chat HTTP 429 | 抛 `.codexUsageLimit`，提示 ChatGPT 用量上限，**不重试** |
| Codex chat HTTP 5xx / 网络 | 抛 `.codexBackendError`，让 AIService 走 fallback slot |
| SSE `response.failed` / `error` 事件 | 抛 `.codexResponseFailed(message)` |
| 60 秒无任何 SSE 事件 | 超时，抛 `.codexTimeout` |

## Settings UI 改动

在 `AIProvider.builtIn` 列表里加：
```swift
AIProvider(
    id: "openai-codex",
    name: "OpenAI Codex (ChatGPT 订阅)",
    baseURL: "",  // 实际固定 chatgpt.com，不让用户改
    models: ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.3-codex"],
    requiresKey: false,
    signupURL: "https://github.com/openai/codex"
)
```

SettingsWindow provider picker 选中 "openai-codex" 时：
- 隐藏 baseURL 输入框
- 隐藏 apiKey 输入框
- 显示 model 下拉（4 个选项）
- 下方显示一行状态：
  - 如果 auth.json 有效：✅ `登录账号: <从 JWT 解出的 email>`
  - 如果 auth.json 不存在/无效：⚠️ `未检测到 codex 登录态，请在终端执行：codex login`
- "测试连接" 按钮调 `CodexBackend.complete("Reply OK.", "Test")` 验证

## AIService 分流改动

`AIService.send(slot:system:user:)` 内部加一个分支：

```swift
private func send(slot: AIProviderSlot, system: String, user: String) async throws -> String {
    if slot.providerID == "openai-codex" {
        return try await CodexBackend.shared.complete(system: system, user: user, model: slot.model)
    }
    // 原有 OpenAI 兼容代码不动
    ...
}
```

`CodexBackend.shared` 是个 actor 单例（构造时初始化 TokenStore + UUID）。

## 测试

### CodexAuthTests
- 解析合法 auth.json (auth_mode=chatgpt)
- 拒绝 auth_mode != chatgpt
- 拒绝缺 access/refresh token
- JWT 解码：提取 chatgpt_account_id, email, exp
- 处理 malformed JWT（不崩溃，返回 nil）

### CodexTokenStoreTests
- 缓存有效返回缓存
- 缓存过期触发 refresh（mock fetch）
- 并发 N 个 validAccessToken() 只触发一次 refresh
- 被通知 401 后重读 auth.json + 强制 refresh

### CodexBackendTests (URLProtocol mock)
- 请求 URL/method/headers/body 全部和 spec 匹配（逐字段断言）
- User-Agent 格式正确（含 uname 信息）
- SSE 解析：拼接多段 delta、识别 completed
- 401 触发 re-auth + 重试一次
- 429 抛 usageLimit、不重试
- 5xx 抛 backendError

## YAGNI（不做）

- 写回 auth.json（codex CLI 自己会 rotate，不要互相覆盖）
- WebSocket 传输（HTTP SSE 够用）
- 多账号支持（auth.json 只有一个）
- Reasoning trace 暴露给上层（complete() 只返回最终文本）
- 流式 UI（现有 14 个 service 都是批量调用）
- 第三方账号管理 UI（用户自己 codex login）
- TLS 指纹伪装（接受 Swift URLSession 默认）

## 验收标准

1. `swift build -c release` 零警告
2. `swift test` 全部通过（含新增 ~30 个测试）
3. 手动测试：
   - 在 Settings 选 openai-codex + gpt-5.4，"测试连接" 返回 "OK" 类似响应
   - 实际触发一次 AIInboxSummarizer，请求成功且响应合理
   - `tcpdump`/`mitmproxy` 抓包确认 headers/body 与 OpenClaw 一致
4. 关掉/删除 auth.json，Settings 显示正确警告
5. 故意写一个无效 refresh_token 进 auth.json，触发 refresh 失败时错误信息清晰
