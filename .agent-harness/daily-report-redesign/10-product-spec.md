# 日报功能完整方案 — 产品规格

## Outcome
将 WeChatHUD 的日报功能从一个「依赖手动复盘、数据经常为空、AI 输出空洞」的鸡肋功能，改造成一个「自动采集聊天记录、智能生成高质量日报、支持一键复制发送」的核心生产力工具。用户打开日报 tab 时，看到的是一份有实质内容、有具体来源、有行动建议的日报，而不是「今日尚未生成对话复盘」。

## Target User
- 日常工作重度依赖微信沟通的职场人士
- 需要向上级汇报每日工作的中层管理者/项目负责人
- 日均微信消息量 50-500 条，跨多个群聊和私聊
- 期望日报能帮他们梳理「今天发生了什么、明天该做什么」

## Scope

### 第一阶段：数据采集层（核心瓶颈解决）
1. **DailyChatScanner** — 轻量级自动扫描器
   - 自动识别今天（0:00-now）活跃的对话（按消息量 + 重要性排序）
   - 选取 Top N（默认 8）个对话进行深度分析
   - 不依赖 retrospective run，直接从 WeChat DB 读取
   - 扫描成本：SQLite 查询，无 AI 调用

2. **DailyMessageDigest** — 单对话消息摘要
   - 对每个选中对话，提取今天的关键消息（@ mentions、关键词命中、用户发送的消息、长消息等）
   - 消息筛选策略：优先保留用户自己发的消息、被 @ 的消息、含决策/确认/安排关键词的消息
   - 上限：每对话 20 条消息，总计不超过 3000 tokens

3. **数据聚合策略**
   - 合并所有现有数据源：pending asks、commitments、reply debt、recalled messages
   - 新增数据源：今日活跃对话列表、每对话消息摘要、今日收发消息统计
   - 按时间线组织，而非按类别堆叠

### 第二阶段：AI 生成层（质量提升）
1. **统一日报生成器** — 合并 AIDailyReportGenerator + AIDailyRetrospector
   - 单一入口，单一 prompt，单一输出格式
   - 输入：丰富的原始数据（消息摘要 + asks + commitments + reply debt + 统计）
   - 输出：{ narrative, highlights, actions, risks, tomorrowFocus, wechatDraft }

2. **新 Prompt 策略**
   - 分层输入：先给时间线消息摘要（最丰富的上下文），再给聚合指标和行动项
   - 要求 AI 从消息摘要中提取具体事件，而非编造
   - 要求 AI 识别「用户主动推进的工作」和「他人向用户请求的工作」
   - wechatDraft 采用「做了什么 + 明天计划 + 需要支持」三段式结构

3. **质量保障机制**
   - JSON schema 校验 + 字段空值 fallback
   - 内容质量 heuristics：narrative 必须包含至少一个人名/群名；wechatDraft 必须包含至少一个具体事项
   - 质量不达标时触发 retry（不同 temperature）

### 第三阶段：展示与交互层
1. **DailyReportTabView 增强**
   - 新增「数据来源」标识：显示日报基于多少个对话、多少条消息
   - 新增「刷新」按钮的进度反馈（正在扫描 X 个对话...）
   - 新增「时间线」视图模式（可选）：按时间顺序展示今日事件
   - 失败状态提供「重试」和「查看详情」选项

2. **自动预热机制**
   - 首次打开应用后 5 分钟自动预热第一份日报
   - 之后每 30 分钟自动刷新（后台线程，不阻塞 UI）
   - 用户打开 tab 时，如果日报在有效期内（15 分钟内），直接展示缓存

3. **复盘入口整合**
   - 日报 tab 底部保留「运行完整复盘」入口，作为补充深度分析的手段
   - 复盘产出的 highlights/todos 自动流入下一次日报刷新

### 第四阶段：配置与调优
1. **日报配置面板**（SettingsWindow 新增 tab）
   - 日报生成时间窗口（默认 0:00-now，可选 yesterday）
   - 扫描对话数量上限（5/8/12/20）
   - 是否自动预热
   - 日报风格（正式/简洁/详细）
   - wechatDraft 接收人（上级/团队/自己）

## Non-Goals
1. 不接入外部日历（Google Calendar / Outlook）— 仅基于微信数据
2. 不修改 retrospective pipeline 的核心逻辑 — 只把它作为日报的数据源之一
3. 不做多语言支持 — 仅中文
4. 不做历史日报归档浏览 — 只显示今天的日报
5. 不做日报的社交分享（发送到微信外）— 只提供 copy-to-clipboard

## Constraints
1. **Token 预算**：单次日报 AI 调用总输入不超过 8000 tokens，输出不超过 1500 tokens
2. **调用成本**：日报生成最多 2 次 AI 调用（主生成 + 1 次 retry），不允许链式多轮调用
3. **性能**：后台预热不能影响前台 UI 响应，扫描 SQLite 的查询时间 < 500ms
4. **隐私**：所有数据处理本地完成，只有格式化后的 prompt 发送到 AI provider
5. **向后兼容**：保留现有 DailyReport 数据模型，新增字段用 Optional；不删除现有表

## Risks
1. **聊天记录质量差**：群聊消息量大但信息密度低，可能稀释日报质量
   - Mitigation：消息筛选策略（去噪）+ 群聊数量上限
2. **AI 幻觉**：模型编造不存在的事件或人名
   - Mitigation：prompt 中明确要求只引用输入中的数据 + 输出后 heuristics 校验
3. **Token 爆炸**：用户有 50+ 活跃对话，消息量远超预算
   - Mitigation：硬上限（最多 8 对话 × 20 消息 = 160 条），超限时按优先级截断
4. **与 retrospective 数据重复**：如果用户同时跑了复盘，日报和复盘 highlights 可能重复
   - Mitigation：日报去重逻辑（相同 chat + 相似 summary 合并）

## Acceptance Criteria
1. 用户首次打开日报 tab 时，看到的内容不是「今日尚未生成对话复盘」，而是基于今天聊天记录的实际内容
2. 日报 narrative 包含至少一个具体的对话来源（人名或群名）
3. wechatDraft 可直接复制粘贴发送，不需要手动修改
4. 日报生成时间 < 15 秒（含 SQLite 扫描 + AI 调用）
5. 后台自动预热每 30 分钟执行一次，用户无感知
6. 日报展示「基于 X 个对话，Y 条消息」的数据来源标识
7. 失败时有明确的错误信息和重试入口

## Milestones

### M1: 数据采集层（2-3 天）
- DailyChatScanner 实现 + 单元测试
- DailyMessageDigest 实现 + 单元测试
- DailyReportBuilder 重构，接入新数据源

### M2: AI 生成层（2-3 天）
- 统一日报生成器设计
- 新 prompt 编写 + 测试
- 质量 heuristics + retry 逻辑

### M3: 展示层（1-2 天）
- DailyReportTabView 增强
- 自动预热机制
- 数据来源标识

### M4: 配置层（1 天）
- 日报配置面板
- 设置持久化

### M5: 集成测试 + 优化（2 天）
- 端到端测试
- Token 预算优化
- 性能调优
