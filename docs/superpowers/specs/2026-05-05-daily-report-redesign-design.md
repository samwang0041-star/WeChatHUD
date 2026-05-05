# 日报 Tab 重构设计规范 v0.1

**Date**: 2026-05-05
**Status**: Draft (pending GATE 1 user review)
**Replaces**: 现有 `DailyReportCommandCenterView` 的渲染策略与单层视图组合方式
**保留**: `DailyReport` / `DailyReportBuilder` / `DailyReportPresentationPolicy` / `DailyReportCommandState` 的数据流与持久化层（仅做扩展，不重写）

---

## 0. 背景与"不可用"根因

用户截图显示 Settings 浅色仪表盘下打开 `日报` tab，仅可见 `0/1`、`紧急/已超期1时`、`AI 洞察` 几个文字片段，整个面板大量空白、内容塌陷。代码侧确认到三类根因：

1. **配色硬编码 dark** — `DailyReportCommandCenterView` 全文使用 `.white.opacity(0.x)`、`Color.white.opacity(0.04)` 等显式深色 HUD 配色。在 Settings 浅色背景下，前景白字与白底融为一体，主文案近乎不可见，只剩自带颜色（绿/红/橙/cyan）的标签露出。
2. **嵌套 ScrollView** — 调用方 `SettingsView.swift:204` 与 `ExtendedTabsView.swift:74` 都已在外层包了 `ScrollView`，但 `DailyReportCommandCenterView.swift:31` 内部又自起一个 `ScrollView`，造成二级滚动容器。SwiftUI 在该组合下会出现内容压平、可视高度计算错乱（用户感知为"页面残破"）。
3. **缺少视觉验证回归** — 之前 e2e（`.agent-harness/daily-report-real-e2e-20260505/`）只跑了 `swift test`，没有跑 macOS UI；视觉破坏（白底白字 + 双滚动）被绕过。

这三条共同导致"日报数据在内存里都对，但 UI 拼不出可读页面"的状态。

---

## 1. 功能定位与目标

### 1.1 目标

把日报从"AI 增强后的一日小结"产品定位升级为**每日多次使用的"调度表"**：

- 用户每天会主动打开 ≥3 次（晨间扫一眼、午后跟进紧急项、傍晚收尾）。
- 主操作是**"决定下一步该做什么"**，不是"读总结"。
- AI 的角色从"写一段叙述"变成**"为每一条紧急 / 关键项给出『为什么紧急 / 怎么推进』的一句话注释"**——回归到行级解释，而非段落总结。
- 同一份内容必须在 **HUD 浮窗（深色）** 和 **Settings 仪表盘（浅色）** 两个表面下都可读、可操作、布局不破。

### 1.2 非目标

- 不重写 `DailyReportBuilder` 的数据装配逻辑（已经稳定）。
- 不替换 `AIDailyReportGenerator`（继续作为"段落型 AI 总结"的兜底；M2 新增 per-row generator 不取代它）。
- 不引入新的滚动/手势/拖拽交互，本次只解决"可读 + 可操作 + 可调度"的产品化基线。
- 不做菜单栏 icon 联动、通知推送、跨设备同步——这些是后续 milestone。

### 1.3 里程碑划分

**M1 产品化基线（独立可发布）**

仅修可读性与布局：消灭"不可用"。需求：

- 双表面（深 / 浅）渲染均可见、对比度合规
- 移除嵌套 ScrollView 引起的塌陷
- 信息架构按"调度表"重排
- 紧急项默认露出操作按钮（不再需要 hover 才能完成）
- 无新数据字段、无新表、无新 prompt

**M2 逐条 AI 注释（独立可发布）**

在 M1 的 UI 容器上叠加一层 per-action 的 AI 解释：

- 每条紧急 / 高优先级 action 配一条 `aiReason`（≤30 字）和 `aiNextStep`（≤40 字）
- 单次批量调用，缓存到 SQLite，UI 渐进显示
- 失败时 row 仍可用，仅不显示注释

M1 与 M2 之间任何一个 PR 单独合都能让用户拿到价值；不强制绑死。

---

## 2. 渲染表面策略

### 2.1 双表面问题

`DailyReportTabView` 同时被两条路径调用：

- **HUD 浮窗** — `ExtendedTabsView.swift:83`，外层 `Color.black.opacity(0.85)` 暗背景
- **Settings 仪表盘** — `SettingsView.swift:217`，外层 `NSColor.windowBackgroundColor`（浅色 / Aqua）

旧实现假设永远在深色 HUD 下，这是配色错误的根。

### 2.2 决策：单视图 + 语义色 + 显式表面 token

不拆两套视图。重构后 `DailyReportCommandCenterView` 只允许使用以下三类颜色：

| 用途       | Token                                    | 备注                          |
| ---------- | ---------------------------------------- | ----------------------------- |
| 主文案     | `.primary`                               | 自动 light/dark 翻转          |
| 次要文案   | `.secondary`                             | 时间戳、来源、计数            |
| 容器底     | `Color(NSColor.controlBackgroundColor)`  | 卡片、分隔区                  |
| 弱分隔     | `Color.primary.opacity(0.08)`            | 用 `.primary` 而非 `.white`   |
| 强调色     | `.red / .orange / .yellow / .green / .cyan` | 不与背景对比；保持饱和度即可 |

**禁止再出现 `Color.white.opacity(...)`、`Color.black.opacity(...)`** 作为前景或文本颜色。grep 把控。

为兼容 HUD 浮窗的纯黑底，外层在 HUD 路径包裹一个 `.preferredColorScheme(.dark)` 容器（仅作用于这个 tab 的子树），让 `.primary` 自动算成白色；Settings 路径不加，沿用系统色方案。这样视图本身不分歧，分歧只在外层 wrapper 一行。

### 2.3 移除内层 ScrollView

`DailyReportCommandCenterView` 当前的 `ScrollView` 直接删掉。改为：

- 视图根输出 `VStack(alignment: .leading, spacing: 0)`，由调用方决定是否包 ScrollView
- 在 HUD 与 Settings 两个调用点都已有外层 ScrollView，不需要新增任何 wrapper

唯一例外：草稿卡的长文本若超出，可在草稿卡内部用 `.lineLimit(nil)` + `.fixedSize(horizontal: false, vertical: true)` 让外层 ScrollView 自然处理。

---

## 3. 信息架构（"调度表"心智模型）

### 3.1 段落顺序

从上到下：

```
┌──────────────────────────────────────┐
│ ① 进度卡（保留）                      │  ← 一眼看完成度
├──────────────────────────────────────┤
│ ② 🔴 紧急 / 已超期      [N]          │  ← 当下要立刻处理
│   - 卡片：内容 + 来源 + 截止          │
│   - 操作按钮：[完成] [打开微信]       │  默认显示，非 hover
│   - (M2) AI 一句注释 + 下一步建议      │
├──────────────────────────────────────┤
│ ③ 📋 待处理 · 今天到期   [N]          │  ← 待处理按截止分三桶
│ ④ 📋 待处理 · 本周到期   [N]          │
│ ⑤ 📋 待处理 · 之后 / 无期限 [N]       │
│   - 卡片：内容 + 来源 + 截止          │
│   - 操作按钮：[完成] [打开微信]       │  默认显示
├──────────────────────────────────────┤
│ ▸ ✅ 已完成      [N]   (折叠 / 默认收) │
├──────────────────────────────────────┤
│ ▸ 📌 今日高亮    [N]   (折叠 / 默认收) │
├──────────────────────────────────────┤
│ ▸ ⚠️ 风险与异常  [N]   (折叠 / 默认收) │
├──────────────────────────────────────┤
│ 💡 一日小结（默认展开 / AI 段落型）    │  ← 旧的 narrative + tomorrowFocus
├──────────────────────────────────────┤
│ 📋 微信日报草稿 + [复制]               │  ← 保留
└──────────────────────────────────────┘
```

### 3.2 设计取舍

| 项                | 决策                              | 理由                                                                 |
| ----------------- | --------------------------------- | -------------------------------------------------------------------- |
| 紧急/待处理分两段 | 保留                              | 用户进入页面 80% 是问"现在最该干什么"，紧急要顶置                    |
| 待处理按截止分桶  | 三桶（今天 / 本周 / 之后）        | 调度表本质是 deadline-first；urgency raw 排序在桶内做                |
| 已完成折叠        | 折叠且默认收                      | 完成项是确认信号，不是工作信号；点开才看                             |
| 高亮折叠          | 折叠且默认收                      | 高亮属于 retrospective，不是当日调度的输入                           |
| 风险折叠          | 折叠且默认收                      | 多数风险（撤回 / 不确定）是观察类信号，不阻塞调度                    |
| AI 小结展开       | 展开 / 留底部                     | 一日小结仍有"通读一遍"的价值，但不应抢顶部 attention                 |
| 操作按钮露出      | 默认显示，hover 时高亮            | 调度表场景需要"瞥一眼即点"；hover-only 在浮窗 hover-dismiss 下不可达 |
| 日期导航 `[< >]`  | 保留                              | 历史复盘是高频访问                                                   |

### 3.3 空态

- **整页无数据** — "今日没有需要调度的事项。" + 副提示 "复盘 / 紧急 / 待回复均为空。"
- **仅紧急为空** — 段落标题不渲染，跳过整段（避免空标题）
- **AI 小结无内容** — 不渲染整段
- **草稿无内容** — 不渲染整段

折叠段标题在 count = 0 时也不渲染。

---

## 4. 视觉细节

### 4.1 字号与间距

| 元素             | 字号  | 字重         |
| ---------------- | ----- | ------------ |
| 段标题（emoji + 文字） | 12pt  | semibold     |
| 段计数 `[N]`     | 10pt  | regular      |
| 卡片主文案       | 13pt  | medium       |
| 紧急卡主文案     | 13pt  | semibold     |
| 来源 / 截止 / 元信息 | 10pt  | regular      |
| 进度卡数字       | 11pt  | semibold     |
| AI 注释（M2）    | 11pt  | regular(italic) |

卡片圆角 `8pt`；卡片左侧紧急色条 `width: 3pt, cornerRadius: 1.5pt`。卡片间垂直间距 `4pt`，段间垂直间距 `12pt`，段内段标题距首卡 `6pt`。横向 padding 统一 `12pt`。

### 4.2 颜色映射（urgency / severity）

```swift
critical → .red
high     → .orange
medium   → .yellow
low      → .secondary       // 低优先级不抢色
```

风险 severity 同上。已完成项主文案使用 `.secondary` + strikethrough。

### 4.3 折叠组件

使用 SwiftUI `DisclosureGroup`，自定义 label：左侧 chevron + emoji + 文字 + 计数。展开/收起状态由本地 `@State` 维护，不持久化到 SQLite（轻量交互，刷新页面后回到默认收起即可）。

### 4.4 操作按钮

- `[完成]` — 绿底色 12% / 前景 `.green` / `checkmark` 图标 + "完成" 文字。点击后立即 strikethrough 该卡，状态进入 `DailyReportCommandState.completed`。
- `[打开微信]` — 中性底 12% / `.secondary` / `bubble.left.and.bubble.right`。`WeChatLauncher.openChat(named:)`。
- 紧急 / 待处理段：默认显示这两个按钮，hover 时给一个 `.opacity(1.0)` 与轻微 background 高亮。
- 已完成段：仅显示 `[撤销]`（点击后 `clearDailyReportCommandState`，回到原 urgency 桶）。M1 阶段可暂不实现撤销；M2 再加。

---

## 5. M2 — 逐条 AI 注释

### 5.1 目标

把"AI 帮我理解为什么紧急、下一步该怎么做"做成行级体验：

- 每条 **紧急（critical / high）** action 配一对 `aiReason` + `aiNextStep`
- `aiReason` ≤ 30 字，回答"**为什么这条要立刻处理**"（依据 deadline / 来源对话最近一条上下文 / 承诺类型）
- `aiNextStep` ≤ 40 字，回答"**下一步具体做什么**"（一个动词起手的祈使句：回复、催促、确认、决策）

### 5.2 调用策略

- **批量单次调用，不为每条单独调一次。** 把当日所有紧急 + 高优先级（最多 12 条）打包成一个 prompt，AI 一次性返回 JSON 数组。理由：成本可控、并发简单、retry 模型现成。
- 调用时机：`loadDailyReport` 内 base report 装配后，作为第二阶段（与现有 `AIDailyReportGenerator.enrich` 并行触发；两者结果回填同一份 `DailyReport`）。
- 不阻塞 UI：M1 的卡片立即显示，AI 注释作为 placeholder（细灰文案 "正在生成…" 或不渲染），完成后通过 `@Published` 再触发一次刷新。
- 缓存：以 `(dateKey, actionID)` 为主键写到新表 `daily_report_action_insights`，命中即不再调 AI。`actionID` 来自现有 `DailyReportAction.id`（已稳定 = `"\(type.rawValue)-\(relatedID)"`）。

### 5.3 失败兜底

- AI 调用失败 / JSON 解析失败：行卡片正常显示，仅不渲染注释区块。
- 部分行未返回（数组长度不一致）：以 `actionID` 匹配，匹配上的就用、匹配不上的不渲染。
- 整体失败写入 `ai_audit` 一条 `parseError`/`httpError`，便于事后追查。

### 5.4 Prompt 草稿

```
你是工作调度助手。下面是用户今天 N 条紧急或高优先级事项。
为每条返回一个对象，包含：
- id: 原 ID 原样回填
- reason: ≤30 字，解释"为什么必须立刻处理"。基于 deadline、来源、类型。不要复述 content。
- next_step: ≤40 字，给出"下一步具体动作"。动词开头，祈使句。

输入：
1. id="commitment-xxx" type=承诺 source="王总" deadline="2026-05-05 18:00" content="..." 距现在=2 小时
2. ...

只输出 JSON 数组：[{"id":"...", "reason":"...", "next_step":"..."}, ...]
```

prompt 模版以 `.txt` 形式落到 `Sources/WeChatHUD/Resources/Prompts/daily_report_action_insights_v1.txt`（与现有 `daily_report_v1.txt` / `classifier_v1.txt` 等同目录同后缀），由 `PromptLoader.load(version:)` 读取，沿用 `AIDailyReportGenerator` 的版本管理约定。

---

## 6. 数据模型与持久化

### 6.1 新增类型

```swift
struct DailyReportActionInsight: Sendable, Codable {
    let dateKey: String          // "yyyy-MM-dd"
    let actionID: String         // 与 DailyReportAction.id 对齐
    let reason: String           // ≤30 字
    let nextStep: String         // ≤40 字
    let modelVersion: String     // "daily_report_action_insights_v1"
    let generatedAt: Date
}
```

### 6.2 新增 SQLite 表

```sql
CREATE TABLE IF NOT EXISTS daily_report_action_insights (
    date_key       TEXT NOT NULL,
    action_id      TEXT NOT NULL,
    reason         TEXT NOT NULL,
    next_step      TEXT NOT NULL,
    model_version  TEXT NOT NULL,
    generated_at   INTEGER NOT NULL,
    PRIMARY KEY(date_key, action_id)
);
CREATE INDEX IF NOT EXISTS idx_action_insights_date ON daily_report_action_insights(date_key);
```

迁移沿用现有 `migrateDailyReportState` 的 `IF NOT EXISTS` 模式；`HUDStore+DailyReport.swift` 增加 `upsertActionInsight / loadActionInsights(dateKey:)` 两个方法。

### 6.3 视图模型扩展

`DailyReportPresentationPolicy.CommandCenterViewModel` 新增字段：

```swift
let actionInsights: [String: DailyReportActionInsight]   // key = action.id
```

`buildViewModel(from:commandStates:insights:)` 新增第三个参数；现有调用点（`DailyReportCommandCenterView`、`ChatMonitor.exportDailyReport`）传入 `store.loadActionInsights(dateKey:)` 的结果。

### 6.4 不动的部分

- `DailyReport` struct 不加新字段（insight 不放进 report，由 view-model 层 join 上去）
- 现有 `daily_report_state` / `daily_report_snapshots` 表不动
- `AIDailyReportGenerator` 完全保留（继续生成段落型 narrative / tomorrowFocus / wechatDraft）

---

## 7. 服务层接线

### 7.1 新生成器：`AIDailyReportActionInsightGenerator`

文件：`Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift`

```swift
actor AIDailyReportActionInsightGenerator {
    init(aiService: AIService, store: HUDStore, promptLoader: PromptLoader = PromptLoader())

    /// 输入紧急 + 高优先级 actions（≤12），回填 store。返回成功生成的 insight 数组（也已落库）。
    /// 失败时返回空数组并写 audit；不抛异常。
    func generate(for actions: [DailyReportAction], dateKey: String) async -> [DailyReportActionInsight]
}
```

实现要点：

- 命中 store 缓存的不再调 AI（按 `actionID` 过滤）
- 仅未命中部分进 prompt
- JSON 解析复用 `AIJSONExtractor.decodeFirstObject`
- 单次失败 retry 一次（与 `AIDailyReportGenerator.enrich` 一致）
- 写 `AIAudit` 角色暂用 `.retrospector`（避免新增枚举），label 用 `daily_report_action_insights_v1`

### 7.2 ChatMonitor 接线

新增 `@Published var dailyReportActionInsights: [String: DailyReportActionInsight] = [:]`。

`loadDailyReport(for:force:)` 改造（伪代码）：

```swift
let baseReport = builder.build(for: date)
self.dailyReport = baseReport
self.dailyReportActionInsights = store.loadActionInsights(
    dateKey: date.dailyReportDateKey
).reduce(into: [:]) { $0[$1.actionID] = $1 }

async let enrichedReport = dailyReportGenerator.enrich(baseReport)
async let insights = actionInsightGenerator.generate(
    for: baseReport.actions.filter { $0.urgency == .critical || $0.urgency == .high },
    dateKey: date.dailyReportDateKey
)

self.dailyReport = await enrichedReport
let newInsights = await insights
for ins in newInsights { self.dailyReportActionInsights[ins.actionID] = ins }
```

并发用 `async let` 同时拉两个；任一失败不影响另一个。

`DailyReportCommandCenterView` 通过 `monitor.dailyReportActionInsights` 取 insight，传给 `buildViewModel`。

### 7.3 配置

`AIDailyReportActionInsightGenerator` 可被关闭：在 `AIConfig` 增加 `dailyReportActionInsightsEnabled: Bool = true`。关闭时 `ChatMonitor` 不调 generator，UI 自动回退到 M1 形态（无注释）。

---

## 8. 测试策略

### 8.1 单元

| 测试文件                                    | 覆盖                                                                |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `DailyReportPresentationPolicyTests`（已有） | 新增「按截止分桶」、「insight 注入」case；调整因 urgent + active 重新分组带来的现有断言 |
| `DailyReportBuilderTests`（已有）            | 不动（builder 不变）                                                |
| `AIDailyReportGeneratorTests`（已有）        | 不动                                                                |
| `AIDailyReportActionInsightGeneratorTests`（新建） | prompt 渲染、JSON 解析（含 retry / 部分匹配）、缓存命中跳过、空输入直返 |
| `HUDStoreDailyReportTests`（已有）           | 新增 `daily_report_action_insights` 表的 upsert / load / 跨日隔离  |

### 8.2 集成

`ChatMonitor` 的 `loadDailyReport` 现有测试（如有）扩展：mock `actionInsightGenerator`，验证 base report 立即可见、insights 后置回填、失败时 dict 保持空。

### 8.3 视觉验证（本次必须新增）

之前 e2e 只跑 `swift test`，没看 UI 是问题源头之一。M1 完成后必须人工：

1. 在 macOS 上 `swift run`，打开 Settings → 日报 tab，肉眼确认主文案可见、对比度足够、无塌陷
2. 同样在 HUD 浮窗点开 日报 tab，确认深色下也可读
3. 制造一组测试数据（紧急 1 条 + 待处理 3 条 + 已完成 2 条 + 高亮 1 条 + 风险 1 条），截图归档到 `docs/superpowers/specs/screenshots/2026-05-05-daily-report-{light,dark}.png`

M1 PR 描述里贴这两张图作为验收凭据。M2 PR 同样新增一张含 `aiReason / aiNextStep` 的截图。

### 8.4 不需要测的

- 段落折叠的 SwiftUI 状态保持（DisclosureGroup 自带）
- 日期 `[< >]` 按钮（行为未改）
- Markdown 导出（不变；若 6.3 引入 insight，可在 export 中追加；M2 决定）

---

## 9. 落地与上线

### 9.1 文件清单

**新建**

- `Sources/WeChatHUD/Services/AIDailyReportActionInsightGenerator.swift`
- `Sources/WeChatHUD/Resources/Prompts/daily_report_action_insights_v1.txt`
- `Tests/WeChatHUDTests/AIDailyReportActionInsightGeneratorTests.swift`
- `docs/superpowers/specs/screenshots/2026-05-05-daily-report-light.png`（PR 时附上）
- `docs/superpowers/specs/screenshots/2026-05-05-daily-report-dark.png`

**修改**

- `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift` — 全文换语义色 + 删内层 ScrollView + 三桶分组 + 默认按钮露出 + 折叠组件 (M1)；新增 insight 渲染 (M2)
- `Sources/WeChatHUD/Views/DailyReportTabView.swift` — 在 HUD 路径包 `.preferredColorScheme(.dark)` 包装；其它不动
- `Sources/WeChatHUD/Data/DailyReportPresentationPolicy.swift` — `buildViewModel` 加 `insights` 参数；新增"待处理三桶"输出字段；不破坏现有调用方先做 default 参数 + 改造调用方
- `Sources/WeChatHUD/Data/HUDStore+DailyReport.swift` — 增 insight 表迁移与 CRUD
- `Sources/WeChatHUD/Data/DailyReportCommandState.swift` 或新建 `Data/DailyReportActionInsight.swift` — 放新结构体
- `Sources/WeChatHUD/Services/ChatMonitor.swift` — 注入 insight generator + `@Published` insight 字典 + `loadDailyReport` 并发改造
- `Tests/WeChatHUDTests/DailyReportPresentationPolicyTests.swift` — 三桶 + insight 注入断言
- `Tests/WeChatHUDTests/HUDStoreDailyReportTests.swift` — insight 表 CRUD

**删除**

- 无（保持向后兼容；旧字段全保留）

### 9.2 上线顺序

1. **PR-A（M1 / 渲染基线）**：仅前两类修改 + presentation policy 三桶 + 测试。该 PR 单独合就让用户看到可读的日报。CI 必须包含截图 attachment。
2. **PR-B（M2 / 数据层）**：建表 + 模型 + store 方法 + 单测。空 generator wiring（注入但不调用），保证表迁移先就位。
3. **PR-C（M2 / 生成器与接线）**：新 generator + ChatMonitor 改造 + UI 渲染 insight 区块 + Prompt 资源 + 单测 + 截图。
4. **PR-D（M2 / 配置开关与文档）**：`AIConfig.dailyReportActionInsightsEnabled` 暴露给 Settings → AI → 高级；README/帮助文案更新。

每个 PR 单独可回滚：

- PR-A 回滚 = 回到坏版本，但 base report 数据仍对（仅 UI 烂）
- PR-B 回滚 = 删表、无影响（PR-C 没合）
- PR-C 回滚 = M1 形态，insight 字典恒空
- PR-D 回滚 = 默认开启状态

### 9.3 灰度

不做服务端灰度。本地开关 `dailyReportActionInsightsEnabled` 默认 true；用户在 AI 设置面板可关。

### 9.4 风险与缓解

| 风险                                            | 缓解                                                          |
| ----------------------------------------------- | ------------------------------------------------------------- |
| `.preferredColorScheme(.dark)` 影响 HUD 其它子树 | 只在 `DailyReportTabView` 根 wrapper 上加；外层 tab 切换不受影响 |
| 三桶分组让"今天没有 deadline 的紧急项"无处放    | 紧急段早于三桶段，紧急项不进桶；只有非紧急 + 无 deadline 的归到「之后」桶 |
| AI insight 生成抢 `AIService` 限流              | 共用 `AIActivityTracker.shared`；同一 dateKey 缓存命中跳过；retry 上限 1 |
| 旧用户 `daily_report_action_insights` 表不存在 | `migrateDailyReportState` 中追加 `CREATE TABLE IF NOT EXISTS`，启动即自愈 |
| 视觉 regression 再次溜进 main                   | M1 PR 强制截图证据；CI 暂不强制 UI 截图（后续 milestone）       |

---

## 10. 开放问题（不阻塞本 spec）

以下交给后续 milestone 或 plan 阶段细化，不影响本 spec 通过：

- `[推迟到明天]` 操作是否要做（§4.4 已敲定撤销留到 M2，但推迟尚未列入任一里程碑）
- 是否把 insight 也写入 markdown 导出（M2 开关：true/false）
- 移动到「复盘 tab」的 7 天总览改造是否需要类似配色重构（建议复用 §2 token，但不在本 spec 范围）
- 进度卡是否合并 urgentCount 显示（"今日 0/5 完成 · 紧急 2"）

---

## 11. Glossary

- **action** — `DailyReportAction`，统一表达 todo / commitment / replyDebt / ask 四类待办
- **insight** — M2 引入的 per-action AI 注释 `(reason, nextStep)`
- **dateKey** — `Date.dailyReportDateKey`，"yyyy-MM-dd"，作为 SQLite 主键的一部分
- **actionID** — `DailyReportAction.id`，格式 `"<type>-<relatedID>"`，跨刷新稳定
- **bucket** — 待处理三桶："今天到期 / 本周到期 / 之后 · 无期限"
