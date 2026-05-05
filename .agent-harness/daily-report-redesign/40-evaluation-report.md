# Evaluation Report — 日报方案设计

## 评审方法
1. 直接检查产出物：30-generation-report.md 的 10 个章节是否完整
2. 对照 10-product-spec.md 验证覆盖度
3. 对照 20-evaluation-rubric.md 的 4 个维度评分
4. 检查技术可行性（与现有代码的兼容性）

---

## Findings（按严重程度排序）

### 🔴 严重问题

#### 1. WeChatReader 改动风险（数据完整性维度）
**问题**：方案提出在 `WeChatReader.swift` 中新增 `todayMessagesByChat` 批量查询方法。但 WeChatReader 是一个厚重的 SQLite 封装类，直接修改它可能引入回归风险。

**证据**：现有 `getMessages(chatUsername:limit:)` 方法已支持按 chat 查询消息，DailyChatScanner 可以直接复用它，不需要新增批量查询方法。Scanner 遍历 contacts 后逐个调用 `getMessages` 即可。

**建议**：移除对 `WeChatReader.swift` 的修改，改为在 `DailyChatScanner` 内部使用现有的 `WeChatReader.getMessages()`。

#### 2. actor 隔离问题（技术可落地性维度）
**问题**：`DailyReportBuilder` 被定义为 `struct`（非 actor），但它内部创建了 `DailyChatScanner`（actor）和 `DailyMessageDigest`（actor），并且调用了 `await`。

**证据**：ChatMonitor.loadDailyReport() 中创建 builder 的代码是同步的：
```swift
let builder = DailyReportBuilder(store: store, replyDebtItems: replyDebtItems, stats: stats)
let baseReport = builder.build()  // 当前是同步调用
```

如果 `build()` 改为 async，调用方需要 `await builder.build()`，这没问题。但更大的问题是 `DailyReportBuilder` 内部持有 `reader: WeChatReader`，而 WeChatReader 不是 Sendable。在 Swift 6 严格模式下，这会导致编译错误。

**建议**：
- `DailyReportBuilder` 改为 `actor DailyReportBuilder`
- 或者让 ChatMonitor 直接协调 Scanner + Digest + Generator，不需要 DailyReportBuilder 这个中间层
- 更简洁的方案：在 `ChatMonitor` 内部直接实现日报构建逻辑（它已经是 @MainActor，可以协调各个 actor）

#### 3. Prompt 输入 token 可能超预算（数据完整性维度）
**问题**：预算中 chat_digests 占 ~5000 tokens，但实际可能远超。8 对话 × 20 消息 × 平均 50 字/消息 = 8000 字 ≈ 10000+ tokens（中文 token 比例约 1:1.5）。

**证据**：prompt 中每条消息格式为 `[时间] 发送者: 消息内容`，平均一条消息约 60-80 字，20 条就是 1200-1600 字，8 个对话就是 9600-12800 字，加上其他内容，总输入可能达到 15000+ tokens，远超 8000 预算。

**建议**：
- 每对话消息上限从 20 降到 10
- 或总消息数硬上限 60 条（而非 8×20=160）
- 或增加动态截断：根据消息长度实时计算 token，超预算时截断

### 🟡 中等问题

#### 4. 缺少 token 计数实现（技术可落地性维度）
**问题**：方案提到「如果总输入预估 > 7500 tokens，自动缩减对话数或消息数」，但没有给出具体的 token 计数实现。

**建议**：使用简单的字节估算（中文 ≈ 字节数 / 3）或集成 tiktoken（但会增加依赖）。更实际的做法是：先按保守上限（5 对话 × 10 消息）生成，如果 output 质量低再逐步放宽。

#### 5. DailyReportWarmer 集成点不明确（用户体验维度）
**问题**：方案说在 AppDelegate 中启动 warmer，但没有明确说明在哪个生命周期方法中集成。AppDelegate 中已有大量初始化逻辑， warmer 的启动时机需要与现有逻辑协调。

**建议**：在 `applicationDidFinishLaunching` 中，在 `chatMonitor` 初始化完成后启动 warmer。或者在 `MenuBarController` 中按需启动（当用户首次打开 HUD 时）。

#### 6. 配置面板的持久化键命名（技术可落地性维度）
**问题**：使用 `@AppStorage` 的键名如 `"dailyReport.autoWarmup"` 是合理的，但项目中已有配置管理方案（如通过 `loadAIConfig()` 或 `HUDStore`），需要确认是否统一。

**建议**：使用 `UserDefaults` 是合理的（配置量小），但应在文档中说明配置迁移策略。

### 🟢 轻微问题

#### 7. `mood` 字段的价值不明确
**问题**：新增的 `mood` 字段（紧张/正常/松散）在 UI 中只有一个小标识，ROI 较低。可以保留但优先级低。

#### 8. 测试文件计划不完整
**问题**：方案只提到 2 个测试文件，但没有覆盖 `UnifiedDailyReportGenerator` 的测试（validateOutput 逻辑需要测试）。

**建议**：增加 `UnifiedDailyReportGeneratorTests.swift`。

---

## 评分

### 数据完整性：7/10
- ✅ 有独立的数据采集层（DailyChatScanner + DailyMessageDigest）
- ✅ 覆盖聊天记录、asks、commitments、reply debt 等多源数据
- ✅ 有消息筛选/去噪策略
- ⚠️ Token 预算可能不足（chat_digests 估算偏乐观）
- ⚠️ 没有给出 token 动态截断的具体实现

### AI 生成质量：8/10
- ✅ Prompt 充分利用原始数据（消息摘要 + 聚合指标）
- ✅ 有多层防幻觉机制（prompt 约束 + schema 关联 + heuristics）
- ✅ 有 retry + fallback 策略
- ✅ wechatDraft 采用三段式结构
- ⚠️ 没有给出 prompt 的实测输出示例

### 技术可落地性：7/10
- ✅ 数据模型与现有模型兼容（只新增 Optional 字段）
- ✅ 服务拆分遵循现有架构模式
- ✅ 有明确的改造范围
- ✅ 向后兼容
- ⚠️ actor 隔离问题（WeChatReader Sendable）
- ⚠️ WeChatReader 改动不必要
- ⚠️ DailyReportBuilder 的 async 改造需要仔细处理

### 用户体验：8/10
- ✅ 有自动预热/缓存机制
- ✅ 失败时有错误信息和重试入口
- ✅ 有数据来源标识
- ✅ 一键复制已有
- ⚠️ 配置面板设计较简单，缺少高级选项

### 总分：7.5/10

---

## Pass/Fail

PASS

方案整体设计合理，核心思路（轻量级扫描 + 丰富 prompt 输入 + 统一生成器）正确。但需要在实施前修正以下阻塞问题：

1. **移除对 WeChatReader.swift 的修改** — 复用现有 `getMessages()`
2. **解决 actor 隔离问题** — 要么让 DailyReportBuilder 成为 actor，要么将逻辑移到 ChatMonitor
3. **收紧 token 预算** — 每对话消息上限降到 10，或总消息数上限 60

这三个问题修正后，方案可以进入实现阶段。

---

## 残留风险

1. **Prompt 调优工作量**：新 prompt 的实际输出质量需要大量实测调优，这部分工作量在方案中低估了。建议预留 1-2 天专门做 prompt 调优。
2. **群聊噪音**：即使消息筛选后，大群的消息仍可能稀释日报质量。建议增加「群聊消息数占比上限」（如群聊消息不超过总消息的 40%）。
3. **AI provider 稳定性**：如果用户使用的是不稳定的 AI provider（如某些免费 API），retry 策略可能不足以保证成功率。建议增加「完全离线模式」开关。
