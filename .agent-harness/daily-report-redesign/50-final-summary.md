# Final Summary — 日报功能完整方案

## 交付成果

一套完整的、可落地的日报功能 redesign 方案，解决了现有系统「数据枯竭 → AI 输出空洞 → 用户不可用」的根本问题。

## 核心设计

### 1. 轻量级数据采集层（零 AI 调用）
- **DailyChatScanner**：扫描今日活跃对话，按重要性排序（消息量 + 用户参与 + @提及 + 关系权重）
- **DailyMessageDigest**：对每个对话筛选关键消息（用户发的消息、被@的消息、含决策关键词的消息）
- 纯 SQLite 查询，性能 < 500ms，零 token 成本

### 2. 统一 AI 生成层（一次调用）
- **UnifiedDailyReportGenerator**：合并现有的 AIDailyReportGenerator + AIDailyRetrospector
- 新 prompt（daily_report_v2.txt）接收丰富的原始消息摘要 + 聚合指标
- 多层防幻觉：prompt 约束 + schema 关联 + heuristics 校验 + retry
- Token 预算：输入 ~4500 tokens，输出 ~1200 tokens，总消耗可控

### 3. 用户体验增强
- **自动预热**：启动后 5 分钟自动生成，之后每 30 分钟刷新
- **缓存机制**：15 分钟有效期，打开 tab 时即时展示
- **数据来源标识**：显示「基于 X 个对话 · Y 条消息」
- **错误处理**：具体错误信息 + 重试按钮 + 多层降级（AI → 模板 → 统计）

### 4. 配置面板
- 扫描对话数量上限（5/8/12/20）
- 每对话消息上限（10/20/30）
- 日报有效期（5/15/30/60 分钟）
- 日报风格（正式/简洁/详细）
- 自动预热开关

## 与现有系统的集成

- **零数据库改动**：日报数据为临时计算结果，通过内存+文件缓存
- **最小侵入**：只修改 4 个现有文件，新增 7 个文件
- **向后兼容**：保留现有 DailyReport 模型、AIDailyReportGenerator、AIDailyRetrospector
- **逐步迁移**：新系统并行运行，旧系统作为 fallback

## 实现路线图

| 里程碑 | 内容 | 预计时间 | 验证标准 |
|--------|------|---------|---------|
| M1 | DailyChatScanner + DailyMessageDigest | 2-3 天 | 扫描返回正确排序，摘要筛选合理 |
| M2 | UnifiedDailyReportGenerator + 新 prompt | 2-3 天 | AI 输出含具体来源，wechatDraft 可用 |
| M3 | 缓存 + 自动预热 + UI 增强 | 1-2 天 | 打开 tab 即时展示，后台预热无感知 |
| M4 | 配置面板 | 1 天 | 设置持久化，修改后生效 |
| M5 | 集成测试 + 优化 | 2 天 | 端到端通过，token < 6000，耗时 < 15s |

**总计：8-11 天**

## 修正记录

根据 Evaluator 反馈修正了 3 个阻塞问题：
1. **移除 WeChatReader 改动** → 复用现有 `getMessages()`
2. **解决 actor 隔离** → 逻辑移到 ChatMonitor（已是 @MainActor）
3. **收紧 token 预算** → 每对话 10 消息，总上限 60 条，输入 ~4500 tokens

## 残留风险

1. **Prompt 调优**：新 prompt 的输出质量需要 1-2 天实测调优
2. **群聊噪音**：大群消息可能稀释质量，建议增加群聊占比上限
3. **多设备**：只包含当前设备的聊天记录

## 下一步行动

1. 按路线图 M1 开始实现 DailyChatScanner
2. 并行编写 daily_report_v2.txt prompt 并做初步测试
3. M2 完成后做端到端集成测试，验证 token 消耗和输出质量
