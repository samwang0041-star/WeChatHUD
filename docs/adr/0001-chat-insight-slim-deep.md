# ADR-0001: ChatInsight 从"全面但浅"转向"精简但深"

## Status

Accepted

## Context

ChatInsight 的 prompt 要求 AI 输出 20+ 个字段（topics、attitudes、tone_changes、mood_shift、silentMembers、recalledNotes、ignoredNotes、participants、relationship_signal、symmetry 等），但 maxTokens 只有 1200。每个字段平均只能分到 ~50 tokens，导致 AI 被迫蜻蜓点水 —— 所有字段都有、所有字段都浅。

用户反馈：分析太空泛，看了等于没看。态度判断不准、情绪转折瞎猜、暗信号基本是填充。

## Decision

1. **单聊分析砍字段**：移除所有需要历史对比才能判断的推断型字段（attitudes、tone_changes、mood_shift、silentMembers、recalledNotes、ignoredNotes、participants、relationship_signal、symmetry）。单聊分析只做事实提取：headline、topics、action_items、mentions_me、waiting_for_me、my_commitments、decisions、overall_mood、importance_to_me、insight、suggestion。

2. **单聊分析加深**：maxTokens 从 1200 提到 2500。prompt 中加入该聊天过去 7 天的关键话题/承诺作为对比上下文，让 AI 能判断"这是新话题还是老话题的延续"。

3. **关系雷达独立出来**：态度变化、语气变化、沉默检测、关系趋势等分析交给独立的后台模块。输入是过去 30 天的单聊分析结果，定期（每周）跑。不在当前 sprint 实现，架构预留。

4. **全局简报简化输入**：不再把 20 个单聊的完整 JSON 塞给 AI。只传每个聊天的 headline + action_items + waiting_for_me。maxTokens 提到 2000。

## Consequences

- **Positive**：核心字段有足够 token 预算展开，分析质量显著提升。用户不再被一堆浅而准的推断型字段干扰。
- **Positive**：架构更清晰 — 事实提取（单聊）和趋势推断（关系雷达）职责分离。
- **Negative**：InsightRadar 需要重构，因为它当前依赖 attitudes/tone_changes 等被砍的字段生成 findings。findings 将基于 topics/action_items/waiting_for_me 重新设计。
- **Negative**：关系雷达尚未实现，短期内用户看不到态度/情绪趋势分析。这是有意识的分阶段交付。

## Alternatives considered

- **只增加 maxTokens（不切字段）**：从 1200 提到 4000。Rejected：即使 token 够了，单天数据 inherently 无法做态度变化/情绪转折判断，这些字段的底层数据就不支持，token 再多也做不准。
- **保持现状，等关系雷达上线后再切**：Rejected：关系雷达是长期项目，用户现在就需要能用的 ChatInsight。先让单聊分析变好用，再逐步叠加关系雷达。
