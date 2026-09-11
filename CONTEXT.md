# WeChatHUD

macOS 原生吸顶浮窗客户端，配合 wechat-cli 使用。核心功能：读取微信加密 DB、AI 分析通信态势、生成日报/洞察。

## Language

**自动托管 (Autopilot)**:
AI 自动代管微信聊天回复的系统。核心目标：在用户不方便回复时（开会、睡觉、忙碌），让 AI 代为回复，且对方察觉不到是机器在代管。由 AutopilotService 编排，包含消息批处理、回复时机模拟（模拟真人打字间隔）、风格一致性评分、敏感词防护、会话账本（防止自我矛盾）。

**实际模式（以代码为准）**：默认关闭（`autoSendEnabled = false`），打开后是"全自动 + 多层护栏"：置信度阈值 0.8，敏感词命中、风险非低、VIP、风格偏差降级为缓兵之计；转账/红包/小程序强制 pending；群聊消息（含 @ 提醒）只出草稿，一律人工确认；每会话发送上限 50 条。置信度三档：高（直接发）、中（AI 结合上下文生成缓兵之计）、低（read-no-reply）。**回复质量要求**：缓兵之计由 AI 自由生成（非代码模板），结合具体对话上下文，避免同一联系人在短时间内收到重复话术。

**ChatInsight**:
聊天洞察系统。帮用户 1 分钟看到所有聊天的全貌，重点是文字背后看不到的东西 — 情绪暗流、态度信号、关系变化、被忽略的信息。

**单聊分析**:
基于某一天的消息做事实提取。输出：headline、topics、action_items、mentions_me、waiting_for_me、my_commitments、decisions、insight、suggestion。不包含态度/情绪/暗信号推断 — 那些需要历史对比，单天数据做不了。
_Avoid_: 把 attitudes/tone_changes/mood_shift 放进单聊分析。

**关系雷达**:
基于长期数据（跨天、跨周）做趋势分析。输出：态度变化、语气变化、沉默检测、关系趋势。独立于单聊分析，后台定期跑。尚未实现，架构预留。

**推断型字段**:
需要历史对比才能判断的字段：attitudes、tone_changes、mood_shift、silentMembers、recalledNotes、ignoredNotes、participants、relationship_signal、symmetry。单聊分析不做这些，留给关系雷达。

**全局简报**:
基于所有单聊分析结果 + 关系雷达数据生成的全局态势总结。输入是精简后的单聊关键信息（不是完整 JSON），确保 AI 有足够输出空间。

## Relationships

- **单聊分析** → **全局简报**：单聊输出 headline + action_items + waiting_for_me，作为全局简报的输入
- **单聊分析** → **关系雷达**：单聊的 topics/decisions 积累为历史数据，关系雷达基于这些做趋势判断
- **关系雷达** → **全局简报**：关系雷达输出 dark_signals/态度趋势，丰富全局简报

## Example dialogue

> **Dev:** "单聊分析要不要做态度判断？"
> **Domain expert:** "不做。单聊只看一天消息，判断不了态度变化。态度分析留给关系雷达，它需要 30 天历史对比。"
>
> **Dev:** "全局简报怎么避免太空泛？"
> **Domain expert:** "不要塞 20 个单聊的完整 JSON 给 AI。只传每个聊天的 headline + action_items + waiting_for_me，给 AI 留出 2000 tokens 写输出。"
