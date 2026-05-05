# Agent Harness Request — 日报功能完整方案设计

## Request Summary
用户反馈："现在这个日报功能几乎不可用，你给我设计一个完整的日报方案。"

## Intent Expansion
用户期望的是一个**可落地、可验证、有具体实现路径**的日报系统 redesign，而非纸上谈兵。当前日报系统存在根本性数据枯竭问题——依赖 retrospective run 产出的 highlights/todos，但 retrospective 是用户手动触发的重型流程，导致日报在绝大多数场景下内容空洞。需要一套从数据采集→AI 生成→展示消费→定时触发的完整闭环方案。

## Delivery Mode
**Long-job delivery** — 需要产出完整的设计文档、技术方案、实现路线图，并确保方案在现有架构中可落地。

## Handoff Workspace
`/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-redesign/`

## Constraints Digest
- macOS Swift/SwiftUI 应用，使用 SQLite 本地存储
- AI 调用通过 AIService actor，支持多 provider fallback
- 已有 retrospective pipeline（RetrospectiveJob → RetrospectiveAnalyzer → SummarySynthesizer）
- 已有 ChatMonitor 作为数据聚合中心
- 已有 DailyReport/DailyReportBuilder/AIDailyReportGenerator/AIDailyRetrospector
- Prompt 文件存储在 Resources/prompts/ 中，通过 PromptLoader 加载
- 日报展示在 DailyReportTabView（SwiftUI）中
- 复盘窗口是独立的 NSWindow（RetrospectiveWindowManager）

## Assumptions
1. 用户希望日报是**自动生成的**，不需要手动触发 retrospective
2. 日报质量的关键瓶颈是**输入数据质量**，不是 prompt engineering
3. 用户认可「数据越多越好，但必须在 token 预算内」的原则
4. 日报应该覆盖「今天」的数据（0:00-now），但也可以回溯历史日期
5. 用户可能希望日报可以直接复制粘贴发送给上级（wechat_draft 字段仍有价值）

## Autonomy Budget
- 可自由阅读任何项目文件以理解现有架构
- 可自由设计新的数据模型、服务、prompt 策略
- 不可修改生产代码（本阶段只产出设计方案）
- 不可删除现有功能，只能提出废弃/合并建议

## Question Policy
只在以下情况询问用户：
1. 方案涉及外部依赖（如接入日历 API、企业微信 API）
2. 需要用户确认成本/隐私权衡（如增加聊天记录读取量）
3. 现有架构约束与方案冲突且无法绕过

## Stop Conditions
- 产出完整的设计文档（10-product-spec.md 级别）
- 产出技术实现方案（数据流、服务拆分、prompt 策略）
- 产出实现路线图（分阶段，每阶段可验证）
- 产出与现有代码的集成方案（最小侵入式改造）
- Evaluator 确认方案完整性和可落地性

## Validation Expectations
- 方案必须能在现有代码库中落地
- 每个设计决策必须有明确的权衡说明
- 必须包含 fallback / 降级策略
- 必须考虑性能影响（AI 调用成本、token 消耗）
