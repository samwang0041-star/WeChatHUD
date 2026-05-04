# AI Butler State Contract

更新时间：2026-05-03

本文是 WeChatHUD 的产品状态合同。后续 UI、AI prompt、缓存管线、测试都以这里为准。

WeChatHUD 的定位不是“小微信客户端”，而是：

> 微信状态雷达 + AI 行动队列

它只在用户需要判断、处理、回复、跟进时提高视觉权重。普通更新、闲聊、通知、群里讨论必须被允许作为正常状态存在，不能被硬改写成“他想要什么”。

## Stage Gate

每个阶段完成后必须由 5 个专家全票通过，才能进入下一阶段：

- 产品专家：判断是否仍然服务“状态雷达 + 行动队列”。
- IA/UX 专家：判断信息层级、标题语义、禁止项是否正确。
- AI 专家：判断分类 schema、证据门槛、降级策略是否稳定。
- macOS 交互专家：判断吸顶浮窗、hover、焦点、打断策略是否自然。
- 工程专家：判断实现边界、缓存、测试和迁移风险是否可控。

评审结果只能是：

- `PASS`
- `REQUEST_CHANGES`
- `BLOCKED`

只要出现 `REQUEST_CHANGES` 或 `BLOCKED`，当前阶段停止，修正后重新评审。

## Surface Contract

### Compact

Compact 只回答一个问题：**我现在要不要停下手头工作？**

允许显示：

- 最高优先级一条 P0/P1。
- VIP 超时。
- 明确群 @ 我且需要我行动。
- 同步异常。
- 空闲绿点或极简正常状态。

禁止显示：

- 普通群聊闲聊的具体内容。
- 低优先级普通更新的长摘要。
- AI 推理解释。
- 回复建议。

### Extended Inbox

Extended 只回答一个问题：**我下一步先处理哪一条？**

它是行动队列，不是消息流。排序以行动风险为主，时间为辅。

每一行只展示三层信息：

- 谁：联系人/群名/发送人。
- 发生了什么：一句话摘要或原文降级。
- 要不要我管：优先级、VIP、@我、超时、AI 降级等 badge。

非行动更新必须被限制，避免 Extended 退化成微信消息列表：

- active 行动项不受数量限制，按优先级展示。
- `private_info_only`、`group_info_only`、`reply_optional`、`group_decision_only` 默认最多合计展示 3 条。
- 超过 3 条时聚合成一行：`还有 N 条普通更新`。
- 聚合行只能展开普通更新列表，不能抢 Compact 主位。
- 普通更新不参与 P0/P1 视觉权重，不显示红/黄风险色。
- `group_decision_only` 如来自高优先级群，可以在 3 条中优先保留 1 条；超过后进入聚合。

### ActionPanel

ActionPanel 只回答一个问题：**这条到底是什么意思，我该不该处理？**

标题必须从状态派生，不能固定为“他想要什么”。

### Detail

Detail 是主动工作台，不是提醒层。

允许显示：

- 最近消息上下文。
- 关系记忆。
- 待处理事项。
- 回复建议。
- 承诺和历史风险。

Detail 打开时有新的 P0/P1，只能用顶部内联提示，不允许强行 collapse 或 hover 打断。

Detail 是显式进入的模式。hover 离开不能自动关闭 Detail。

### Retrospective

复盘是时间跨度层，只处理跨天/跨周的重点、承诺、风险和证据。

禁止把即时聊天解释、普通单条消息、正在加载的 AI 分析塞进复盘主内容。

## macOS Interaction Contract

吸顶 HUD 必须保持“轻触、低打断”的 macOS 原生感。

- Compact hover 展开到 Extended 时，不应主动抢当前 app 焦点。
- Extended 可以响应鼠标点击，但只有用户明确点击输入框、弹窗、菜单等交互控件时，才允许成为 key window。
- 打开微信前必须先收起 HUD，并短暂抑制 hover 反弹。
- Detail 是主动工作台，不受 hover enter/exit 自动收起影响。
- snooze popover、菜单、设置弹窗打开时，HUD 不能因为鼠标离开 row 而坍塌。

事件优先级：

| 当前状态 | 事件 | 行为 |
| --- | --- | --- |
| Compact | mouse enter | 展开到 Extended，不 makeKey，不激活 App |
| Extended | mouse leave | 400ms 后回 Compact；若 popover/menu 打开则保持 |
| Extended | row click | 展开/收起 ActionPanel；不主动 makeKey |
| Extended | text input / popover / menu click | 允许成为 key window |
| Extended | 打开微信 | 先 collapse，再打开微信；抑制 hover 反弹 1.5s 或直到鼠标离开 HUD 区域 |
| Detail | mouse leave | 保持 Detail |
| Detail | close button / Esc | 回 Compact |
| Detail | 查看新急事 | 回 Extended 并选中对应 item |
| Detail | 打开微信 | collapse 并打开微信 |
| 任意 | app deactivate | 不因 deactivate 自动清空状态，只按当前状态规则收起 |

## Notification Interruption Contract

Notification banner 是短暂打断层，只允许用于真正需要注意的事件。

允许触发 banner：

- P0/P1 私聊请求。
- VIP 风险或 VIP 超时。
- 明确 `group_action_required`。
- 高优先级 `group_mention_fyi`。
- 承诺到期。
- 同步/权限异常。
- 用户显式配置的“所有白名单都打断”模式。

默认禁止触发 banner：

- `group_info_only`。
- `private_info_only`。
- 普通图片、表情、链接分享。
- `group_decision_only`，除非用户配置为高优先级群。
- AI loading / AI failed 自身。

优先级规则：

- Detail 已打开时，任何新 P0/P1、VIP 风险、群 @ 都不弹 banner，改为 Detail 顶部内联提示。
- `group_mention_fyi` 只有满足以下任一条件才可触发 banner：VIP 群、白名单高优先级群、@ 来自 VIP/管理员/关键联系人、或 10 分钟内连续 2 次以上 @ 我。
- 普通 `group_mention_fyi` 只进入 Extended，不打断。
- 用户显式开启“所有白名单都打断”时，可以绕过默认禁止项，但 UI 必须显示这是用户配置模式。

banner 点击规则：

- 点击主体：进入 Detail，这是显式主动模式；进入 Detail 后忽略 hover enter/exit，不能因 hover 自动 collapse。
- 点击微信按钮：继承全局打开微信行为，先 collapse HUD，再打开微信，并抑制 hover 反弹 1.5s 或直到鼠标离开 HUD 区域。
- 点击忽略：只忽略本轮，不静音长期对话。

## Canonical Presentation State

Stage 1 可以先用当前字段推导展示状态；Stage 2 让 AI 输出消息语义子集，再由本地 presentation composer 合成完整展示状态。

```swift
enum InboxSemanticState: String, Codable {
    case idle = "idle"
    case syncIssue = "sync_issue"
    case privateInfoOnly = "private_info_only"
    case privateActionRequired = "private_action_required"
    case privateVIPRisk = "private_vip_risk"
    case groupInfoOnly = "group_info_only"
    case groupMentionFYI = "group_mention_fyi"
    case groupActionRequired = "group_action_required"
    case groupDecisionOnly = "group_decision_only"
    case replyOptional = "reply_optional"
    case commitmentDue = "commitment_due"
    case autopilotReview = "autopilot_review"
    case aiLoading = "ai_loading"
    case aiFailed = "ai_failed"
    case handled = "handled"
}
```

snake_case raw value 是唯一跨层 wire format。Swift 代码可以使用 camelCase case 名，但 Codable、AI 输出、缓存、日志和文档表格都必须使用 snake_case raw value。

所有 UI 决策必须从 `InboxSemanticState` 派生：

- ActionPanel 标题。
- CTA 文案。
- 是否显示回复建议。
- 是否允许进入 Compact 主位。
- 是否允许触发 notification banner。
- badge 颜色。
- fallback 文案。

禁止在 UI 层直接用单个 boolean 作为最终语义：

- `actionRequired` 只能作为输入信号，不能等价于 `privateActionRequired` 或 `groupActionRequired`。
- `isAtMention` 只能说明“提到我”，不能等价于“需要我处理”。
- `isVIP` 只能说明关系权重，不能等价于 P0。

Stage 1 必须引入临时展示适配器，不改持久化模型：

```swift
struct InboxPresentationItem: Identifiable {
    let id: String
    let sourceItem: InboxItem?
    let state: InboxSemanticState
    let title: String
    let subtitle: String
    let primaryCTA: PresentationCTA
    let secondaryCTAs: [PresentationCTA]
    let replySuggestionMode: ReplySuggestionMode
    let compactEligibility: SurfaceEligibility
    let bannerEligibility: SurfaceEligibility
    let badgeTone: BadgeTone
    let fallback: PresentationFallback?
    let groupedChildren: [InboxItem]
}

enum ReplySuggestionMode {
    case hidden
    case manual
    case automatic
}
```

Stage 1 保守推导规则：

- 群聊 `isAtMention == true` 但没有已存储 ask/action 证据：推导为 `group_mention_fyi`，不能推导为 `group_action_required`。
- 群聊 `actionRequired == true` 但证据来源只是 @：推导为 `group_mention_fyi`。
- 私聊 `actionRequired == true` 可先推导为 `private_action_required`，但 UI 文案必须允许 AI failed/低置信降级。
- `handled`、聚合普通更新、sync issue、commitment、autopilot review 都是 presentation item，不要求塞进 `InboxItem`。

## State Taxonomy

### `idle`

含义：同步正常，没有 active action。

展示：

- Compact：绿点或极简正常状态。
- Extended：空态或“一切正常”。
- ActionPanel：不出现。

主交互：无。

禁止项：

- 不制造待处理感。
- 不显示 AI 卡片。

### `sync_issue`

含义：微信未运行、数据库不可读、同步过久、权限异常、AI 配置错误等基础能力不可靠。

展示：

- Compact：黄/红状态点。
- Extended header：短错误原因。
- ActionPanel：不出现。

主交互：

- 重试同步。
- 打开微信。
- 打开设置。

禁止项：

- 不把同步问题包装成聊天待办。
- 不显示空白 AI 分析。

### `private_info_only`

含义：私聊有新内容，但不是明确请求，也不需要用户立刻回复。

展示：

- Compact：默认不抢占，只计入低优先级更新。
- Extended row：`联系人 · 摘要`，低权重。
- ActionPanel 标题：`对话更新`。

主交互：

- 打开微信查看。
- 忽略本轮。
- 稍后。

禁止项：

- 不显示“他想要什么”。
- 不默认生成回复建议。
- 不标成 P0/P1，除非本地规则或 AI 证据证明需要回复。

### `private_action_required`

含义：私聊明确要求用户本人做事、回答、确认、提供信息、给时间或做决定。

展示：

- Compact：可展示联系人 + 行动摘要。
- Extended row：黄/红点 + 摘要 + 等待时长。
- ActionPanel 标题：`他想要什么`。

主交互：

- 打开微信回复。
- 回复建议。
- 稍后。
- 查看详情。

禁止项：

- 没有 target=me 的证据不能进入此状态。
- 没有 action 证据不能进入此状态。

### `private_vip_risk`

含义：VIP 私聊、关键联系人、关系风险或超时。

展示：

- Compact：VIP + 超时/风险提示。
- Extended row：VIP badge、情绪/关系风险、等待时长。
- ActionPanel 标题：`需要尽快回复` 或 `重要联系人消息`。

主交互：

- 立即回复。
- 回复建议。
- 查看关系脉络。
- 忙碌托管。

禁止项：

- 不把所有 VIP 普通闲聊都升成 P0。
- 风险必须来自超时、情绪、历史承诺或明确请求。

### `group_info_only`

含义：群聊普通讨论、闲聊、分享、图片、普通更新，没有明确指向用户的行动要求。

展示：

- Compact：不显示具体内容，最多贡献更新数。
- Extended row：`群名 · 发送人: 摘要`，低权重。
- ActionPanel 标题：`群里在聊什么`。

主交互：

- 打开群聊查看。
- 忽略本轮。
- 稍后。

禁止项：

- 不显示“他想要什么”。
- 不显示“需要你处理”。
- 不默认显示回复建议。
- 不因为群聊热闹而抢 Compact 主位。

### `group_mention_fyi`

含义：群里 @ 用户或提到用户，但只是通知、礼貌提及、抄送、FYI，没有明确动作。

展示：

- Compact：只在优先级较高时显示。
- Extended row：`有人@你` + 短摘要。
- ActionPanel 标题：`为什么@你`。

主交互：

- 查看上下文。
- 打开群聊。
- 忽略本轮。

禁止项：

- 没有明确行动时不显示“需要你处理”。
- 不自动生成回复建议。

### `group_action_required`

含义：群里明确要求用户本人回应、确认、处理、决策、提供材料或跟进。

展示：

- Compact：群名/发送人 + 行动摘要。
- Extended row：`@你`、黄/红点、行动摘要。
- ActionPanel 标题：`需要你处理`。

主交互：

- 打开群聊回复。
- 回复建议。
- 查看上下文。
- 稍后。

禁止项：

- 群里没有 @ 我、没有明确名字、上下文不能唯一指向我时，不能升级到此状态。
- 对方描述自己要做的事，不能改写成用户待办。

### `group_decision_only`

含义：群里已经形成决议、结论、安排或风险信息，但不需要用户本人行动。

展示：

- Compact：默认不抢占。
- Extended row：`群里有决议` + 摘要。
- ActionPanel 标题：`已有决议`。

主交互：

- 打开查看。
- 标记已看。
- 进入复盘时可作为 highlight。

禁止项：

- 不显示回复建议。
- 不显示“需要你处理”。

### `reply_optional`

含义：可以回复，但不回复不会卡住事情。常见于寒暄、近况、轻量问候、低风险社交消息。

展示：

- Compact：默认不抢占。
- Extended row：低权重，可显示 `可回` badge。
- ActionPanel 标题：`可以回一句`。

主交互：

- 想回一句。
- 打开微信。
- 忽略。

禁止项：

- 不用红色。
- 不放进 P0。

### `commitment_due`

含义：用户承诺过的事项临近或到期。

展示：

- Compact：到期或高风险时显示。
- Extended row：承诺内容、对象、截止时间。
- ActionPanel 标题：`承诺快到期` 或 `承诺已到期`。

主交互：

- 标记完成。
- 打开微信跟进。
- 延期。

禁止项：

- 不和普通未读混排成一样的视觉权重。

### `autopilot_review`

含义：托管生成了候选回复，但需要用户确认。

展示：

- Compact：有待确认时显示数量。
- Extended row：待确认回复、风险原因。
- ActionPanel 标题：`托管待确认`。

主交互：

- 发送。
- 编辑。
- 丢弃。
- 暂停托管。

禁止项：

- 不自动发送高风险内容。
- 不隐藏跳过原因。

### `ai_loading`

含义：AI 分析尚未完成。

展示：

- Compact：不显示 loading 解释。
- Extended row：保留原文 preview 或本地摘要。
- ActionPanel：`AI 正在整理重点...`。

主交互：

- 打开微信。
- 等待。

禁止项：

- 不空白。
- 不阻止用户打开微信。

### `ai_failed`

含义：AI 未配置、超时、接口错误、JSON 解析失败或低置信。

展示：

- Compact：不抢主位，除非同时存在 P0/P1 本地风险。
- Extended row：原文 preview + 弱提示。
- ActionPanel 标题：`分析暂不可用`。

主交互：

- 打开微信。
- 重试分析。
- 打开 AI 设置。

禁止项：

- 不把失败显示成红色聊天风险。
- 不显示“AI 分析返回为空”这类内部错误作为主内容。
- 不因为 AI 失败就隐藏原文 preview。

### `handled`

含义：已忽略、已回复、已稍后、已静音。

展示：

- Compact：不显示。
- Extended：进入已处理区，默认折叠。
- ActionPanel：只允许恢复或查看。

主交互：

- 撤销。
- 恢复。
- 取消静音。

禁止项：

- 不继续参与 active count。
- 新消息到达前不重新激活 dismissed 项。

## Priority Order

主队列排序优先级：

1. `private_vip_risk` 且超时。
2. `group_action_required` / `private_action_required` 且 P0。
3. `commitment_due`。
4. `autopilot_review`。
5. `private_vip_risk` 普通新消息。
6. `group_mention_fyi`。
7. `private_action_required` P1。
8. `reply_optional`。
9. `group_decision_only`。
10. `private_info_only` / `group_info_only`。
11. `ai_failed` / `ai_loading` 降级态。
12. `handled`。

## ActionPanel Title Contract

| 状态 | 标题 |
| --- | --- |
| `private_action_required` | `他想要什么` |
| `private_vip_risk` | 超时/关系风险：`需要尽快回复`；普通 VIP 新消息：`重要联系人消息` |
| `private_info_only` | `对话更新` |
| `reply_optional` | `可以回一句` |
| `group_info_only` | `群里在聊什么` |
| `group_mention_fyi` | `为什么@你` |
| `group_action_required` | `需要你处理` |
| `group_decision_only` | `已有决议` |
| `commitment_due` | 未过期：`承诺快到期`；已过期：`承诺已到期` |
| `autopilot_review` | `托管待确认` |
| `ai_loading` | `AI 正在整理重点` |
| `ai_failed` | `分析暂不可用` |
| `handled` | 无普通分析标题；恢复面板只显示 `已处理` |

## Presentation Matrix

Stage 1 UI 必须从这张表派生主要展示，不允许每个 View 自己猜。

| 状态 | 主 CTA | 次 CTA | 回复建议 | Compact | Banner | Badge |
| --- | --- | --- | --- | --- | --- | --- |
| `idle` | 无 | 无 | hidden | idle only | no | green |
| `sync_issue` | `重试同步` | `打开设置`, `打开微信` | hidden | yes | yes | yellow/red |
| `private_info_only` | `打开微信查看` | `忽略`, `稍后` | manual | no | no | gray |
| `private_action_required` | `打开微信回复` | `回复建议`, `稍后`, `查看详情` | automatic | yes if P0/P1 | yes if P0/P1 | yellow/red |
| `private_vip_risk` | `立即回复` | `回复建议`, `关系脉络`, `托管` | automatic if action/overdue, otherwise manual | yes | yes if overdue/risk | orange/red |
| `group_info_only` | `打开群聊查看` | `忽略`, `稍后` | hidden | no | no | gray |
| `group_mention_fyi` | `查看上下文` | `打开群聊`, `忽略` | manual | yes if highPriorityFYI | yes if highPriorityFYI | blue |
| `group_action_required` | `打开群聊回复` | `回复建议`, `查看上下文`, `稍后` | automatic | yes | yes | yellow/red |
| `group_decision_only` | `打开查看` | `标记已看` | hidden | no | no unless high-priority group | blue/gray |
| `reply_optional` | `想回一句` | `打开微信`, `忽略` | manual | no | no | gray |
| `commitment_due` | `打开微信跟进` | `标记完成`, `延期` | manual | yes if due/overdue | yes if due/overdue | orange/red |
| `autopilot_review` | `审核回复` | `暂停托管` | hidden | yes if pending | yes if high-risk pending | purple |
| `ai_loading` | `打开微信查看` | 无 | hidden | no | no | gray |
| `ai_failed` | `打开微信查看` | `重试分析`, `AI 设置` | hidden | no unless local P0/P1 | no | gray/red weak |
| `handled` | `恢复` | silenced: `取消静音`; otherwise: `查看记录` | hidden | no | no | gray |

`private_vip_risk` 的 `automatic if action/overdue` 条件：

- overdueMinutes > 0。
- priority 为 P0/P1。
- 存在明确请求、承诺、情绪风险或连续未回。

`highPriorityFYI` 使用 Notification Interruption Contract 中同一组规则：VIP 群、白名单高优先级群、@ 来自 VIP/管理员/关键联系人、或 10 分钟内连续 2 次以上 @ 我。

BadgeTone 谓词：

| Badge 表达 | 具体规则 |
| --- | --- |
| green | `idle` |
| gray | 非行动、非风险、非失败 |
| blue | @ 我 FYI、群决议、需要查看但不需要行动 |
| yellow | P1 行动项、未超时承诺、普通同步警告 |
| orange | VIP 风险、承诺临近、非过期托管待确认 |
| red | P0、超时、同步严重错误、承诺已过期 |
| purple | 托管待确认 |
| gray/red weak | AI failed 默认 gray；只有同时存在本地 P0/P1 风险时加弱 red 提示 |

当表格里出现 `yellow/red`、`orange/red`、`blue/gray` 这类表达时，必须按上述谓词选择单一 `BadgeTone`，不能让 View 自行选择。

## Reply Suggestion Policy

默认生成回复建议：

- `private_action_required`
- `group_action_required`
- `private_vip_risk` 且满足 Presentation Matrix 中 `automatic if action/overdue` 条件

可由用户点击后生成：

- `reply_optional`
- `private_info_only`
- `group_mention_fyi`

禁止默认生成：

- `group_info_only`
- `group_decision_only`
- `ai_loading`
- `ai_failed`
- `handled`

## AI Classification Gate

AI 必须先分类，再摘要，再生成回复。

Stage 2 的机器输出必须对齐下面的 schema。Stage 1 如果还没有这套 AI 结果，也必须用本地字段推导出同名展示状态。

AI 只输出“消息语义子集”。系统状态和合成状态由本地 presentation composer 产生：

- AI 可输出：`private_action_required`、`private_info_only`、`private_vip_risk`、`group_action_required`、`group_mention_fyi`、`group_info_only`、`group_decision_only`、`reply_optional`、`ai_failed`。
- 本地系统/合成输出：`idle`、`sync_issue`、`commitment_due`、`autopilot_review`、`ai_loading`、`handled`。

```json
{
  "schema_version": "ai_butler_signal_v1",
  "state": "private_action_required|private_info_only|private_vip_risk|group_action_required|group_mention_fyi|group_info_only|group_decision_only|reply_optional|ai_failed",
  "target": "me|other_person|group|unclear|none",
  "target_identity_match": {
    "matched": false,
    "source": "at_me|wechat_id|display_name|group_alias|explicit_resolver|none",
    "matched_text": ""
  },
  "target_evidence": ["原文短证据"],
  "action": "用户可执行动作；没有则为空",
  "action_evidence": ["原文短证据"],
  "blocking_reason": "不处理会卡住什么；没有则为空",
  "non_task_kind": "none|social|info|media|ack|link|decision|third_party|unknown",
  "confidence": 0.0,
  "summary": "列表使用的一句话摘要",
  "headline": "ActionPanel 使用的一句话标题内容",
  "reply_suggestion_policy": {
    "should_generate": false,
    "reason": "ok|no_action|low_confidence|media_only|needs_manual_context|ai_failed"
  },
  "fallback": {
    "analysis_status": "ok|loading|failed|low_confidence|not_configured|timeout|parse_error",
    "fallback_preview": "AI 不可用时显示的原文或本地摘要",
    "fallback_badge": "AI未配置|AI超时|低置信|分析暂不可用",
    "retryable": true,
    "cta_policy": "open_wechat|retry_ai|open_settings|none"
  }
}
```

action 状态必须设置 `non_task_kind = "none"`。

进入 `action_required` 必须同时满足：

1. 明确指向用户本人：`target = me`。
2. 有可引用原文证据支持 target。
3. 有可引用原文证据支持 action。
4. 用户不处理会让对话或事项卡住。
5. `confidence >= 0.75`。

最低证据数量：

- `target_evidence.count >= 1`。
- `action_evidence.count >= 1`。
- `blocking_reason` 非空。

置信区间：

- `>= 0.75`：允许进入 action-required 状态。
- `0.45..<0.75`：只能进入 `reply_optional`、`private_info_only`、`group_mention_fyi`、`group_info_only`、`group_decision_only`。
- `< 0.45`：进入 `ai_failed` 或使用本地 fallback preview，不显示强行动文案。

如果缺任何一项，必须降级到：

- 私聊：`reply_optional` 或 `private_info_only`。
- 群聊普通讨论：`group_info_only`。
- 群聊已有结论但无需用户行动：`group_decision_only`。
- 群聊 @ 我但无行动：`group_mention_fyi`。
- 低置信或 AI 不可靠：`ai_failed`，并保留 fallback preview。

群聊升级规则：

- 无 @ 我、无明确名字、上下文不能唯一指向我：最高只能到 `group_info_only` 或 `group_decision_only`。
- @ 我但无明确行动：只能到 `group_mention_fyi`。
- 任务指向别人：必须标为 third-party，不得改写成用户待办。
- `group_mention_fyi` 必须有 `target_identity_match.matched = true` 或明确 @ 我；松散提到一个同名词不算。
- `group_action_required` 必须有证据字面命中用户身份之一：微信名、备注名、群昵称、@我，且 `target_identity_match.matched = true`。
- “当前会话中唯一可证明的用户代称”不能由 AI 自行推断，必须来自本地 resolver 输出并写入 `target_identity_match.source = "explicit_resolver"`。
- `@张三` 这类示例只有在张三是用户身份变体时才允许视为 target=me，否则必须进入 third-party 或 group_info_only。

非任务是成功输出，不是失败：

- 闲聊。
- 表情。
- 单张图片。
- 链接分享。
- 系统通知。
- 群里讨论。
- 对方描述自己要做的事。
- 对别人说的话。

## Fallback Contract

AI 不可靠时必须保留可用体验：

- 未配置：显示原文 preview + `AI 未配置` 弱提示。
- 超时：显示本地判断 + `AI 超时` 弱提示。
- JSON 解析失败：显示原文 preview + `分析暂不可用`。
- 低置信：显示 `可能需要你看一下`，CTA 用打开查看，不用回复。
- 非任务：不显示错误，也不显示空回复建议区域。

fallback 必须是可渲染数据，不是日志字符串：

- `analysis_status`：`ok|loading|failed|low_confidence|not_configured|timeout|parse_error`。
- `fallback_preview`：原文 preview 或本地摘要。
- `fallback_badge`：给 UI 的短标签。
- `retryable`：是否显示重试。
- `cta_policy`：`open_wechat|retry_ai|open_settings|none`。

禁止把内部错误作为主标题，例如 `AI 分析返回为空`、`JSON parse failed`、`HTTP 401`。这些只能进入调试日志或二级说明。

## Detail / Retrospective Boundary Matrix

| 状态 | Detail 边界 | 复盘边界 |
| --- | --- | --- |
| `idle` | 不进入 Detail | 不进入复盘 |
| `sync_issue` | 只进设置/诊断，不进聊天 Detail | 只作为系统健康信息，不进聊天复盘 |
| `private_info_only` | 可查看最近消息和关系记忆 | 默认不收录，除非跨期形成主题 |
| `private_action_required` | 显示上下文、行动、回复建议 | 未处理跨期时收录为待办/风险 |
| `private_vip_risk` | 显示关系脉络、超时原因、建议动作 | 收录为关系风险或重点联系人事件 |
| `group_info_only` | 显示群聊最近脉络 | 默认不收录，除非成为高价值主题 |
| `group_mention_fyi` | 显示 @ 前后上下文 | 只在跨期仍相关时收录 |
| `group_action_required` | 显示任务证据、上下文、回复建议 | 未处理跨期时收录为待办/风险 |
| `group_decision_only` | 显示决议证据和相关发言 | 可收录为决议 highlight |
| `reply_optional` | 可生成“想回一句”，不显示强待办 | 默认不收录 |
| `commitment_due` | 显示承诺来源和跟进动作 | 必须收录为承诺状态 |
| `autopilot_review` | 显示候选回复、风险原因、审核动作 | 可收录为托管审核记录 |
| `ai_loading` | 不阻止 Detail，显示原文降级 | 不收录 loading 状态 |
| `ai_failed` | 显示原文和重试/设置入口 | 不把失败本身收录为聊天重点 |
| `handled` | 只允许恢复或查看记录 | 已处理项默认不收录，除非是承诺完成记录 |

## Stage 0 Acceptance Criteria

Stage 0 通过条件：

- 每个状态都有 Compact、Extended、ActionPanel、Detail/复盘的展示边界。
- 每个状态都有允许交互和禁止项。
- 每个 UI 决策都能追溯到 `InboxSemanticState`。
- 非行动更新默认限量/折叠，不会把 Extended 变成消息列表。
- 群聊普通闲聊不会再进入“他想要什么”。
- 非任务是合法状态，不被当成 AI 失败。
- AI 输出 schema 明确包含 state、target、证据、非任务类型、回复策略和 fallback 数据。
- AI 失败不会造成空白 UI。
- Notification banner 默认只打断高优先级事件。
- hover 展开不主动抢当前 app 焦点。
- Detail/复盘和即时收件箱边界清楚。
- 后续 Stage 1 可以直接按本合同修改 UI。
