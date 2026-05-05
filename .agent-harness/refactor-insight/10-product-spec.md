# Product / Task Spec: 洞察功能模块重构

## Outcome
洞察模块的代码结构清晰、职责分离明确、重复逻辑消除。所有分析器遵循统一的接口模式和基础设施。编译通过，功能完全等价。

## Target User
未来维护该代码库的开发者（包括原作者和协作者）。

## Current State Analysis

### 问题诊断

1. **分析器职责重叠与命名混乱**
   - `AIChatInsight`：单聊深度洞察（AI驱动，返回 ChatInsightResult）
   - `ChatAnalyzer`：群聊/私聊摘要（AI驱动，返回 GroupAnalysis/PrivateAnalysis）
   - `ChatInsightEngine`：纯算法统计（无AI，返回 ChatStatsData + GlobalOverview）
   - `ContextAnalyzer`：pending ask 上下文分析
   - `RecallAnalyzer`：撤回消息分析
   - 五个分析器有四个都走相同的 AI 调用 → 解析 → 重试 → 审计流程，但各自实现

2. **协调层与数据层耦合**
   - `InsightCoordinator`：既调度任务又直接调用 reader/store 准备数据，还管理AI服务
   - `InsightStore`：同时是 ObservableObject 状态容器、数据加载器、筛选器
   - `ChatMonitor` 也包含洞察入口方法（`refreshInsightInBackground`、`analyzeOneChat`）

3. **重复模式（每处独立实现）**
   - AI HTTP 调用 + timeout + activity tracking
   - JSON 解析 + 失败后追加严格指令重试
   - 审计日志写入（writeAudit）
   - Prompt 模板加载和插值
   - 消息格式化（formatMessages）

4. **模块边界模糊**
   - Services/Insight 没有子目录，所有分析器平铺在 Services/
   - 数据模型 ChatInsightModels.swift 同时包含 AI 结果、统计结果、关键词洞察类型

## Scope

### In-Scope
1. 提取统一的 AI 分析基础设施（`AIAnalysisPipeline`）
2. 重组 Insight 相关服务，建立清晰的目录结构
3. 统一分析器接口模式（protocol-based）
4. 拆分 `InsightStore` 的状态管理与数据加载职责
5. 清理 `InsightCoordinator`，使其专注于调度而非分析
6. 视图层最小适配（仅接口调整，不改动 UI 结构）

### Non-Goals
- 不修改任何 prompt 模板内容
- 不修改数据模型字段（可迁移文件位置，不改定义）
- 不修改数据库 schema
- 不改写核心算法逻辑（只改组织结构）
- 不新增功能或删除现有功能

## Milestones / Vertical Slices

### M1: AI 分析基础设施提取
创建 `AIAnalysisPipeline` actor，统一封装：
- AI 调用（timeout、temperature、maxTokens、JSON mode）
- 重试机制（追加严格指令后重试一次）
- JSON 解析（通过 AIJSONExtractor）
- 审计日志自动写入
- Activity tracking 自动管理

所有现有分析器的 call/writeAudit/parse 逻辑迁移到使用 pipeline。

### M2: 洞察核心服务重组
- 将 `AIChatInsight` + `InsightCoordinator` 的 AI 分析部分合并为 `ChatInsightService`
- 将 `ChatInsightEngine` 重命名为 `ChatStatsEngine`，职责不变
- `InsightCoordinator` 简化为纯调度器，不再直接处理 AI 调用

### M3: 其他分析器统一改造
- `ChatAnalyzer` → `ChatSummaryService`（统一使用 pipeline）
- `ContextAnalyzer` → `ContextAnalysisService`（统一使用 pipeline）
- `RecallAnalyzer` → `RecallAnalysisService`（统一使用 pipeline）

### M4: Store 与状态管理清理
- `InsightStore` 保留为纯 ObservableObject 状态容器
- 提取 `InsightDataLoader` 负责数据加载和筛选逻辑
- `ChatMonitor` 中的洞察入口方法委托给 `InsightCoordinator`

### M5: 目录整理与最终验证
- 创建 `Services/Insight/` 子目录
- 移动相关文件
- 全量编译验证
- 运行时功能验证

## Constraints
- 必须保持 Swift actor 并发模式
- 必须保持与 WeChatReader / HUDStore 的现有接口兼容
- 视图层绑定（@Published、@EnvironmentObject）必须继续工作
- 项目必须能编译通过（swift build）

## Acceptance Criteria
- [ ] swift build 无错误
- [ ] 无新增编译警告
- [ ] ChatInsightView 正常加载统计数据
- [ ] AI 洞察分析流程正常（单聊分析 → 全局简报 → 雷达发现）
- [ ] 其他分析器（ChatSummary、Context、Recall）功能正常
- [ ] 代码重复度显著降低（AI 调用/审计/解析逻辑不再分散在各处）

## Risks
- 视图层对 `InsightCoordinator` / `InsightStore` 的依赖较深，改名/改签名可能引发连锁修改
- actor 隔离边界变更可能导致编译错误
- `ChatMonitor` 中的洞察方法与 `InsightCoordinator` 可能有竞态或重复逻辑
