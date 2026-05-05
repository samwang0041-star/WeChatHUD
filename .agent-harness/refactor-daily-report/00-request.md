# 00-request.md — Daily Report Refactor

## Request Summary
用户要求重构日报（Daily Report）功能，认为当前实现"基本是废的"。

## Intent Expansion
日报是 WeChatHUD 的核心功能之一，用于每日复盘微信聊天活动。当前实现存在以下问题：
- UI 展示可能不够直观或有价值
- 数据聚合和分析可能不够深入
- 用户可能觉得日报没有提供有意义的洞察
- 需要重新设计使其成为用户每天真正想看的功能

## Delivery Mode
Long-job delivery — this is a substantial refactor requiring deep understanding, redesign, and careful implementation.

## Handoff Workspace
`/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/refactor-daily-report/`

## Constraints Digest
- Swift/SwiftUI macOS app
- Existing architecture with HUDStore, AI services, WeChatReader
- Must maintain backward compatibility where possible
- Should integrate with existing menu bar and settings UI

## Assumptions
- 用户希望日报提供真正有意义的每日聊天洞察
- 需要更好的数据可视化和分析
- UI 需要重新设计以提升用户体验
- 可能需要利用 AI 生成更有价值的总结

## Autonomy Budget
- 可以修改任何与日报相关的代码
- 可以添加新的数据模型和服务
- 可以重构 UI 组件
- 需要用户确认重大架构变更

## Question Policy
Ask only for blocking ambiguities that would materially change scope, risk, or user experience. Otherwise proceed with explicit assumptions.

## Role Permissions
- Planner: read-only research
- Generator: full write access to product files
- Evaluator: read-only, can request patches

## Stop Conditions
- Daily report feature passes evaluation rubric
- No blocking issues remain
- User approves final implementation

## Validation Expectations
- UI renders correctly
- Data flows properly from WeChat to report
- Report generation works end-to-end
- Menu bar integration functions
- Settings configuration works
