# WeChatHUD Frontend Craft Loop

长期运行目标的工作流规格。Agent 每次续跑只做 **一刀**：把一个真实界面再逼近一档 CleanMyMac 级工艺。不要问用户。做完写日志、独立 commit，停在可编译、可测试的树上。

**真源**：本文件 + `docs/design/frontend-craft-loop-log.md`。Goal 卡片只负责续跑。卡片若乱码、过时、或写着「当前停在哪」，以日志状态板为准。

启动词（每次续跑同一句；Goal 卡片应与此相同）：

```
按 docs/design/frontend-craft-loop.md 跑下一刀。
先读 docs/design/frontend-craft-loop-log.md，再读本文件。
选队列里下一刀，审计 → 改一处最高杠杆工艺债 → 验证 → 写日志。
每一刀独立 commit，消息写 why。这一轮只做一刀。
远目标：队列 1–13 都 done（该表面总分 ≥ 8.5，且主动词/空气/短句 ≥ 8）。
```

选刀规则在本文件。日志 `Next` 若与本文件冲突，跟本文件。

---

## 节奏

一轮对话 = 一刀。读日志 → 改 → 验绿 → 写日志 → commit → **这一轮结束**。下一刀等 Goal 下次续跑，或用户再说「下一刀」。

用顺序续跑，不用定时器。不要 `sleep` + echo，不要分钟级 `/loop`：测试和 release 比一分钟长，TICK 会堆在同一刀上。

用户插话时：把手头这刀收到可提交（或明确丢弃）再回答；然后按新指示走。

---

## 这是什么产品

WeChatHUD 是 macOS 原生吸顶助手：刘海岛告诉你「现在要不要看」，工作台让你处理、回顾、配置。它读本机微信库，用 AI 做摘要、草稿、日报、洞察；Autopilot 能代回，但默认关，护栏不能松。

用户要的不是功能清单，是 **打开就知道下一件事，点一下就发生，过程好看**。对标的是 CleanMyMac / 一流 iOS 工具的 **工艺**：极简排版、一屏一事、悬停/按压/弹出/布局都有物理感，设置页像说明书而不是控制台。

不是做成磁盘清理软件。禁止抄 CleanMyMac 的机器人、星球插画、营销口号、扫盘进度环套在静态列表上。

### 两套表面，两套尺子

| 世界 | 窗口 | 用户在干什么 | 视觉 |
|---|---|---|---|
| **岛** | 吸顶 `NSPanel`，不抢焦点 | 瞥一眼、展开收件箱、看横幅、点一行 | 黑底、青玉点缀、字号 10.5–15 |
| **工作台** | `SettingsWindow` + `NavigationSplitView` | 处理今天、改设置、看回顾 | 浅底/深底、青玉主操作、字号 10.5–17 |

岛已经有弹簧、peek、测量管线。工作台仍偏「功能都摊开」。循环的主战场是工作台与设置；岛只修工艺，不重做物理。

---

## 目标感：CleanMyMac 级，翻译到本产品

每一刀用这七条当验收，而不是「更好看一点」。

1. **主动词** — 一屏只有一个明显下一步。其余动作是次级、悬停、或披露后才出现。
2. **稀疏** — 设置页先给 2–5 个日常决定；高级项进「高级设置」。完成当前任务必需的信息不藏。
3. **空气** — 层级靠间距和字重，不靠套框。同一卡片只一层分组底。标题与内容同左缘。
4. **物理** — 悬停有洗层，按下有 0.96 缩放，弹出从上下文长出，页变用 `pageChange`，形态用岛弹簧。曲线走 `CompanionMotion`。
5. **短句** — 标题是人话动词或名词，副标题一句说清后果。禁止 API、JSON、schema、WAL、provider 出现在日常文案。
6. **状态是戏** — 空 / 加载 / 成功 / 失败各有内容和下一步。AI 整理、同步、发送只在真有过程时演戏（Buddy、扫光、回执），不为静态页造假进度。
7. **回执** — 每个会改变世界的动作留下可见结果：已保存、已稍后、待核对、失败可重试。可逆的给撤销。

CleanMyMac 页面结构的对应，用来选刀，不用来抄布局：

| 他们 | 我们 |
|---|---|
| Smart Scan 首页：一句现状 + 一个扫描 | 「今天」：一句「现在几件事」+ 一条主列表 |
| 扫描结果：分组 + 一个清理 | 收件箱 / 待确认：分组 + 一个主动作 |
| Shredder：危险能力，先警告再开 | 自动回复：默认关，开之前确认 |
| 设置：少行、每行一个决定 | 微信连接 / AI 服务 / 使用偏好 |
| 功能页插画 + 一句 + 大按钮 | 工作台一级页：安静标识 + 一句 + 主按钮（用 SF Symbol / 青玉圆，不上新插画库） |

---

## 先读，再改

按顺序读，读到够用为止：

1. `docs/design/frontend-craft-loop-log.md` — 上一刀停在哪（覆盖 Goal 卡片）
2. 本文件
3. `docs/design/ui-language.md` — 不变量，本循环不得改写其条文来迁就一刀
4. 当前表面的 Swift 文件（见队列）
5. 需要时：`CompanionStyle.swift`、`IslandStyle.swift`、`CompanionMotion.swift`、`SettingsRow.swift`、`CompanionProductCopy.swift`
6. 需要时：`docs/2026-09-08-module-navigation-design.md` 里该模块的 1/2/3 级

代码里的设计系统已经存在。一刀是 **用它把页面做干净**，不是再发明一套。

| 用途 | 只走这里 |
|---|---|
| 青玉 / 底 / 边 / mist | `CompanionPalette` |
| 工作台字号 | `WorkspaceType` + `workspaceDisplay/Title/RowTitle/Body/Meta/Micro` |
| 岛字号与行高 | `IslandType` / `IslandMetrics` / `island*` |
| 岛墨色阶 | `IslandInk`（可读字不低于 `meta`） |
| 动效 | `CompanionMotion` + `withMotion` / `companionAnimation` |
| 按压 | `CompanionPressStyle` 或 `IslandPillButtonStyle` |
| 设置行 | `SettingsSection` / `SettingsRow` / `SettingsToggleRow` |
| 用户可见字符串 | `CompanionProductCopy` 或该页自己的 `*Copy` enum |
| 模态 | `CompanionDialog`，不新开 `NSWindow` |

新字号、新颜色、新手写 `withAnimation` / `.animation(`、新 22pt 大标题，都算这一刀失败。

---

## 硬轨

- Autopilot：默认关、置信度 0.8、敏感词、金融 pending、群聊人工确认、会话上限 50。文案必须继续说真话。
- 岛：不改弹簧常数、测量管线、mask、peek 时序，除非这一刀的目标就是修已证实的卡顿，并且 `Island*Tests` 先红后绿。
- 不新开窗口。三级界面用行内展开、右侧详情、`CompanionDialog`。
- 界面中文。`brandPromise` 保持空。
- 不削弱辅助功能：可操作控件有 label；浮层留在宿主 AX 树；尊重 reduceMotion / reduceTransparency。
- 不提交真实微信消息、token、密钥。Preview 只用虚构数据。
- 不把 18 个侧栏项一次合并。信息架构可以在「侧栏」那一刀收，但必须保留旧 `Tab.rawValue` 与深链。
- 不引入 Lottie / 第三方动画 SDK。SwiftUI + 现有 AppKit 弹簧足够。

---

## 一刀怎么跑

完成标准写在每步后面。没达到就不要进入下一步。

### 1. 选刀

按这个顺序，只选一把。日志 `Next` / 状态板提示是线索，选刀规则在这里：

1. 最新一节 `Next` 写着换表面：
   - 该表面**已经有过**总分 ≥ 8.0 → 换。取队列 **1–13** 里下一个 `queued`。
   - 该表面还没有到过 8.0 → **不要换**。留在该表面，进入审计。刀过关还没发生，换表面等于把没做完的页丢进回扫队列。
2. `Next` 点名一条债，或没有写换表面：留在**当前** `in-progress` 表面，债本轮重审，不照抄 `Next`。没有当前 in-progress 时，取 1–13 里序号最小的 `queued`。
3. 1–13 没有 `queued` 了：回扫序号最小的 `in-progress`。
4. 1–13 都 `done`：才动 14–16。

一刀 = 一个页面 + 一个最高杠杆工艺债。队列一行若列了多个文件（11–13），只改其中一个页面。不要同时改岛和工作台。`in-progress` 不是 `done`，不要为了往前走把它标成完成。

完成：日志或回复里写出 `surface`、文件、这一刀的主动词。

### 2. 审计

打开该表面相关 Swift（含它用的 row / dialog / empty）。对照七条目标感和评分表，写下：

- 现在的主动词是什么（若没有，写「无」）
- 眼睛第一眼落到哪，是否就是下一步
- 悬停、按下、展开、关、空、错、加载各有没有设计过
- 哪些文案是实现用语
- 哪些间距/字号是裸数字，应收回 token

打分（见下表）。改之前分数必须写进日志。

圈债：不超过 5 条里只圈一条，选最能把该表面推向 `done` 的。

- `done` 卡在主动词 / 空气 / 短句：圈这三维里**分数最低且 < 8** 的那维对应的债，不要去磨已经 ≥ 8 的维。
- 这三维都 ≥ 8、总分还 < 8.5：再圈物理 / 状态戏 / 稀疏 / 回执。
- 能让用户 3 秒内感到变化的债，优先于收回 token、补按下这种用户几乎看不见的债——除非那一维 < 8 且没有更可见的债。

完成：有 before 分，且列出不超过 5 条债，并圈定唯一要修的那条。

### 3. 改

只修圈定的债。能收进 token / `*Copy` / 现有组件就收，不在页面里堆一次性修饰。

典型一刀（只选一种）：

- 把一页收成「现状一句 + 主列表 + 一个主按钮」，次级动作进悬停或披露
- 设置页日常 3 行，其余进「高级设置」。回答「现在能不能发 / 何时发出去」的行留在首屏
- 补齐悬停洗层、按下缩放、披露 `islandDetailReveal` / `strongEaseOut`
- 重写该页可见文案：短、后果清楚、与代码一致
- 空态改成一句人话 + 一个去处，不再居中堆说明
- 修该页裸 `font` / 随机 opacity，收回 `workspace*` / `IslandInk`

完成：`git diff` 能用一句话说清「用户多感到什么」。

### 4. 验

按下面「验证」做。红了就修到绿，不要带着红分去写下刀。

完成：相关测试绿；release 能编；你能用文字走完该页的悬停→按下→结果。

### 5. 记

追加 `docs/design/frontend-craft-loop-log.md` 一节，并改状态板。有实质代码再 commit。不要把 `docs/overnight/` 未跟踪笔记塞进这一刀。

完成：日志含 before/after 分、改了什么、测了什么、下一刀是谁。这一轮到此。

---

## 表面队列

按用户看见的频率排。状态记在日志。不要跳到队尾去做「更好做的重构」。

| 序 | 表面 | 主文件 | 这一刀要逼近的样子 |
|---|---|---|---|
| 1 | 今天 | `AssistantTodayView.swift`、`CompanionSetupCard.swift` | Smart Scan：一句现状，一条「需要回复」，一个下一步；设置卡只在未就绪时出现 |
| 2 | 岛·展开收件箱 | `InboxView.swift`、`InboxRowView.swift`、`ActionPanelView.swift` | 分组清楚；一行一个主动作；悬停才出次动作；从行移到按钮不误收起 |
| 3 | 岛·通知横幅 | `NotificationBannerView.swift` | 消息是英雄；身份行安静；按下/悬停洗层完整；高度仍走测量 |
| 4 | 岛·紧凑/peek | `CompactInboxBar.swift`、`PixelBuddyView.swift` | 翼上无正文；peek 只加宽；Buddy 悬停才展开详情 |
| 5 | 待确认回复 | `ApprovalWorkspaceView.swift` | 队列 + 一条确认；不是仪表盘 |
| 6 | 自动回复设置 | `AutopilotSettingsView.swift` | 主开关 + 一句后果；连发窗口留在首屏（它回答「何时发出去」，`AutopilotCopyConsistencyTests` 钉死）。每小时上限、会话上限、排除名单进高级 |
| 7 | AI 服务 | `AISettingsView.swift`（service） | 已连接/未连接一句；表单不要压过「能不能用」 |
| 8 | 微信连接 | `SyncSettingsView.swift` connection、`WeChatConnectionSetupView.swift` | 已连/缺什么/下一步；诊断进披露 |
| 9 | 首次引导 | `OnboardingView.swift`、`FirstLaunchAISetupView.swift` | 每步一个决定；点完成不等于已连上或已授权发送 |
| 10 | 关注谁 | `ContactsSettingsView.swift` | 列表 + 一个添加；账号 ID 默认收起 |
| 11 | 待办 / 我答应的 / 草稿 | `DiscussionWorkspaceView.swift`、`CommitmentTabView.swift`、`ReplyDraftsView.swift` | 筛选少、行上一个动词、详情展开再编辑 |
| 12 | 今日小结 / 聊天回顾 / 关系雷达 | `DailyReportTabView.swift`、`ChatInsightView.swift`、`RelationshipRadarView.swift` | 结论在上，出处可展开；无数据不编故事 |
| 13 | 提醒方式 / 使用偏好 / 本地资料 / 怎么用 | 对应 Settings 页、`CompanionGuideView.swift` | 每行一个决定；指南只写已实现能力 |
| 14 | 侧栏与页头 | `SettingsView.swift` | 分组仍是处理/回顾/代回复/设置；可把低频设置收进一页内的 section，不删路由 |
| 15 | 对话详情 / 对话框 | `ConversationDetailView.swift`、`DetailPanelView.swift`、`CompanionDialog` | 先建议后原文；发送有确认和回执 |
| 16 | 全站微交互巡检 | `CompanionStyle.swift`、`CompanionMotion.swift` 的调用点 | 每个可点物有按压；每个可悬停列表有洗层；每个披露有方向 |

同一表面可多刀，直到该表面总分 ≥ 8.5 且「主动词」「空气」「短句」都不低于 8，才标 `done`。

---

## 评分

每项 0–10。总分加权。改前改后都打。

| 维 | 权重 | 10 分长什么样 | 4 分长什么样 |
|---|---|---|---|
| 主动词 | 20% | 3 秒内能说出下一步，主按钮只有一个 | 一排同等按钮，或没有下一步 |
| 空气 | 15% | 用现有 token，对齐不变量 1–2，扫一眼有节奏 | 卡片套卡片，标题居中，疏密随机 |
| 短句 | 15% | 方言语气，与代码一致，无实现词 | 用户必须读完副标题才知道开关干什么 |
| 物理 | 15% | 悬停/按/开/关都走 `CompanionMotion`，方向不对称 | 瞬切，或手写动画，或 reduceMotion 被忽略 |
| 状态戏 | 15% | 空/忙/成/败都能走下去 | 空白、转圈无说明、失败只 print |
| 稀疏 | 10% | 日常决定在首屏，高级在披露里 | 首屏是表单墙 |
| 回执 | 10% | 做完看得到，错了能重来，可逆能撤销 | 点了没反应，或假成功 |

惩罚（每项 −0.5，可叠）：新开窗口；新色盘；岛弹簧被无测试改动；日常文案出现实现词；主按钮超过一个还同样强调；把必看信息只放进 tooltip。

打分纪律（不守则 stall / done 都作假）：

- 没改到的维，After = Before。同一处编辑明显连带的，最多 +0.2。
- 圈定维单刀升幅 > 2.0 视为灌分，压回 ≤ 2.0，并在日志写清依据。
- 走查点名的控件文案必须出现在本刀 diff 里。

两道门槛，不要混：

| 门槛 | 数字 | 含义 |
|---|---|---|
| 这一刀过关 | 总分 ≥ 8.0，且主动词 ≥ 8 | 这一刀把该表面推近了。低于此，日志写清为什么还要再来 |
| 该表面 `done` | 总分 ≥ 8.5，且主动词 / 空气 / 短句都不低于 8 | 才能把状态板改成 `done`。整轮完成 = 队列 1–13 都 `done` |

---

## 验证

本刀动到的套件必须绿；`swift build -c release` 必须过。

一次 `swift test` 里写多个 `--filter` 是 **或**（并集），不是与。要只跑一个套件就只写一个 `--filter`。相关套件可以写在同一条命令里，靠或来并起来。

没动岛时，不必把 `Island*Tests` 当作本刀证据；release 编过即可证明没把岛编坏。动到岛形态 / 测量 / hover 时再加：`IslandRowExpandTests`、`IslandPeekTests`、`IslandFrameSpringTests`、`IslandInteractionTests`、`CompactIslandPolicyTests`。

动到设置持久化 / Autopilot 文案时加对应 `*Settings*` / `Autopilot*`。

Live 用例只在 `WCHUD_LIVE_COMPANION_AI=1` 时跑；未设置时必须是显式 skip。不要为了「全绿」去设这个变量。

无法在真机点一遍时，用文字走查代替，但必须写到日志：悬停谁、按下谁、展开什么、失败走哪。不要用一张静态布局描述代替交互。

`make preview` 只在本机有图形会话且这一刀改了可见布局时跑。

---

## 日志格式

追加到 `docs/design/frontend-craft-loop-log.md`，一刀一节：

```markdown
## Cycle N — YYYY-MM-DD — <表面名>

- Surface: <队列名>
- Files: <路径>
- Before: 总分 x.x（主动词/空气/短句/物理/状态戏/稀疏/回执）
- Debt picked: <一句话>
- After: 总分 x.x
- Changed: <用户能感到的变化，不要列文件补丁>
- Verified: <命令与结果>
- Next: <队列下一刀>
```

---

## 停

不要把下面几种情况混成一种「收工」：

| 情况 | 做什么 |
|---|---|
| 相关测试或 release 编不过，这一刀内修不回 | 停这一刀。树回到可编译。Goal 保持。不要标 `done` |
| 下一刀必须改产品规则（例如默认自动发送）才能「更好看」 | 跳过那条债，换债（仍按审计优先顺序）。整轮继续 |
| 连续两刀同一表面总分提升都 < 0.3，**且**该表面已经有过总分 ≥ 8.0 | 换到 1–13 里下一个 `queued`。该表面保持 `in-progress`，留给回扫。整轮继续 |
| 连续两刀提升都 < 0.3，但该表面还没有到过 8.0 | 留下。换债，不要换表面。`Next` 禁止写「换表面」 |

用户说停，整轮才停。不要因为「已经过了一晚」或「已经砍了十几刀」把 Goal 标完成。

整轮完成：队列 1–13 都 `done`。那时才可以结束 Goal。14–16 不是完成条件。
