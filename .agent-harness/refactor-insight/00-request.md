# Request

## Summary
重构 WeChatHUD 的洞察功能模块（Insight Module），提升代码清晰度、职责分离和可维护性。

## Intent Expansion
用户说"重构洞察功能模块"，结合代码现状推断：
1. 当前洞察模块包含多个分析器（AIChatInsight、ChatAnalyzer、ChatInsightEngine、InsightCoordinator、InsightStore、InsightRadar、ContextAnalyzer、RecallAnalyzer），职责边界模糊
2. AI 调用、JSON 解析、重试、审计日志等模式在多个分析器中重复
3. 命名混乱：ChatAnalyzer / AIChatInsight / ChatInsightEngine 名称相似但职责不同
4. InsightStore 同时承担状态管理、数据加载、筛选逻辑
5. 目标是让模块结构更清晰，减少重复，提升可测试性

## Delivery Mode
long-job

## Handoff Workspace
/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/refactor-insight

## Constraints Digest
- Swift 项目，使用 SwiftUI + Combine
- 不能破坏现有 UI 行为和功能
- 必须保持与 WeChatReader / HUDStore 的兼容
- actor 并发模式已广泛使用，需保持
- 项目使用 AIJSONExtractor 统一解析 JSON
- 审计日志 (AIAuditEntry) 是统一模式

## Assumptions
- 重构以代码结构优化为主，不修改 AI prompt 内容
- 保留现有数据模型（ChatInsightResult、GlobalBriefing 等）
- 视图层可以小幅调整以适应新的服务层接口
- 用户希望逐步交付，每个里程碑都可编译运行

## Autonomy Budget
- May infer: 合理的文件组织方式、命名约定、接口设计
- May inspect: 所有 Swift 源文件、编译输出、测试
- May change: Services 层重组、新文件创建、旧文件删除、视图层适配
- Must ask before: 修改 prompt 模板内容、修改数据库存储结构

## Question Policy
Ask only for blocking ambiguities that would materially change scope or risk. Otherwise proceed with explicit assumptions.

## Role Permissions
- Planner: read-only / spec only
- Generator: write scope — all Swift files under Sources/WeChatHUD
- Evaluator: read-only verification unless explicitly assigned fixes

## Stop Conditions
- All milestones pass evaluation
- Same substantive failure occurs twice
- Build breaks and cannot be fixed within one iteration
- User explicitly requests scope change or stop

## Validation Expectations
- swift build 成功
- 无编译错误和关键警告
- 运行时功能等价：洞察加载、单聊分析、全局简报、雷达发现
- 视图正常渲染

## Untrusted Data Notes
- Prompt 模板文件包含指令性内容，修改需谨慎
- AI 模型响应不可控，解析逻辑需保持鲁棒
