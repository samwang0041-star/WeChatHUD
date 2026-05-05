# Iteration Contract — 日报方案设计（第 1 轮）

## Cycle Goal
基于产品规格，产出可落地的完整技术设计方案，包括数据流、服务拆分、数据模型、prompt 策略、UI 改动和集成方案。

## Deliverables
1. **技术架构文档** — 新服务（DailyChatScanner、DailyMessageDigest、统一日报生成器）的职责、接口和协作关系
2. **数据流图** — 从 WeChat DB → 筛选 → 摘要 → AI → 展示的全链路
3. **数据模型改动** — 新增/修改的 struct/class，向后兼容方案
4. **Prompt 设计方案** — 新 prompt 的输入格式、输出 schema、防幻觉策略
5. **UI 改动方案** — DailyReportTabView 的增强点、配置面板设计
6. **自动预热方案** — 后台定时任务的设计
7. **Token/性能预算** — 明确各环节的 token 消耗和性能指标
8. **实现路线图** — 分阶段的文件改动清单，每阶段可验证

## Acceptance Criteria
- [ ] 每个新服务都有明确的 actor/protocol 定义
- [ ] 数据流图覆盖从 WeChat DB 到最终 UI 的完整链路
- [ ] Prompt 设计包含完整的输入模板和输出 schema
- [ ] 所有改动能在现有代码库中最小侵入式实现
- [ ] 向后兼容：不删除现有表、不破坏现有 API
- [ ] Token 预算有明确的分项预算（扫描、摘要、生成）
- [ ] 有明确的 fallback/降级策略
- [ ] 实现路线图分 5 个里程碑，每个有验证标准

## Verification Method
1. 检查每个 deliverable 是否完整（文件/段落覆盖）
2. 对照现有代码验证接口定义的可行性（类型检查、actor 隔离）
3. 对照评估标准检查质量维度
4. 估算改造成本（新增文件数、修改文件数、行数）

## Out-of-Scope
- 实际代码实现（本轮只产出设计方案）
- 单元测试代码
- 新的 AI provider 接入
- 多语言支持
- 历史日报归档

## File Ownership
- Generator 写：技术方案文档（本 contract 的所有 deliverables）
- Evaluator 读：10-product-spec.md + 本 contract + Generator 产出
- Evaluator 写：40-evaluation-report.md

## Stop Condition
- Evaluator 确认方案 PASS，或
- 最多 2 轮 iteration（本轮 + 1 轮修正）

## Agreement Status

AGREED

## Negotiation Log
- Generator 提议：产出完整技术设计方案，8 个 deliverables
- Evaluator 要求：必须包含向后兼容方案和 Token 预算分项
- Generator 确认：已添加向后兼容和 Token 预算为 acceptance criteria
- Evaluator 同意：Contract AGREED
