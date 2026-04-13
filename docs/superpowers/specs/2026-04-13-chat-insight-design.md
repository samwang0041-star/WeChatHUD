# ChatInsight — 聊天洞察系统

## 核心理念

帮用户 1 分钟看到所有聊天的全貌，更重要的是看到**文字背后看不到的东西** — 情绪暗流、态度信号、关系变化、被忽略的信息、跨群的因果链。

这不是聊天记录的摘要工具，是**通信态势感知系统**。

## 设计原则

- **简报优先**：打开就是全局简报，不需要点击就能了解全貌
- **隐性信号**：重点分析文字看不到的 — 语气变化、沉默、撤回、回避
- **跨群关联**：同一个话题在不同群/私聊的讨论自动关联
- **按需钻入**：全局看完，需要深入再点进去

## 信息层次

```
第一眼（3秒）：有没有火要救？
第二眼（10秒）：今天整体什么情况？
第三眼（30秒）：每个群/人在聊什么？谁的态度有变化？
钻入（按需）：某个群/人的完整分析
搜索（按需）：某个话题的跨群画像
```

---

## 视图架构

### 1. 主视图：全局简报（ChatInsightView）

一个可滚动的简报流，AI 生成，按优先级排列。

```
┌─────────────────────────────────────────┐
│  📅 4月13日 聊天简报              今天 ▾ │
│                                         │
│  ── 🔴 需要你行动 ──────────────────── │
│  按紧急程度排序，显示等待时间            │
│                                         │
│  ── 📊 今日全景 ────────────────────── │
│  统计数据 + AI 2-3句话全局概括          │
│                                         │
│  ── 🏢 工作 ────────────────────────── │
│  每个工作群一张卡片：                    │
│    群名 + 消息数 + 趋势                 │
│    在聊什么（话题标签）                  │
│    情绪 + 情绪变化原因                  │
│    和我相关的事                          │
│    ▸ 详情                               │
│                                         │
│  ── 🏠 生活 ────────────────────────── │
│  同上                                   │
│                                         │
│  ── 👤 私聊重点 ─────────────────────── │
│  每个有互动的私聊一张卡片               │
│                                         │
│  ── 🔗 跨群话题 ─────────────────────── │
│  AI 检测到跨群讨论的话题                 │
│  各群讨论角度 + 信息冲突点               │
│                                         │
│  ── 🔇 暗信号 ──────────────────────── │
│  沉默分析 + 撤回消息 + 语气变化          │
│                                         │
│  ── 🔍 搜索 ────────────────────────── │
│  关键词语义搜索入口                      │
└─────────────────────────────────────────┘
```

**排序逻辑**：
- 工作群/私聊按 `categoryWeight × 1000 + messageCount × 10 + hasActionForMe × 500` 排序
- categoryWeight: work=3, life=2, other=1
- 需要我行动的永远在最前面

**时间选择器**：今天 | 7天 | 30天，全局生效。

### 2. 详情视图（ChatInsightDetailView）

点击任何群/人的卡片进入。

**群聊详情**：
- 在聊什么：话题列表，每个话题的讨论摘要、状态、参与人
- 和我相关：@我、等我做什么、我的承诺
- 群氛围：情绪 + 情绪转折点 + 触发事件 + 信噪比 + 决策效率
- 谁在说话：参与者角色标注（推动者/决策者/执行者/反对者/旁观者）
- 隐性信号：语气变化、沉默者、撤回消息、被忽略的发言
- 跨群关联：这个群的话题也在哪里讨论
- 画像分析：AI 深度洞察 + 行动建议

**私聊详情**：
- 聊了什么：话题列表 + 摘要
- 关系信号：升温/降温/平稳 + 依据
- 语气分析：措辞变化、回复速度变化、消息长度变化
- 跨群关联：你和这个人在哪些群有共同话题
- 画像分析：AI 洞察 + 建议

### 3. 跨群话题视图（TopicCrossView）

点击跨群话题进入。

- 各群/私聊里关于这个话题的讨论（分来源展示）
- 合并时间线
- 信息冲突检测（产品群说 4/20，开发群说 4/25）
- 干系人图：谁是推动者、谁在阻塞
- 话题状态 + AI 建议

### 4. 关键词搜索视图（KeywordInsightView）

搜索栏输入关键词，AI 语义匹配（不是字面匹配）。

- 从已缓存的各聊天分析结果中筛选相关话题
- 收集相关消息，调用 AI 生成话题画像
- 输出：话题全景、时间线、干系人、状态、建议

---

## 隐性信号分析（核心差异化）

### 语气与态度分析

AI 在分析每条消息时，不仅看内容，还看表达方式：

**信号类型**：

| 信号 | 示例 | 含义 |
|------|------|------|
| 回复缩短 | "好的我看看" → "收到" | 敷衍或距离感 |
| 标点变化 | "好。" vs "好！" vs "好~" | 正式/热情/轻松 |
| 语气词选择 | "嗯嗯" vs "好的" vs "行" | 不同程度的认同 |
| 回复速度变化 | 平时5分钟，今天2小时 | 优先级下降或忙 |
| 消息长度变化 | 平时一段话，今天一个字 | 失去耐心或兴趣 |
| 主动性变化 | 以前主动找你，现在只回复 | 关系可能在降温 |
| 话题回避 | 你问A，他回答B | 刻意绕开 |
| 表情包变化 | 从丰富表情到纯文字 | 情绪变冷 |

**态度分类**（对某个话题/提议的反应）：

| 态度 | 典型表达 | AI 标注 |
|------|---------|--------|
| 真正支持 | "这个思路不错！具体怎么落地？" | 积极推进 |
| 表面配合 | "好的，我看看" | 观望，未承诺 |
| 敷衍 | "收到" / "嗯" | 不关心 |
| 隐性反对 | "这个...要再想想" / 沉默 | 不认同但不直说 |
| 显性反对 | "我觉得不太行" | 直接反对 |
| 推卸 | "这个你找XX吧" | 不想参与 |

### 沉默分析

纯算法，不需要 AI：

- 计算每个人的日均发言量（7天滚动平均）
- 今天发言量 < 平均的 30% → 标记为"异常沉默"
- 对比他在其他群的活跃度 → 判断是"整体不在线"还是"选择性沉默"
- 群里提到他但他没回应 → 高信号

### 撤回消息整合

已有 `recalled_messages` 表数据，直接关联到分析：

- 撤回的消息内容是什么（如果抓到了原文）
- 撤回的时间上下文 — 在讨论什么时撤回的
- 撤回后发了什么替代消息
- AI 分析撤回的可能原因

### 被忽略的发言

- 群里某人的消息发出后 10 分钟内无人回复/引用
- 如果这个人平时的消息有人回应 → 这次被忽略是异常
- 分析被忽略消息的内容 — 是不合时宜、不受欢迎、还是被淹没

---

## 数据模型

### 分析结果结构

```swift
struct ChatInsightResult: Codable {
    // ── 内容层 ──
    let headline: String                  // 一句话概括
    let topics: [TopicInsight]            // 话题列表
    let decisions: [String]               // 已做的决策
    let actionItems: [ActionItem]         // 待办事项

    // ── 和我相关 ──
    let mentionsMe: Int                   // @我次数
    let waitingForMe: [WaitingItem]       // 等我做什么 + 等了多久
    let myCommitments: [String]           // 我承诺了什么
    let needsMyAttention: Bool            // 是否需要关注

    // ── 情绪维度 ──
    let overallMood: String               // 焦虑/轻松/正式/紧张/正常
    let moodShift: MoodShift?             // 情绪转折
    let attitudes: [AttitudeSignal]?      // 关键人对关键话题的态度

    // ── 隐性信号 ──
    let toneChanges: [ToneChange]?        // 语气变化
    let silentMembers: [SilentMember]?    // 异常沉默的人
    let recalledMessages: [RecalledNote]? // 撤回消息分析
    let ignoredMessages: [IgnoredNote]?   // 被忽略的发言

    // ── 价值维度 ──
    let signalNoiseRatio: Double          // 0-1
    let decisionEfficiency: String        // 快/正常/慢
    let importanceToMe: ImportanceLevel   // 高/中/低 + 原因

    // ── 人员维度（群聊）──
    let participants: [ParticipantRole]?

    // ── 关系维度（私聊）──
    let relationshipSignal: String?       // 升温/平稳/降温
    let symmetry: Double?                 // 互动对称性

    // ── 跨群关联 ──
    let crossChatTopics: [String]?        // 也在其他群讨论的话题名

    // ── 画像 ──
    let insight: String                   // 深度洞察
    let suggestion: String                // 行动建议
}

struct TopicInsight: Codable {
    let name: String                      // 具体话题名
    let messageCount: Int
    let participantCount: Int
    let summary: String                   // 讨论摘要
    let status: String                    // 已决/讨论中/搁置/信息同步
    let myInvolvement: String?            // 我的参与
    let attitudes: [String: String]?      // 关键人的态度
    let crossChats: [String]?             // 跨群出现
}

struct MoodShift: Codable {
    let from: String                      // 之前的情绪
    let to: String                        // 之后的情绪
    let trigger: String                   // 触发事件
    let time: String                      // 大约时间
}

struct AttitudeSignal: Codable {
    let person: String
    let topic: String
    let attitude: String                  // 积极推进/表面配合/敷衍/隐性反对/显性反对
    let evidence: String                  // 依据（具体措辞）
}

struct ToneChange: Codable {
    let person: String
    let change: String                    // "回复从'好的我看看'变成了'收到'"
    let interpretation: String            // "可能在敷衍或距离感增加"
}

struct SilentMember: Codable {
    let name: String
    let usualDailyMessages: Int           // 平时日均
    let todayMessages: Int                // 今天
    let activeElsewhere: Bool             // 在其他群是否活跃
    let interpretation: String            // "选择性沉默" or "整体不在线"
}

struct RecalledNote: Codable {
    let person: String
    let originalContent: String?          // 原文（如果抓到）
    let context: String                   // 撤回时在讨论什么
    let replacement: String?              // 替代消息
    let interpretation: String            // AI 分析
}

struct IgnoredNote: Codable {
    let person: String
    let content: String                   // 被忽略的消息内容
    let usualResponseRate: String         // 平时的回应率
    let interpretation: String            // 为什么被忽略
}

struct WaitingItem: Codable {
    let source: String                    // 谁在等
    let what: String                      // 等什么
    let waitingHours: Double              // 等了多久
}

struct ParticipantRole: Codable {
    let name: String
    let messageCount: Int
    let role: String                      // 推动者/决策者/执行者/反对者/旁观者
    let doing: String                     // 在做什么
    let attitudeToward: [String: String]? // 对关键话题的态度
}

struct ImportanceLevel: Codable {
    let level: String                     // 高/中/低
    let reason: String                    // 为什么
}
```

### 全局简报结构

```swift
struct GlobalBriefing: Codable {
    let date: String
    let actionRequired: [ActionRequiredItem]  // 需要你行动的事
    let headline: String                      // 2-3句全局概括
    let stats: BriefingStats                  // 统计数据
    let crossTopics: [CrossTopic]             // 跨群话题
    let darkSignals: DarkSignals              // 暗信号汇总
    let overallMood: String                   // 全局情绪
    let blindSpots: [String]                  // 盲区提醒
    let topSuggestion: String                 // 最重要的一条建议
}

struct ActionRequiredItem: Codable {
    let source: String                        // 来源
    let what: String                          // 等你做什么
    let waitingHours: Double                  // 等了多久
    let urgency: String                       // 高/中/低
}

struct CrossTopic: Codable {
    let name: String                          // 话题名
    let chats: [String]                       // 涉及的群/人
    let summary: String                       // 综合摘要
    let conflict: String?                     // 信息冲突
    let status: String                        // 状态
}

struct DarkSignals: Codable {
    let toneChanges: [ToneChange]             // 语气变化
    let silences: [SilentMember]              // 异常沉默
    let recalls: [RecalledNote]               // 撤回
    let ignored: [IgnoredNote]                // 被忽略
    let headline: String?                     // AI 对暗信号的总结
}

struct BriefingStats: Codable {
    let totalMessages: Int
    let myMessages: Int
    let activeGroups: Int
    let totalGroups: Int
    let activePrivateChats: Int
    let workRatio: Double                     // 工作消息占比
}
```

### 统计数据（纯算法，不需要 AI）

```swift
struct ChatAnalyticsEngine {
    static func compute(
        messages: [Message],
        selfName: String,
        timeRange: DateInterval
    ) -> ChatStatsData
}

struct ChatStatsData {
    let messageCount: Int
    let myMessageCount: Int
    let participantCount: Int
    let messagesByHour: [Int]                 // 24 slots
    let avgResponseTimeSeconds: Double
    let symmetryRatio: Double                 // 1.0=完全对称
    let trend7d: Double                       // 正=增长
    let topSenders: [(String, Int)]           // 发言排名
    let silentMembers: [SilentMember]         // 异常沉默（纯算法检测）
    let ignoredMessages: [(sender: String, content: String, time: Date)]
}
```

---

## AI Prompt 架构

### Prompt 1: `chat_insight_v1` — 单聊天分析

```
你是一个高级聊天分析师。你的任务不是总结聊天内容，
而是分析文字背后的隐性信号 — 态度、情绪、关系动态。

## 输入
- 聊天：{chatName}（{group/private}）
- 分类：{work/life/other}
- 我是：{selfName}
- 时间范围：{timeRange}
- 消息：
{messages}
- 撤回消息（如有）：
{recalledMessages}
- 此人/群的历史记忆：
{conversationMemory}

## 分析要求

### 1. 内容分析
- 识别所有讨论话题，话题名必须具体
- 每个话题的讨论程度（刚提出/深入讨论/已有结论）
- 已做的决策、待办事项

### 2. 态度分析（核心）
对每个话题，分析关键参与者的真实态度：
- 不要看他们说了什么，看他们怎么说的
- "好的我看看" = 表面配合，没有行动承诺
- "收到" / "嗯" = 敷衍
- 提出具体问题 = 真正关心
- 沉默 = 可能是反对但不想说
- 转移话题 = 回避
- 回复变短 = 失去耐心或兴趣

标注每个人对每个关键话题的态度：
积极推进 / 表面配合 / 敷衍 / 隐性反对 / 显性反对 / 回避 / 未表态

给出态度判断的依据（具体措辞）。

### 3. 情绪分析
- 整体氛围
- 有没有情绪转折点？具体到时间和触发事件
- 不要说"气氛紧张"，要说"14:20老板追问排期后，张三的回复从积极变为敷衍"

### 4. 语气微变化
对比此人/群的历史沟通风格（如果提供了 conversationMemory），
识别语气、措辞、回复速度的变化：
- 标点符号使用变化
- 回复长度变化
- 语气词选择变化
- 主动性变化

### 5. 和我的关系
- 有人@我或等我吗？
- 我承诺了什么？
- 我的发言被如何回应？被忽略了吗？

### 6. 撤回消息分析（如有）
- 撤回了什么？
- 在什么上下文中撤回的？
- 发了什么替代消息？
- 可能的撤回原因

### 7. 被忽略的发言
- 哪些消息发出后无人回应？
- 这正常吗？（对比此人平时的被回应率）

### 8. 画像
- 一条非显而易见的洞察（必须基于数据，不是常识）
- 一条具体的行动建议（具体到人+行动+时间）

## 输出
严格按照 ChatInsightResult JSON schema 输出。
所有态度判断必须附带证据（具体的消息措辞）。
```

### Prompt 2: `chat_insight_global_v1` — 全局简报 + 跨群聚合

```
你是一个通信态势分析师。基于所有聊天的分析结果，
生成全局简报。

## 输入
- 我是：{selfName}
- 日期：{date}
- 各聊天分析结果：
{chatInsights JSON array}
- 全局统计：
{aggregatedStats}

## 要求

### 1. 需要行动
从所有聊天中提取等我做的事，按紧急程度排序。
包含等待时间和来源。

### 2. 全局概括
2-3句话。必须具体。
不要："今天比较忙"
要："今天72%的沟通集中在Q2排期，你在3个群被问到
同一个问题但给了不同的答复，李四等你数据已经5小时"

### 3. 跨群话题检测
哪些话题在多个群/私聊出现？
用语义匹配 — "排期"和"timeline"和"什么时候上线"是同一件事。
各处讨论角度有什么不同？有没有信息冲突？

### 4. 暗信号汇总
从各聊天分析中收集所有暗信号（语气变化、沉默、撤回、忽略），
生成一段总结：
"今天有3个值得注意的暗信号：张三对你的态度在变冷（回复缩短），
 老板在管理群撤回了一条关于预算的消息，你在产品群的方案提议
 被集体忽略了。"

### 5. 盲区提醒
- VIP 但今天没互动的人
- 工作群你没参与的重要讨论
- 你的承诺中未兑现的

### 6. 最重要的建议
综合所有信息，给出今天最应该做的一件事。

## 输出
严格按照 GlobalBriefing JSON schema 输出。
```

### Prompt 3: `chat_insight_keyword_v1` — 关键词语义画像

```
用户想了解关于"{keyword}"的完整画像。

## 输入
- 关键词：{keyword}
- 各聊天的话题分析结果：
{topicInsights from cached chatInsights}
- 相关消息（AI 根据话题分析初筛后的）：
{relevantMessages}
- 我是：{selfName}

## 要求

不是字面匹配。理解关键词的语义，把所有相关的讨论纳入分析。
例如搜索"项目进度" → "deadline"、"排期"、"延期"、"什么时候上线"
都是相关的。

生成话题画像：
1. 全景描述
2. 涉及哪些群/人
3. 时间线（关键事件）
4. 干系人及角色/态度
5. 各群的讨论角度差异
6. 当前状态 + 风险
7. 你在这个话题中的位置
8. 行动建议

## 输出 JSON
{
  "summary": "话题全景",
  "status": "进行中/已完成/停滞/有风险",
  "chats": ["涉及的群/人"],
  "timeline": [{"date": "", "event": ""}],
  "stakeholders": [{"name": "", "role": "", "attitude": "", "evidence": ""}],
  "perspectives": [{"chat": "群名", "angle": "讨论角度"}],
  "conflicts": ["信息冲突点"],
  "myPosition": "我在这个话题中的角色和处境",
  "risks": ["风险"],
  "recommendation": "行动建议"
}
```

---

## 执行流程

```
用户打开 Insight tab
    ↓
Step 1: 纯算法统计（ChatAnalyticsEngine）
    并行处理所有白名单聊天，计算 ChatStatsData
    包括沉默检测、被忽略消息检测
    结果即时显示（统计数据先上屏）
    ↓
Step 2: AI 单聊天分析（chat_insight_v1 × N）
    并行调用，每个活跃聊天一次
    输入：消息 + 撤回消息 + conversationMemory + statsData
    结果缓存到 analysis_cache（TTL 2小时）
    每完成一个就更新对应卡片
    ↓
Step 3: AI 全局简报（chat_insight_global_v1 × 1）
    等所有 Step 2 完成后调用
    输入：所有 chatInsight 结果 + 聚合统计
    结果渲染为简报顶部内容
    ↓
用户点击某群/人 → 从缓存读取 step 2 结果 → 渲染详情
用户搜索关键词 → 从缓存筛选话题 + 1次 AI 调用 → 渲染画像
```

**缓存策略**：
- `analysis_cache` 表，`analysisType = "chat_insight_v1"`
- TTL 2小时（日内多次打开不重复调用）
- 换日自动失效
- 手动刷新按钮可强制重新分析

**Token 优化**：
- 每个聊天只发送时间窗口内的消息（今天=24h，7天=168h）
- 消息超过 200 条的群先做采样（保留首尾 + 等间隔抽样）
- conversationMemory 限制 400 字符
- 统计数据由纯算法计算，不占用 AI token

---

## 文件结构

```
Sources/WeChatHUD/
├── Services/
│   ├── ChatInsightEngine.swift          — 纯算法统计（消息数、沉默检测等）
│   └── AIChatInsight.swift              — 3个 prompt 的调用、缓存、结果解析
├── Data/
│   └── Models.swift                     — 新增上述所有 Codable 结构体
├── Views/Analytics/
│   ├── ChatInsightView.swift            — 主视图：全局简报流
│   ├── ChatInsightDetailView.swift      — 详情：群/人的完整分析
│   ├── TopicCrossView.swift             — 跨群话题详情
│   └── KeywordInsightView.swift         — 关键词搜索结果
├── Views/
│   └── ExtendedTabsView.swift           — 新增 .insight tab
└── Resources/prompts/
    ├── chat_insight_v1.txt              — 单聊天分析
    ├── chat_insight_global_v1.txt       — 全局简报
    └── chat_insight_keyword_v1.txt      — 关键词画像
```

### 修改的现有文件

- `ExtendedTabsView.swift` — Tab 枚举加 `.insight`，tab bar 加按钮
- `Models.swift` — 新增所有 Codable 结构体
- `HUDStore.swift` — analysis_cache 表已存在，无需改动

---

## 后续迭代（不在第一版）

- 时间轴视图（跨群统一时间线）
- 对比模式（本周 vs 上周）
- 话题追踪（Watch Mode）
- 影响力分析
- 日历热力图
- 信息流向追踪
