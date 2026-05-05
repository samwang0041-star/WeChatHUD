# Generation Report — 日报功能完整技术设计方案

## 输出概览
基于产品规格，产出可落地的完整技术设计方案。本方案在现有架构中最小侵入式实现，保留全部现有功能，新增轻量级数据采集层和统一 AI 生成层。

## 关键决策
1. **不引入新数据库表** — 日报数据为临时计算结果，通过内存缓存 + 文件缓存即可
2. **DailyChatScanner 不做 AI 调用** — 纯 SQLite 查询 + 规则筛选，零 token 成本
3. **统一生成器合并而非替换** — 保留 AIDailyReportGenerator 和 AIDailyRetrospector，新增 UnifiedDailyReportGenerator 作为统一入口，逐步迁移
4. **消息摘要采用"原始消息 + 轻量标记"而非二次 AI 摘要** — 减少一次 AI 调用，将 token 用在最终生成上

---

## 一、技术架构

### 1.1 新增服务

```
┌─────────────────────────────────────────────────────────────┐
│                      ChatMonitor (@MainActor)                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │ DailyReportCache│  │DailyReportBuilder│  │UnifiedDaily  │ │
│  │   (内存+文件)    │  │   (数据聚合)      │  │ReportGenerator│
│  └────────┬────────┘  └────────┬────────┘  └──────┬───────┘ │
│           │                    │                   │         │
│  ┌────────▼────────┐  ┌────────▼────────┐         │         │
│  │ DailyChatScanner│  │ DailyMessageDigest        │         │
│  │  (SQLite 扫描)   │  │  (消息筛选/格式化)         │         │
│  └────────┬────────┘  └────────┬────────┘         │         │
│           │                    │                   │         │
│  ┌────────▼────────────────────▼───────────────────▼───────┐ │
│  │              WeChatReader / HUDStore                     │ │
│  │         (SQLite 读取 / 本地数据查询)                      │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

#### DailyChatScanner

```swift
/// 轻量级今日对话扫描器。纯 SQLite 查询，无 AI 调用。
/// 职责：找出今天（0:00-now）活跃的对话，按重要性排序。
actor DailyChatScanner {
    private let reader: WeChatReader
    private let store: HUDStore

    struct ScannedChat: Sendable {
        let chatUsername: String
        let chatName: String
        let isGroup: Bool
        let relation: Relation          // 从 store 读取
        let todayMessageCount: Int      // 今日消息数
        let lastMessageTime: Date       // 最后消息时间
        let userOutboundCount: Int      // 用户发送的消息数（主动推进的信号）
        let atMentionCount: Int         // @ 用户的次数
        let priorityScore: Double       // 综合优先级分数
    }

    /// 扫描今天活跃的对话，返回按 priorityScore 排序的列表。
    /// 硬上限：maxChats 个。
    func scanToday(maxChats: Int = 8) -> [ScannedChat]
}
```

**扫描策略（priorityScore 计算）：**

```swift
private func computePriorityScore(chat: ScannedChat) -> Double {
    var score = 0.0
    // 基础分：今日消息量（对数衰减，避免大群刷屏）
    score += log10(Double(chat.todayMessageCount) + 1) * 10
    // 用户主动参与：+20 分/条用户消息（自己推进的工作更重要）
    score += Double(chat.userOutboundCount) * 20
    // @ 提及：+15 分/次（他人直接呼叫）
    score += Double(chat.atMentionCount) * 15
    // VIP/工作关系：+30 分
    if chat.relation == .work { score += 30 }
    if chat.relation == .vip { score += 40 }
    // 群聊 vs 私聊：私聊权重 +10
    if !chat.isGroup { score += 10 }
    // 时间衰减：越久远的对话分数越低
    let hoursAgo = Date().timeIntervalSince(chat.lastMessageTime) / 3600
    score *= max(0.3, 1.0 - hoursAgo * 0.05)
    return score
}
```

**SQLite 查询策略：**

```swift
// WeChatReader 已支持 getMessages(chatUsername:limit:) 返回 newest-first
// 在 DailyChatScanner 中新增批量查询：
func todayMessagesByChat(startOfDay: Int) -> [(chatUsername: String, count: Int, lastTime: Int, outboundCount: Int, atCount: Int)]
```

查询逻辑：遍历 topActiveContacts（已存在）→ 对每个 contact 查今日消息数 → 计算分数 → 排序取 Top N。

性能预估：遍历 50 个 contacts，每个查 1 条 COUNT 查询，总计 ~50ms。

#### DailyMessageDigest

```swift
/// 为单个对话生成今日消息摘要。纯数据格式化，无 AI 调用。
/// 职责：从今日消息中筛选关键消息，格式化为 AI 可读的文本。
actor DailyMessageDigest {
    private let reader: WeChatReader
    private let myUsername: String

    struct ChatDigest: Sendable {
        let chatUsername: String
        let chatName: String
        let isGroup: Bool
        let relation: Relation
        let todayMessageCount: Int      // 今日总消息数（含未选中的）
        let selectedMessages: [DigestMessage]
        let keyTopics: [String]         // 从消息中提取的关键词（简单规则匹配）
    }

    struct DigestMessage: Sendable {
        let time: Date
        let senderName: String
        let senderIsMe: Bool
        let text: String
        let isAtMention: Bool
        let importance: MessageImportance
    }

    enum MessageImportance: Int, Sendable {
        case critical = 3   // 用户自己发的长消息、被 @ 的消息
        case high = 2       // 含决策/确认/安排关键词、URL、文件
        case normal = 1     // 普通消息
        case skip = 0       // 跳过（表情、红包、短语音转文字等）
    }

    /// 为指定对话生成今日消息摘要。
    /// 硬上限：maxMessages 条选中消息。
    func digest(chat: DailyChatScanner.ScannedChat, maxMessages: Int = 20) -> ChatDigest
}
```

**消息筛选策略：**

```swift
private func classifyImportance(_ msg: MessageInfo) -> MessageImportance {
    let text = msg.text.trimmingCharacters(in: .whitespaces)
    // 跳过低价值消息
    if text.count < 3 { return .skip }                    // 表情、"ok"、"嗯"
    if isRedPacket(text) { return .skip }                  // 红包
    if isVoiceTranscriptShort(text) { return .skip }       // 短语音
    // Critical：用户自己发的消息（主动推进）或被 @ 的消息
    if msg.senderUsername == myUsername && text.count > 10 { return .critical }
    if msg.isAtMention { return .critical }
    // High：含关键词或结构化内容
    let keywords = ["确认", "决定", "安排", "会议", "截止", " deadline", "预算", "方案", "审批", "签署", "明天", "下周", "http", "文件", "文档"]
    if keywords.contains(where: { text.contains($0) }) { return .high }
    if text.contains("http") || text.contains("www.") { return .high }
    // Normal：其他消息
    return .normal
}
```

**消息选择算法：**

```swift
func selectMessages(allMessages: [MessageInfo], maxMessages: Int) -> [DigestMessage] {
    // 1. 按重要性分类
    let classified = allMessages.map { (msg: $0, importance: classifyImportance($0)) }
    let critical = classified.filter { $0.importance == .critical }
    let high = classified.filter { $0.importance == .high }
    let normal = classified.filter { $0.importance == .normal }

    // 2. 按优先级选取，确保时间线覆盖
    var selected: [MessageInfo] = []
    selected.append(contentsOf: critical.prefix(maxMessages / 2))
    if selected.count < maxMessages {
        selected.append(contentsOf: high.prefix(maxMessages - selected.count))
    }
    if selected.count < maxMessages {
        selected.append(contentsOf: normal.prefix(maxMessages - selected.count))
    }

    // 3. 按时间排序（ chronological ）
    return selected.sorted { $0.createTime < $1.createTime }
}
```

#### UnifiedDailyReportGenerator

```swift
/// 统一日报生成器。合并 AIDailyReportGenerator 和 AIDailyRetrospector。
/// 职责：接收丰富的原始数据，调用 AI 生成完整的日报。
actor UnifiedDailyReportGenerator {
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    struct ReportInput: Sendable {
        let date: Date
        let chatDigests: [DailyMessageDigest.ChatDigest]
        let pendingAsks: [PendingAsk]
        let handledAsks: [PendingAsk]
        let pendingCommitments: [Commitment]
        let overdueCommitments: [Commitment]
        let replyDebtItems: [ReplyDebtItem]
        let todayRecalled: [RecalledMessage]
        let stats: HUDStats
        let todayMessageTotal: Int       // 今日总收发消息数
        let activeChatCount: Int         // 今日活跃对话数
        let userOutboundTotal: Int       // 用户今日发送消息总数
    }

    struct ReportOutput: Decodable, Sendable {
        let narrative: String
        let highlights: [AIHighlight]
        let actions: [AIAction]
        let risks: [AIRisk]
        let tomorrowFocus: String
        let wechatDraft: String
        let mood: String                 // 今日整体节奏：紧张/正常/松散

        struct AIHighlight: Decodable, Sendable {
            let summary: String
            let chatName: String
            let category: String           // decision / progress / discussion / risk
            let confidence: Double
        }

        struct AIAction: Decodable, Sendable {
            let content: String
            let type: String               // todo / commitment / replyDebt / ask
            let urgency: String            // critical / high / medium / low
            let deadline: String?          // ISO 日期或相对时间
            let chatName: String
        }

        struct AIRisk: Decodable, Sendable {
            let type: String
            let description: String
            let severity: String           // high / medium / low
            let chatName: String?
        }
    }

    /// 生成日报。失败时返回 nil（调用方负责降级）。
    func generate(_ input: ReportInput) async -> ReportOutput?
}
```

**质量校验（heuristics）：**

```swift
private func validateOutput(_ output: ReportOutput, input: ReportInput) -> Bool {
    // 1. narrative 必须包含至少一个人名/群名
    let allNames = input.chatDigests.map { $0.chatName }
    let hasName = allNames.contains { output.narrative.contains($0) }
    guard hasName else { return false }

    // 2. wechatDraft 必须包含至少一个具体事项（数字序号）
    guard output.wechatDraft.contains("1)") || output.wechatDraft.contains("1.") else { return false }

    // 3. narrative 不能包含"今日尚未生成对话复盘"等套话
    let bannedPhrases = ["今日尚未生成对话复盘", "暂无高亮数据", "今天处理了一些工作事项"]
    guard !bannedPhrases.contains(where: { output.narrative.contains($0) }) else { return false }

    // 4. tomorrowFocus 不能是空话
    let emptyPhrases = ["继续推进工作", "按计划进行", "正常推进", "继续跟进"]
    guard !emptyPhrases.contains(where: { output.tomorrowFocus.contains($0) }) else { return false }

    return true
}
```

**Retry 策略：**

```swift
func generateWithRetry(_ input: ReportInput, maxAttempts: Int = 2) async -> ReportOutput? {
    for attempt in 0..<maxAttempts {
        let temperature = attempt == 0 ? 0.2 : 0.4  // 第二次提高 temperature 增加多样性
        let output = await generate(input, temperature: temperature)
        if let output = output, validateOutput(output, input: input) {
            return output
        }
    }
    return nil
}
```

### 1.2 改造现有服务

#### DailyReportBuilder（重构）

```swift
struct DailyReportBuilder {
    let store: HUDStore
    let replyDebtItems: [ReplyDebtItem]
    let stats: HUDStats
    let reader: WeChatReader        // 新增：用于读取聊天记录

    func build() async -> DailyReport {
        // 1. 扫描今日活跃对话
        let scanner = DailyChatScanner(reader: reader, store: store)
        let scannedChats = await scanner.scanToday(maxChats: 8)

        // 2. 为每个对话生成消息摘要
        let digester = DailyMessageDigest(reader: reader, myUsername: reader.myUsername())
        var chatDigests: [DailyMessageDigest.ChatDigest] = []
        for chat in scannedChats {
            let digest = await digester.digest(chat: chat, maxMessages: 20)
            chatDigests.append(digest)
        }

        // 3. 获取现有数据（asks, commitments, recalled）
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        // ... 现有逻辑 ...

        // 4. 构建聚合指标
        let todayMessageTotal = scannedChats.reduce(0) { $0 + $1.todayMessageCount }
        let userOutboundTotal = scannedChats.reduce(0) { $0 + $1.userOutboundCount }
        let activeChatCount = scannedChats.count

        // 5. 构建 ReportInput
        let reportInput = UnifiedDailyReportGenerator.ReportInput(
            date: now,
            chatDigests: chatDigests,
            pendingAsks: pendingAsks,
            handledAsks: handledAsks,
            pendingCommitments: pendingCommitments,
            overdueCommitments: overdueCommitments,
            replyDebtItems: replyDebtItems,
            todayRecalled: todayRecalled,
            stats: stats,
            todayMessageTotal: todayMessageTotal,
            activeChatCount: activeChatCount,
            userOutboundTotal: userOutboundTotal
        )

        // 6. 调用统一生成器
        let generator = UnifiedDailyReportGenerator(aiService: aiService)
        let aiOutput = await generator.generateWithRetry(reportInput)

        // 7. 构建 DailyReport（兼容现有模型）
        return DailyReport(
            date: now,
            dateRange: (start: startOfDay, end: now),
            generatedAt: now,
            metrics: metrics,
            highlights: aiOutput?.highlights.map { ... } ?? [],
            actions: aiOutput?.actions.map { ... } ?? [],
            risks: aiOutput?.risks.map { ... } ?? [],
            pendingAsks: pendingAsks + handledAsks,
            narrative: aiOutput?.narrative,
            tomorrowFocus: aiOutput?.tomorrowFocus,
            wechatDraft: aiOutput?.wechatDraft
        )
    }
}
```

#### ChatMonitor.loadDailyReport（增强）

```swift
func loadDailyReport(force: Bool = false) async {
    // 检查缓存
    if !force, let cached = dailyReportCache.load(),
       Date().timeIntervalSince(cached.generatedAt) < 900 {  // 15 分钟缓存
        dailyReport = cached.report
        dailyReportGeneratedAt = cached.generatedAt
        return
    }

    dailyReportError = nil
    let builder = DailyReportBuilder(
        store: store,
        replyDebtItems: replyDebtItems,
        stats: stats,
        reader: reader
    )

    do {
        let report = try await builder.build()
        dailyReport = report
        dailyReportGeneratedAt = Date()
        dailyReportCache.save(report: report, generatedAt: Date())
    } catch {
        dailyReportError = error.localizedDescription
        // 降级：尝试只生成数据聚合报告（无 AI narrative）
        let fallbackReport = builder.buildFallback()
        dailyReport = fallbackReport
    }
}

/// 后台自动预热
func warmUpDailyReport() async {
    guard dailyReport == nil else { return }
    await loadDailyReport()
}
```

---

## 二、数据流

```
WeChat DB (SQLite)
    │
    ▼
[DailyChatScanner.scanToday] ──► [ScannedChat] × N (N≤8)
    │                              │
    │                              ▼
    │                    [DailyMessageDigest.digest]
    │                              │
    │                              ▼
    │                    [ChatDigest] × N
    │                              │
    │    ┌─────────────────────────┘
    │    ▼
[DailyReportBuilder.build]
    │
    ├──► HUDStore: pendingAsks, commitments, recalled, replyDebt
    │
    ▼
[UnifiedDailyReportGenerator.ReportInput]
    │
    ▼
[Prompt formatting] ──► {chat_digests + asks + commitments + stats}
    │
    ▼
[AIService.completeWithMetadata] ──► AI response
    │
    ▼
[JSON parse + validateOutput] ──► [ReportOutput]
    │
    ▼
[DailyReport model] ──► [DailyReportCache] ──► [DailyReportTabView]
```

**时序说明：**
1. Scanner 和 Digest 是串行的（对每个 chat 依次 digest），但可以优化为并发（TaskGroup，max 4 concurrent）
2. AI 生成是单点瓶颈，但只有一次调用（含 retry）
3. 全链路目标耗时：扫描 100ms + digest 500ms + AI 5-10s = **总计 < 15s**

---

## 三、数据模型改动

### 3.1 新增模型

```swift
// MARK: - Daily Chat Digest Models

struct DailyChatDigest: Sendable {
    let chatUsername: String
    let chatName: String
    let isGroup: Bool
    let relation: Relation
    let todayMessageCount: Int
    let selectedMessages: [DailyDigestMessage]
    let keyTopics: [String]
}

struct DailyDigestMessage: Sendable {
    let time: Date
    let senderName: String
    let senderIsMe: Bool
    let text: String
    let isAtMention: Bool
    let importance: DailyMessageImportance
}

enum DailyMessageImportance: Int, Sendable {
    case critical = 3
    case high = 2
    case normal = 1
    case skip = 0
}

// MARK: - AI Report Output Models

struct AIDailyReportOutput: Decodable, Sendable {
    let narrative: String
    let highlights: [AIDailyHighlight]
    let actions: [AIDailyAction]
    let risks: [AIDailyRisk]
    let tomorrowFocus: String
    let wechatDraft: String
    let mood: String
}

struct AIDailyHighlight: Decodable, Sendable {
    let summary: String
    let chatName: String
    let category: String
    let confidence: Double
}

struct AIDailyAction: Decodable, Sendable {
    let content: String
    let type: String
    let urgency: String
    let deadline: String?
    let chatName: String
}

struct AIDailyRisk: Decodable, Sendable {
    let type: String
    let description: String
    let severity: String
    let chatName: String?
}
```

### 3.2 DailyReport 模型扩展（向后兼容）

```swift
struct DailyReport: Sendable {
    // 现有字段保持不变
    let date: Date
    let dateRange: (start: Date, end: Date)
    let generatedAt: Date
    let metrics: DailyReportMetrics
    let highlights: [DailyReportHighlight]
    let actions: [DailyReportAction]
    let risks: [DailyReportRisk]
    let pendingAsks: [PendingAsk]
    var narrative: String?
    var tomorrowFocus: String?
    var wechatDraft: String?

    // 新增字段（全部 Optional，向后兼容）
    var mood: String?                    // 今日整体节奏
    var dataSourceInfo: DataSourceInfo?  // 数据来源标识
    var rawDigests: [DailyChatDigest]?   // 原始消息摘要（调试/详情用）
}

struct DataSourceInfo: Sendable {
    let scannedChatCount: Int
    let selectedMessageCount: Int
    let todayTotalMessageCount: Int
    let askCount: Int
    let commitmentCount: Int
}
```

### 3.3 缓存模型

```swift
/// 日报内存 + 文件缓存
actor DailyReportCache {
    private var memoryCache: CachedReport?
    private let cacheFileURL: URL

    struct CachedReport: Sendable {
        let report: DailyReport
        let generatedAt: Date
    }

    func load() -> CachedReport? { memoryCache }
    func save(report: DailyReport, generatedAt: Date)
    func clear()
}
```

**文件缓存路径：** `~/Library/Caches/com.wechathud/daily_report_cache.json`

---

## 四、Prompt 设计方案

### 4.1 输入模板（daily_report_v2.txt）

```
你是一个专业的工作日汇总助手。根据用户今天的微信聊天记录和活动数据，生成一份有上下文、有重点的日报总结。

你必须输出**单个 JSON 对象**，不要包含 markdown 围栏或任何其他文本。

JSON schema:
{
  "narrative": "今日核心回顾，2-3 句话，最多 120 字。必须引用具体的对话来源和事件，不能写泛泛而谈的套话。",
  "highlights": [
    {"summary": "一句话总结这个高亮事件", "chat_name": "来源群名/人名", "category": "decision|progress|discussion|risk", "confidence": 0.9}
  ],  // 最多 5 条，只选最重要的
  "actions": [
    {"content": "行动内容", "type": "todo|commitment|replyDebt|ask", "urgency": "critical|high|medium|low", "deadline": "截止时间或null", "chat_name": "来源"}
  ],  // 最多 8 条，按 urgency 排序
  "risks": [
    {"type": "overdueCommitment|overdueTodo|recalledMessage|other", "description": "风险描述", "severity": "high|medium|low", "chat_name": "来源或null"}
  ],  // 最多 3 条
  "tomorrow_focus": "明天最该优先处理的一件事，1 句话，最多 50 字。必须具体。",
  "wechat_draft": "可直接复制粘贴到微信发给上级的工作日报，正式礼貌、不超过 200 字。格式：日期+工作小结，今日完成（1) 2) 3)），明日计划，需要支持。",
  "mood": "今日整体工作节奏，1 个词：紧张|正常|松散"
}

# 输入数据

## 今日统计
- 日期: {date}
- 活跃对话数: {active_chat_count}
- 今日总收发消息: {today_total_messages} 条
- 用户发送消息: {user_outbound_total} 条
- 未读消息: {unread_count}
- 待处理请求: {pending_ask_count}
- 待履行承诺: {pending_commitment_count}（超期: {overdue_commitment_count}）
- 回复债务: {reply_debt_count}
- 撤回消息: {recalled_count}

## 今日对话摘要（按重要性排序）
{chat_digests}

## 待办与承诺
{actions}

## 风险与异常
{risks}

# 规则

1. **必须引用具体来源** — narrative 中要提到具体的人名/群名和事件内容
2. **不要编造数据** — 只用输入里给的信息，如果 chat_digests 为空，诚实说明"今日聊天记录有限"
3. ** highlights 必须从 chat_digests 中提取** — 不能凭空创造
4. **actions 必须基于 asks + commitments + reply debt** — 不能编造不存在的待办
5. **wechatDraft 三段式**：
   - 第一行：日期 + "工作小结"
   - 第二行起：今日完成 1) 2) 3)
   - 然后：明日计划
   - 最后：需要支持
6. **tomorrowFocus 选择原则**：
   - 已超期的承诺/待办最优先
   - 截止时间在 24h 内的次之
   - 高置信度高亮相关的行动再次之
7. **mood 判断**：
   - 紧张：消息量 > 200 或有超期事项 ≥ 3
   - 松散：消息量 < 30 且无待办
   - 正常：其他

只输出 JSON，不要任何其他文字。
```

### 4.2 chat_digests 格式化

```swift
func formatChatDigests(_ digests: [DailyChatDigest]) -> String {
    digests.enumerated().map { (i, d) in
        var lines: [String] = []
        lines.append("\n### 对话 \(i+1): [\(d.chatName)] (\(d.isGroup ? "群聊" : "私聊"), \(d.relation.rawValue), 今日 \(d.todayMessageCount) 条消息)")
        if !d.keyTopics.isEmpty {
            lines.append("关键词: \(d.keyTopics.joined(separator: ", "))")
        }
        for msg in d.selectedMessages {
            let timeStr = formatTime(msg.time)
            let prefix = msg.senderIsMe ? "我" : msg.senderName
            let atMarker = msg.isAtMention ? " [@我]" : ""
            lines.append("[\(timeStr)] \(prefix)\(atMarker): \(msg.text)")
        }
        return lines.joined(separator: "\n")
    }.joined(separator: "\n")
}
```

### 4.3 防幻觉机制

1. **Prompt 层面**：明确要求「只用输入里给的信息」，如果聊天记录有限要诚实说明
2. **Schema 层面**：highlights 必须关联 chat_name，actions 必须关联 chat_name
3. **Heuristics 层面**：validateOutput 检查 narrative 是否包含至少一个 chat_name
4. **Retry 层面**：失败时提高 temperature 重试，或降级到数据聚合报告

---

## 五、UI 改动方案

### 5.1 DailyReportTabView 增强

```swift
struct DailyReportTabView: View {
    @EnvironmentObject var monitor: ChatMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.07))
            content
        }
        .task {
            await monitor.loadDailyReport()
        }
    }

    // MARK: - Header（增强）
    private var header: some View {
        HStack(spacing: 0) {
            Text("日报")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(.leading, 4)

            // 数据来源标识
            if let info = monitor.dailyReport?.dataSourceInfo {
                Text("基于 \(info.scannedChatCount) 个对话 · \(info.selectedMessageCount) 条消息")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.leading, 8)
            }

            Spacer()

            // 生成时间
            if let genAt = monitor.dailyReportGeneratedAt {
                Text(timeAgo(genAt))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }

            Button(action: {
                Task { await monitor.loadDailyReport(force: true) }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Content（增强失败状态）
    @ViewBuilder
    private var content: some View {
        if let error = monitor.dailyReportError {
            errorState(error)
        } else if monitor.dailyReport == nil && monitor.dailyReportGeneratedAt == nil {
            loadingState
        } else if let report = monitor.dailyReport {
            reportContent(report: report)
        } else {
            emptyState("日报生成失败，请稍后重试")
        }
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(.orange.opacity(0.7))
            Text("日报生成出错")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Text(error)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await monitor.loadDailyReport(force: true) }
            }
            .font(.system(size: 10))
            .foregroundColor(.blue)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
```

### 5.2 新增 mood 展示

在 metricsSection 下方新增 mood 标识：

```swift
private func moodSection(mood: String) -> some View {
    let (emoji, color) = moodStyle(mood)
    return HStack(spacing: 4) {
        Text(emoji)
            .font(.system(size: 12))
        Text("今日节奏: \(mood)")
            .font(.system(size: 9))
            .foregroundColor(color)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(color.opacity(0.1))
    .cornerRadius(4)
}

private func moodStyle(_ mood: String) -> (String, Color) {
    switch mood {
    case "紧张": return ("🔥", .orange)
    case "松散": return ("🍃", .green)
    default: return ("⚡", .white.opacity(0.6))
    }
}
```

### 5.3 配置面板（SettingsWindow 新增）

```swift
struct DailyReportSettingsView: View {
    @AppStorage("dailyReport.autoWarmup") private var autoWarmup = true
    @AppStorage("dailyReport.maxScannedChats") private var maxScannedChats = 8
    @AppStorage("dailyReport.maxMessagesPerChat") private var maxMessagesPerChat = 20
    @AppStorage("dailyReport.cacheMinutes") private var cacheMinutes = 15
    @AppStorage("dailyReport.style") private var style = "formal"

    var body: some View {
        Form {
            Section("自动生成") {
                Toggle("应用启动后自动预热日报", isOn: $autoWarmup)
                Picker("扫描对话数量上限", selection: $maxScannedChats) {
                    Text("5").tag(5)
                    Text("8").tag(8)
                    Text("12").tag(12)
                    Text("20").tag(20)
                }
                Picker("每对话消息上限", selection: $maxMessagesPerChat) {
                    Text("10").tag(10)
                    Text("20").tag(20)
                    Text("30").tag(30)
                }
            }

            Section("缓存与刷新") {
                Picker("日报有效期", selection: $cacheMinutes) {
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                }
            }

            Section("风格") {
                Picker("日报风格", selection: $style) {
                    Text("正式").tag("formal")
                    Text("简洁").tag("concise")
                    Text("详细").tag("detailed")
                }
            }
        }
    }
}
```

---

## 六、自动预热方案

### 6.1 定时器设计

```swift
/// 日报自动预热定时器
actor DailyReportWarmer {
    private var timer: Timer?
    private let monitor: ChatMonitor
    private let interval: TimeInterval = 30 * 60  // 30 分钟

    func start() {
        // 首次预热：启动后 5 分钟
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            Task { await self?.warmUp() }
        }

        // 定期预热
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.warmUp() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func warmUp() async {
        guard UserDefaults.standard.bool(forKey: "dailyReport.autoWarmup") else { return }
        await monitor.warmUpDailyReport()
    }
}
```

### 6.2 集成到 AppDelegate

```swift
// AppDelegate.swift
private var dailyReportWarmer: DailyReportWarmer?

func applicationDidFinishLaunching(_ notification: Notification) {
    // ... 现有代码 ...
    dailyReportWarmer = DailyReportWarmer(monitor: chatMonitor)
    Task { await dailyReportWarmer?.start() }
}
```

---

## 七、Token/性能预算

### 7.1 分项预算

| 环节 | Token 估算 | 说明 |
|------|-----------|------|
| Prompt 头部（指令 + schema） | ~500 | 固定 |
| 今日统计（metrics） | ~200 | 固定 |
| 对话摘要（chat_digests） | ~5000 | 8 对话 × 20 消息 × ~30 tokens/消息 |
| 待办与承诺（actions） | ~800 | 约 20 条 |
| 风险（risks） | ~300 | 约 5 条 |
| **总输入** | **~6800** | **< 8000 预算** |
| AI 输出 | ~1200 | narrative + highlights + actions + risks + wechatDraft |

**控制措施：**
- 对话数硬上限：8 个
- 每对话消息硬上限：20 条
- 每条消息文本截断：80 字符（保留前 80 字）
- 如果总输入预估 > 7500 tokens，自动缩减对话数或消息数

### 7.2 性能预算

| 环节 | 目标耗时 | 最坏情况 |
|------|---------|---------|
| SQLite 扫描（50 contacts） | ~50ms | ~200ms |
| 消息读取（8 chats × 100 msgs） | ~300ms | ~800ms |
| 消息筛选/格式化 | ~100ms | ~300ms |
| AI 调用 | ~5-10s | ~15s（含 retry） |
| JSON 解析 + 校验 | ~50ms | ~100ms |
| **总计** | **~6-11s** | **~17s** |

**优化措施：**
- Scanner 和 Digest 可并发执行（TaskGroup，max 4）
- 消息读取使用批量查询而非逐条
- AI 调用使用 timeout: 15s，retry timeout: 10s

---

## 八、Fallback/降级策略

### 8.1 多层降级

```swift
enum DailyReportFallbackLevel: Int {
    case fullAI = 0      // 完整 AI 生成
    case partialAI = 1   // AI 只生成 narrative，其他用规则聚合
    case ruleBased = 2   // 完全规则聚合，无 AI
    case empty = 3       // 只有统计数字
}

func buildFallback(level: DailyReportFallbackLevel) -> DailyReport {
    switch level {
    case .fullAI:
        // 正常流程
        return try await buildWithAI()
    case .partialAI:
        // AI 失败但数据聚合成功：只生成 wechatDraft（模板填充）
        return buildWithTemplateDraft()
    case .ruleBased:
        // 完全没有 AI：用现有 DailyReportBuilder 的逻辑（当前版本）
        return buildLegacyReport()
    case .empty:
        // 极端情况：只返回统计数字
        return buildEmptyReport()
    }
}
```

### 8.2 模板填充（partialAI fallback）

当 AI 无法生成 narrative 时，使用模板填充 wechatDraft：

```swift
private func templateDraft(report: DailyReport) -> String {
    let date = report.date.formatted(date: .numeric, time: .omitted)
    var lines: [String] = []
    lines.append("\(date) 工作小结")

    // 今日完成：从 handled asks + 用户发送的消息中提取
    let completions = report.pendingAsks.filter { $0.status == .done }
    if !completions.isEmpty {
        lines.append("今日完成：")
        for (i, ask) in completions.prefix(5).enumerated() {
            lines.append("\(i+1)) \(ask.summary)")
        }
    } else {
        lines.append("今日处理对外沟通 \(report.metrics.pendingAskCount) 件待跟进事项")
    }

    // 明日计划：从 pending asks + commitments 中提取
    let pending = report.actions.filter { $0.urgency != .low }
    if !pending.isEmpty {
        lines.append("明日计划：")
        for (i, action) in pending.prefix(3).enumerated() {
            lines.append("\(i+1)) \(action.content)")
        }
    }

    lines.append("请支持：暂无")
    return lines.joined(separator: "\n")
}
```

---

## 九、实现路线图

### M1: 数据采集层（新增 2 个文件，修改 1 个文件）

**新增文件：**
1. `Services/DailyChatScanner.swift` — 对话扫描器
2. `Services/DailyMessageDigest.swift` — 消息摘要器

**修改文件：**
3. `Data/WeChatReader.swift` — 新增 todayMessagesByChat 批量查询方法

**验证标准：**
- DailyChatScanner.scanToday() 返回按分数排序的 ScannedChat 列表
- DailyMessageDigest.digest() 返回格式化的 ChatDigest
- 单元测试覆盖：扫描分数计算、消息筛选、消息选择算法

### M2: 统一 AI 生成层（新增 1 个文件，新增 1 个 prompt，修改 1 个文件）

**新增文件：**
1. `Services/UnifiedDailyReportGenerator.swift` — 统一日报生成器
2. `Resources/prompts/daily_report_v2.txt` — 新 prompt

**修改文件：**
3. `Services/DailyReportBuilder.swift` — 重构为异步，接入 Scanner + Digest + UnifiedGenerator

**验证标准：**
- UnifiedDailyReportGenerator.generate() 返回结构化的 ReportOutput
- validateOutput 能正确识别低质量输出
- Retry 策略在质量不达标时触发

### M3: 展示层与自动预热（修改 2 个文件，新增 1 个文件）

**新增文件：**
1. `Services/DailyReportCache.swift` — 日报缓存
2. `Services/DailyReportWarmer.swift` — 自动预热定时器

**修改文件：**
3. `Views/DailyReportTabView.swift` — 增强 header、错误状态、mood 展示
4. `Services/ChatMonitor.swift` — 接入缓存和自动预热

**验证标准：**
- 打开日报 tab 时，如果有缓存直接展示（< 100ms）
- 错误状态显示具体错误信息和重试按钮
- 自动预热在启动后 5 分钟触发

### M4: 配置面板（新增 1 个文件，修改 1 个文件）

**新增文件：**
1. `Views/DailyReportSettingsView.swift` — 日报设置面板

**修改文件：**
2. `App/SettingsWindow.swift` — 集成日报设置 tab

**验证标准：**
- 设置项持久化到 UserDefaults
- 修改设置后下次生成生效

### M5: 集成测试与优化（新增 2 个测试文件）

**新增文件：**
1. `Tests/WeChatHUDTests/DailyChatScannerTests.swift`
2. `Tests/WeChatHUDTests/UnifiedDailyReportGeneratorTests.swift`

**优化项：**
- Token 预算实测，调整硬上限
- 性能实测，优化并发策略
- Prompt 调优（根据实测输出质量）

**验证标准：**
- 端到端测试：从扫描到展示全链路通过
- Token 消耗 < 8000
- 生成时间 < 15s

---

## 十、文件改动清单

### 新增文件（8 个）
1. `Sources/WeChatHUD/Services/DailyChatScanner.swift`
2. `Sources/WeChatHUD/Services/DailyMessageDigest.swift`
3. `Sources/WeChatHUD/Services/UnifiedDailyReportGenerator.swift`
4. `Sources/WeChatHUD/Services/DailyReportCache.swift`
5. `Sources/WeChatHUD/Services/DailyReportWarmer.swift`
6. `Sources/WeChatHUD/Views/DailyReportSettingsView.swift`
7. `Sources/WeChatHUD/Resources/prompts/daily_report_v2.txt`
8. `Tests/WeChatHUDTests/DailyChatScannerTests.swift`

### 修改文件（5 个）
1. `Sources/WeChatHUD/Services/DailyReportBuilder.swift` — 重构为异步，接入新数据源
2. `Sources/WeChatHUD/Services/ChatMonitor.swift` — 接入缓存、自动预热、错误处理
3. `Sources/WeChatHUD/Views/DailyReportTabView.swift` — 增强展示
4. `Sources/WeChatHUD/App/SettingsWindow.swift` — 集成配置面板
5. `Sources/WeChatHUD/Data/WeChatReader.swift` — 新增批量查询方法

### 向后兼容
- DailyReport 模型只新增 Optional 字段，不影响现有序列化
- DailyReportBuilder 的同步 build() 方法改为 async，调用方已使用 await
- 保留 AIDailyReportGenerator 和 AIDailyRetrospector，新的 UnifiedDailyReportGenerator 并行存在

---

## 已知局限

1. **消息筛选是规则-based**：DailyMessageDigest 的消息重要性分类基于关键词匹配，可能遗漏非关键词但重要的消息。未来可考虑用轻量级 AI 做消息筛选（但会增加一次 AI 调用）。
2. **群聊噪音**：大群（100+ 人）的消息可能稀释重要私聊。当前通过 priorityScore 中的"私聊权重 +10"来缓解。
3. **撤回消息处理**：recalled messages 的 AI 分析仍依赖现有 RecallAnalyzer，日报只是展示其结果。
4. **历史数据**：方案只覆盖「今天」，不支持查看历史日报。如需历史日报，需扩展缓存为按日期索引。
5. **多设备**：如果用户在多设备上使用微信，WeChat DB 只包含当前设备的聊天记录，日报可能不完整。

---

## 变更文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `Services/DailyChatScanner.swift` | 新增 | 轻量级对话扫描器 |
| `Services/DailyMessageDigest.swift` | 新增 | 消息摘要器 |
| `Services/UnifiedDailyReportGenerator.swift` | 新增 | 统一 AI 日报生成器 |
| `Services/DailyReportCache.swift` | 新增 | 日报缓存 |
| `Services/DailyReportWarmer.swift` | 新增 | 自动预热定时器 |
| `Views/DailyReportSettingsView.swift` | 新增 | 配置面板 |
| `Resources/prompts/daily_report_v2.txt` | 新增 | 新 prompt |
| `Tests/DailyChatScannerTests.swift` | 新增 | 单元测试 |
| `Services/DailyReportBuilder.swift` | 修改 | 重构为异步，接入新数据源 |
| `Services/ChatMonitor.swift` | 修改 | 接入缓存、预热、错误处理 |
| `Views/DailyReportTabView.swift` | 修改 | 增强展示 |
| `App/SettingsWindow.swift` | 修改 | 集成配置面板 |
| `Data/WeChatReader.swift` | 修改 | 新增批量查询 |
