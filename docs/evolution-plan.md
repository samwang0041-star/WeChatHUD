# WeChatHUD 全面进化方案

## 执行摘要

WeChatHUD 当前主要风险不是单点 bug，而是三条架构债叠加：本地敏感数据保护不足、并发边界不可信、UI/AI 子系统增长过快。进化顺序必须先止血，再固化基础设施，最后做性能与可维护性优化。

建议分 5 个阶段，总周期约 12-15 周，每阶段不超过 3 周：

| 阶段 | 主题 | 目标 | 覆盖问题 |
|---|---|---|---|
| P0 | 安全止血 | 移除硬编码密钥、阻断明文外发/明文落盘风险 | 1,2,3,4,10,23,25 |
| P1 | 存储与并发地基 | Actor 化 HUDStore/WeChatReader 边界，建立版本化迁移 | 6,7,8,16,26,27 |
| P2 | 扫描与 UI 性能 | 降低全局刷新、修复列表/窗口行为、优化 DB 查询 | 5,12,13,14,15,21,22 |
| P3 | AI 平台化 | 统一 AI 调用、脱敏、审计、测试缺口 | 17,18,4,25 |
| P4 | 模块化与发布硬化 | 拆分巨型模型、补齐中低优先级体验、稳定测试/签名 | 19,20,24,28 |

核心技术路线：

- Swift 6 严格并发采用"立即建立门禁，渐进开启 complete"的策略，不一次性大爆炸。
- Actor 化采用中粒度：`HUDStoreActor`、`WeChatReaderActor`、`AIRequestPipeline`、`ClipboardActor`，避免每个 DAO/方法过细导致调用面爆炸。
- 数据脱敏必须在客户端完成，服务端/模型端不承担第一道防线。
- 状态管理短期保持 `ObservableObject/@Published` 兼容，逐步引入切片式 ViewModel；新模块采用 `@Observable`。
- 测试策略为"补齐安全/迁移/AI 基础设施测试 + 保持 350 个现有测试通过"，不是只测新增，也不是重写全部历史测试。

---

## 详细阶段计划

### P0：安全止血与隐私基线，1-2 周

**目标**

消除可立即利用的安全风险，确保用户在默认配置下不会泄露 API Key、微信明文 DB、真实消息全文或 OAuth token。

**范围**

- 移除 HUDStore.swift 中硬编码云端 API Key。
- 将 `AIProviderSlot.apiKey` 从 SQLite `settings.ai` 明文迁移到 macOS Keychain。
- `settings.ai` 仅保存 provider、baseURL、model、keychain item reference。
- 收紧 `~/.wechat-hud`、`~/.wechat-hud/cache`、解密 DB 文件权限：目录 `0700`，文件 `0600`。
- 默认禁用 persistent decrypted cache；优先使用 memory/ephemeral cache，退出时清理。
- 禁止远程 AI 使用 `http://`；仅允许 localhost HTTP。
- Codex `auth.json` 读取前校验：非 symlink、owner 为当前用户、权限不宽于 `0600/0640`。
- AI 请求前统一调用 `Redactor`/新 `PrivacyRedactor`，默认不发送真实姓名、wxid、手机号、邮箱、URL token、金额、地址、身份证样式文本。
- `ai_audit.input_text/output_text` 改为保存 redacted snippet/hash，缩短 raw 内容留存为 0 天，调试模式才允许本地明文短期留存。
- zstd 与 XML 的 DoS 防护可先放到 P4 完整做，但 P0 至少设定 zstd 最大输出硬上限。

**交付物**

- `KeychainSecretStore`：保存、读取、删除 AI API Key。
- `AIConfig` v2：SQLite 中不再包含明文 `apiKey`。
- 一次性迁移：读取旧 SQLite key → 写入 Keychain → 清空 DB 明文字段。
- `SecureFileManager`：创建目录/文件时统一设置权限。
- `AIPrivacyPipeline`：请求前脱敏，审计前二次脱敏。
- 安全回归测试：Keychain mock、HTTP 阻断、脱敏、文件权限、Codex auth 权限。

**主要风险与缓解**

- Keychain 迁移失败导致用户丢 key：迁移采用"两阶段提交"，Keychain 写入成功并可读回后再清空 SQLite。
- 本地模型 HTTP 被误禁：允许 `localhost`、`127.0.0.1`、`::1`，远程 IP/域名必须 HTTPS。
- 脱敏降低 AI 效果：保留稳定占位符，如 `PERSON_1`、`CHAT_1`，让模型仍能理解关系结构。

**成功指标**

- 代码库不再包含真实 `sk-` API Key。
- 新建/迁移后的 `hud.sqlite3` 中搜索不到 API Key 明文。
- 解密 DB 文件权限为 `0600`，cache 目录为 `0700`。
- 远程 `http://example.com` AI endpoint 连接测试失败，`http://127.0.0.1` 允许。
- AI request recorder 测试证明消息正文已脱敏。
- 现有 350 测试继续通过，新增安全测试通过。

---

### P1：存储与 Swift 并发地基，2-3 周

**目标**

消除 SQLite wrapper 和 WeChatReader 的"看似线程安全"状态，使后续性能优化建立在可信并发模型上。

**范围**

- 为 `HUDStore` 建立单写入/串行访问边界。
- 移除 "FULLMUTEX 等于 wrapper 安全" 的假设。
- 替换 ChatMonitor.swift 的 `nonisolated(unsafe)` store 传递。
- 替换 `Task.detached` 传递 shared mutable `reader/store` 的模式。
- `WeChatReader` 从 `@unchecked Sendable` 迁移到 actor 或 actor facade。
- `AutopilotService` 剪贴板操作收敛到 MainActor/Clipboard service。
- 引入 `PRAGMA user_version` 或 `schema_migrations` 表，停止靠 `CREATE TABLE IF NOT EXISTS` + `ALTER TABLE try?` 漂移。
- Package 增加 Swift concurrency warning 门禁，不立刻 complete 全量失败。

**交付物**

- `HUDStoreActor` 或 `SerializedHUDStore`：所有 SQLite prepare/step/finalize 通过同一 executor。
- `WeChatReaderActor`：保护 decrypted cache、contact cache、self aliases、chatDBCache。
- `ScanEngine` 输入改成 snapshot DTO 或 actor async 方法，避免 detached task 持有非 Sendable 引用。
- `SchemaMigrator`：版本号、up/down 不需要，至少 up-only 幂等迁移。
- Swift build settings：先启用 `-warn-concurrency`、`StrictConcurrency=targeted`，记录 complete 模式剩余错误。
- 并发压力测试：并发读写 settings、AI audit、scan cache 不崩溃、不交叉污染。

**主要风险与缓解**

- Actor 改造牵动调用面大：先加 facade，保留同步 API 给旧测试，内部串行化；再逐步 async 化。
- 测试大量需要 `await`：优先改 helper 和 fixture，不在业务逻辑里引入临时 `Task {}`。
- Scan 性能下降：actor 方法提供批量 API，避免每条消息一次 actor hop。

**成功指标**

- `nonisolated(unsafe)`、`@unchecked Sendable` 在核心数据路径清零或有明确 ADR 例外。
- `Task.detached` 不再捕获 `HUDStore`/`WeChatReader`。
- SQLite 并发压力测试 1,000 次混合操作无 crash、无 `SQLITE_MISUSE`。
- schema version 从 0 迁移到当前版本可重复执行。
- `swift build` 在 targeted strict concurrency 下无新增 warning，剩余 complete warning 有清单。

---

### P2：扫描与 UI 性能，2-3 周

**目标**

解决"全视图刷新"和扫描性能瓶颈，保证高消息量/大白名单下 UI 稳定。

**范围**

- 拆分 ChatMonitor.swift 的 30+ `@Published`。
- 建立状态切片：Inbox、Autopilot、Insights、Retrospective、Panel。
- 将 Extended/Inbox 大列表从 eager `VStack` 改为 `LazyVStack` 或 `List`，保留现有视觉。
- 修复 `UUID()`/offset 作为 List id 导致的 row state 丢失。
- 修复 `.extended` 调用 `makeKey()` 抢焦点问题，当前注释与实现不一致。
- 优化 WeChatReader N+1：为白名单扫描建立批量消息读取。
- 补齐 `review_todos`、`red_banner_dismissals` 查询所需索引。
- Popover 状态统一归口，避免 hover/click 状态漂移。

**交付物**

- `InboxViewModel`、`AutopilotViewModel`、`InsightViewModel` 等观察切片。
- `ChatMonitorState` 快照，scan 完成后按切片发布。
- `MessageBatchQuery`：按 chat usernames 批量解析 DB/table，减少每 chat 全库探测。
- 稳定 id 规范：所有 ForEach/List 使用 `msgUID`、`chatUsername`、`triggerMsgUID` 等业务 id。
- Panel focus policy 测试/手工 QA checklist。
- Instruments baseline 与优化后对比报告。

**主要风险与缓解**

- UI 拆分破坏现有 EnvironmentObject 引用：保留 `ChatMonitor` facade，对旧 View 暂时转发，逐屏迁移。
- LazyVStack 影响高度测量：先迁移内部列表，不改 panel 顶层测量机制；对 compact/extended 做截图和尺寸 QA。
- 批量 SQL 误读 WeChat 表：用现有 `getMessages` 作为 oracle，对同一 fixture 比较结果一致。

**成功指标**

- 一次 scan 后 SwiftUI invalidation 范围减少，至少不再因任一 AI/Autopilot 字段刷新整个 HUD。
- 1,000 条 inbox item 滚动不卡顿，无 row 展开状态丢失。
- 白名单 100 个 chat 的扫描 DB open/prepare 次数下降 50%+。
- `.extended` hover 不抢当前 App 焦点，点击交互仍可用。
- 相关 UI logic tests 与现有 350 测试通过。

---

### P3：AI 服务平台化与测试补齐，2-3 周

**目标**

把 7+ 个 AI service 中重复的 JSON 解析、重试、审计、活动跟踪、脱敏逻辑收敛为统一平台，降低后续改动风险。

**范围**

- 统一 `AIReplySuggester`、`AIBriefingGenerator`、`AIInboxSummarizer`、`AIChatInsight`、`AIGroupCatchup`、`AIDailyRetrospector`、`AIWhitelistCategorizer` 的调用骨架。
- 所有 AI 调用经过同一个 `AIRequestPipeline`。
- JSON extraction、strict retry、parse error audit、activity begin/end 统一。
- 审计日志默认只保存 redacted input/output + hash + byte/token count。
- 补齐 4 个无直接测试服务：
  - `AIBriefingGenerator`
  - `AIInboxSummarizer`
  - `AIChatInsight`
  - `AIActivityTracker`
- 现有 disabled live tests 保持 disabled，但增加 deterministic fake AI tests。

**交付物**

- `AIRequestPipeline<T: Decodable>` 或 `StructuredAIClient`。
- `PromptRequest`：role、promptVersion、system、userTemplateData、options、redactionPolicy。
- `AIResponseParser`：提取 fenced JSON、object boundary、schema decode。
- `AIAuditWriter`：统一审计，不由各服务各写一份。
- Fake `AIServiceProtocol` 测试双：返回成功 JSON、HTTP error、parse failure、retry success。
- AI 服务测试矩阵。

**主要风险与缓解**

- 大规模重构影响行为：先引入 pipeline 并迁移一个低风险服务，再逐个迁移；每迁移一个服务跑对应 golden tests。
- prompt 输出差异导致模型质量波动：保持 prompt 文本不变，只改变调用骨架。
- 审计字段变化影响 UI/回顾功能：提供 v1/v2 读取兼容，写入只写 v2。

**成功指标**

- AI 服务重复的 call/parse/retry/audit 代码减少 60%+。
- 4 个缺测服务均有直接单元测试。
- 每个 AI role 至少覆盖：成功、首轮 parse 失败后 retry 成功、HTTP error、审计写入。
- request recorder 证明所有 AI service 都经过脱敏 pipeline。
- 现有 350 测试 + 新 AI tests 通过。

---

### P4：模块化、DoS 防护与发布硬化，2-3 周

**目标**

清理中期架构债，降低未来变更成本，并解决测试/发布环境不稳定。

**范围**

- 拆分 Models.swift 75 个类型：
  - `AIModels.swift`
  - `InboxModels.swift`
  - `AutopilotModels.swift`
  - `RetrospectiveModels.swift`
  - `SettingsModels.swift`
  - `WeChatModels.swift`
- 完成 zstd 解压输出上限和 XML 文本累计上限。
- 实现 InboxRowView 空右键菜单动作：VIP 升降级、忽略发送人，或移除不可用菜单项。
- 统一 popover state ownership。
- 修复测试签名问题：区分 `swift test`、debug app、signed app。
- Release pipeline：build、test、权限检查、secret scan、basic manual QA checklist。

**交付物**

- 模型拆分 PR，纯移动类型，行为零变化。
- `BoundedZstdDecompressor`，最大输出例如 2-4 MB 可配置。
- `SimpleXMLParser` 增加 `maxTotalTextBytes` 与 `maxElementTextBytes`。
- `make test` 不依赖本机固定 signing identity。
- `make verify`：secret scan + swift test + swift build -c release。
- 发布前 checklist。

**主要风险与缓解**

- Models 拆分引入访问级别错误：纯移动，不重命名；每次移动一组类型并立即 build。
- zstd/XML 上限截断真实长消息：上限记录 telemetry/audit，UI 显示"内容过长已截断"。
- 签名修复影响本地运行：Makefile 保留 `SIGN_IDENTITY` override，并提供 ad-hoc/debug 路径。

**成功指标**

- `Models.swift` 降到 400 行以内或只保留核心共享类型。
- zstd/XML fuzz tests 不产生 OOM，超限可控失败。
- `make test` 在无开发证书机器可运行。
- `make verify` 一条命令完成发布前门禁。
- Secret scan 无高危命中。

---

## 技术决策记录 ADR

### ADR-001：Swift 6 严格并发采用渐进启用

**状态**：建议采纳。

**背景**：项目当前 Package 仍是 Swift tools 5.9，审计发现 `nonisolated(unsafe)`、`@unchecked Sendable`、`Task.detached` 跨 mutable state。一次性开启 complete strict concurrency 会造成大面积编译失败，影响 350 测试稳定性。

**决策**：P1 立即启用 targeted strict concurrency 和 `-warn-concurrency` 门禁；P2/P3 清完核心路径后开启 complete 作为 CI 非阻断 job；P4 转为阻断。

**备选**：立即 complete。优点是风险暴露最彻底；缺点是会把安全止血拖进大规模编译修复。

**后果**：能先修最高风险路径，同时不会让并发迁移无限期后移。

---

### ADR-002：Actor 化采用中粒度

**状态**：建议采纳。

**背景**：`HUDStore` 和 `WeChatReader` 都是有内部 mutable state 的大对象。SQLite FULLMUTEX 只保护 SQLite connection，不保护 Swift wrapper 状态、statement 生命周期和跨方法事务语义。

**决策**：建立中粒度 actor/facade：
- `HUDStoreActor` 串行化所有 SQLite 访问。
- `WeChatReaderActor` 保护 decrypted cache、keys、contacts、chatDBCache。
- `AIRequestPipeline` actor 处理 AI 调用共享状态。
- `ClipboardActor` 或 `@MainActor ClipboardService` 处理剪贴板。

**备选**：粗粒度全 App MainActor，简单但扫描/AI 会阻塞 UI；细粒度每表/每 cache actor，理论纯净但调用复杂。

**后果**：调用面可控，性能可通过批量 API 保持。

---

### ADR-003：数据脱敏在客户端强制执行

**状态**：建议采纳。

**背景**：AI 请求当前直接包含真实消息内容；审计日志也保存原始内容片段。任何远程模型或代理都不应收到未处理微信原文。

**决策**：客户端请求构造前强制脱敏。服务端/模型端只作为第二层，不作为信任边界。默认 remote provider 使用 strict redaction；local provider 可允许 relaxed，但仍脱敏 token/证件/密钥。

**备选**：只在云端 API gateway 脱敏。不适合当前可配置 OpenAI-compatible endpoint 架构。

**后果**：AI 效果可能轻微下降，但可通过稳定占位符和关系映射缓解。

---

### ADR-004：状态管理短期切片，长期新模块用 `@Observable`

**状态**：建议采纳。

**背景**：`ChatMonitor` 当前大量 `@Published` 导致任一字段变化可能影响整个 HUD 视图树。直接全量迁移 `@Observable` 风险大，且现有 SwiftUI EnvironmentObject 使用广泛。

**决策**：P2 先拆 ViewModel 切片并保留 `ObservableObject` facade；新模块和重写模块使用 `@Observable`。当 Swift 6.2 settings 稳定后，再评估全量迁移。

**备选**：一次性 `@Observable` 重写。风险是 UI 行为回归和测试大面积改动。

**后果**：性能收益可先落地，兼容现有视图和测试。

---

### ADR-005：测试策略为补齐风险测试，不重写历史

**状态**：建议采纳。

**背景**：已有 350 测试是重要资产，但存在 AI 服务缺测、测试签名问题和 live tests disabled。

**决策**：保持现有测试兼容；新增测试围绕安全、迁移、并发压力、AI pipeline、性能关键路径。新测试用 Swift Testing 或现有 XCTest 均可，但同文件风格保持一致。

**备选**：只测新增。无法防止重构破坏现有行为。全量重写测试则成本过高。

**后果**：每阶段都有明确回归门禁，同时避免测试迁移本身变成主项目。

---

## 风险矩阵

| 风险 | 概率 | 影响 | 阶段 | 缓解 |
|---|---:|---:|---|---|
| Keychain 迁移导致用户 API Key 丢失 | 中 | 高 | P0 | 两阶段迁移、读回验证、迁移前一次性本地备份提示 |
| 脱敏后 AI 质量下降 | 中 | 中 | P0/P3 | 稳定占位符、保留关系/时间/意图结构、对比 golden cases |
| Actor 化导致 scan 变慢 | 中 | 高 | P1 | 批量 API、减少 actor hop、Instruments 对比 |
| Swift strict concurrency 引发大量编译错误 | 高 | 中 | P1 | targeted 先行、complete 非阻断、按模块清单推进 |
| UI 切片破坏现有 hover/panel 行为 | 中 | 高 | P2 | 保留 facade、逐屏迁移、手工 QA checklist |
| LazyVStack 影响 panel 自适应高度 | 中 | 中 | P2 | 先内部列表迁移，固定测量边界，截图/尺寸验证 |
| AI pipeline 重构引入行为差异 | 中 | 高 | P3 | 单服务试点、prompt 不变、fake AI 覆盖 retry/audit |
| Schema 版本迁移破坏老用户 DB | 中 | 高 | P1 | fixture 覆盖旧版本、迁移幂等、失败回滚/备份 |
| 测试签名修复影响 app 打包 | 低 | 中 | P4 | test/debug/release 三路径分离 |
| Models 拆分造成访问级别/循环依赖问题 | 中 | 低 | P4 | 纯移动、小批量 build，不做语义重构 |

---

## 成功指标

### 全局完成指标

- 28 个审计问题全部关闭或有明确 ADR 例外。
- 现有 350 测试全部通过。
- 新增安全/并发/AI/迁移测试通过。
- `swift build -c release` 无新增 warning。
- secret scan 无真实 API Key。
- 默认配置下远程 AI 不接收未脱敏原文。
- 高消息量场景 HUD 可交互，无明显卡顿或焦点抢占。

### 阶段验收清单

| 阶段 | 必须通过的验证 |
|---|---|
| P0 | SQLite 无明文 key；Keychain mock 测试；AI request recorder 脱敏；文件权限测试；远程 HTTP 阻断 |
| P1 | SQLite 并发压力测试；schema migration fixture；targeted strict concurrency 无新增 warning；核心 unsafe 标记清零 |
| P2 | 100 chat 扫描性能对比；1,000 row UI 稳定；`.extended` 不抢焦点；List row state 不丢 |
| P3 | 4 个缺测 AI 服务补齐；所有 AI role 经 pipeline；retry/audit/redaction 测试通过 |
| P4 | `Models.swift` 拆分完成；zstd/XML fuzz 上限测试；无证书环境可跑 `make test`；`make verify` 成功 |
