# WeChatHUD Frontend Craft Loop

每次续跑只做 **一刀**：把一个真实页面再逼近一档工艺。不要问用户。做完写日志、独立 commit。

远目标：队列 **1–13** 都 `done`（该页总分 ≥ 8.5，且主动词 / 空气 / 短句 ≥ 8）。14–16 不是完成条件。用户说停，整轮才停。Goal 未完成时不要把会话停在「等下一脚」。

**权威（从上到下，只跟最上面那条还活着的）：**

1. 本文件的选刀、圈债、停
2. 日志状态板的状态与分数
3. 日志 `Next`、状态板「下一刀提示」、Goal 卡片 — 线索，不是命令

启动词（Goal 卡片应与此相同）：

```
按 docs/design/frontend-craft-loop.md 跑下一刀。
先读本文件的选刀，再读 docs/design/frontend-craft-loop-log.md 的状态板。
选刀覆盖日志 Next。审计后只改一处最高杠杆工艺债。
验证、写日志、独立 commit（why）。1–13 未 done 则立刻选下一刀，不要停等 Goal 续跑。
远目标：队列 1–13 都 done（总分 ≥ 8.5，且主动词/空气/短句 ≥ 8）。
```

---

## 这一轮

读选刀 → 打开该页 → 审计圈债 → 改 → 验绿（release 必须在本回合等完）→ 写日志 → commit。然后：若 1–13 还没都 `done`，**立刻选下一刀**。不要等 Goal 再踢一脚，不要因为 release 编完的「告知结果」就收工。

顺序续跑。不要 `sleep`、不要分钟级 `/loop`。用户插话时，把手头这刀收到可提交（或明确丢弃）再按新指示走。用户说停，整轮才停。

---

## 1. 选刀

只选一个页面。队列一行若列了多个文件（11–13），只改其中一个页面。不要同时改岛和工作台。

查日志状态板，按这个顺序决定 **哪一页**：

1. 看最新一节是哪一页。若它是 `in-progress`，且日志里**从未**打出总分 ≥ 8.0 → 留下这一页。即使 `Next` 写着换表面。
2. 最新 `Next` 写着换表面，且那一页**已经**有过总分 ≥ 8.0 → 换到 1–13 里下一个 `queued`。
3. 否则：当前 `in-progress` 留下（债本轮重审）。没有 in-progress 时，取 1–13 里序号最小的 `queued`。
4. 1–13 没有 `queued` 了：回扫序号最小的 `in-progress`。
5. 1–13 都 `done`：才动 14–16。

`in-progress` 不是 `done`。不要为了往前走把一页标成完成。

完成：写出 `surface`、文件、这一刀的主动词。

---

## 2. 审计

打开该页相关 Swift（含它用的 row / dialog / empty）。对照下面七条，写下：

- 现在的主动词是什么（若没有，写「无」）
- 眼睛第一眼落到哪，是否就是下一步
- 悬停、按下、展开、关、空、错、加载各有没有设计过
- 哪些文案是实现用语
- 哪些间距/字号是裸数字，应收回 token

Before 分必须写进日志。最多列 5 条债，只圈一条。

圈哪一条 — 选最能把该页推向 `done` 的：

| 该页现在 | 圈 |
|---|---|
| 主动词 / 空气 / 短句里有 < 8 | 这三维里**分数最低**的那维对应的债 |
| 这三维都 ≥ 8，总分 < 8.5 | 物理 / 状态戏 / 稀疏 / 回执里用户 3 秒内能感到的那条 |
| 总分从未 ≥ 8.0 | 留下。`Next` 写「还要再来哪条债」，不写换表面 |

已经 ≥ 8 的维不要再磨。能让用户 3 秒内感到变化的债，优先于只收回 token、只补按下。

完成：有 Before 分、≤5 条债、圈定唯一一条。

---

## 3. 改

只修圈定的债。能收进 token / `*Copy` / 现有组件就收。

只选一种：

- 一页收成「现状一句 + 主列表 + 一个主按钮」，次级进悬停或披露
- 设置页日常 3 行，其余进「高级设置」。回答「现在能不能发 / 何时发出去 / 能不能用」的行留在首屏
- 补齐悬停洗层、按下缩放、披露 `islandDetailReveal` / `strongEaseOut`
- 重写该页可见文案：短、后果清楚、与代码一致
- 空态改成一句人话 + 一个去处
- 该页裸 `font` / 随机 opacity 收回 `workspace*` / `IslandInk`

完成：`git diff` 能用一句话说清用户多感到什么。

---

## 4. 验

本刀动到的套件必须绿；`swift build -c release` 必须过。红了就修到绿。

`swift build -c release` 在本回合内等到结束再 commit（等待至少 90 秒）。不要丢到后台再结束回合：后台编完会变成「告知用户结果」，Goal 看起来像停了。

一次 `swift test` 里多个 `--filter` 是 **或**。只跑一个套件就只写一个 `--filter`。

没动岛时，不必把 `Island*Tests` 当本刀证据。动到岛形态 / 测量 / hover 时再加：`IslandRowExpandTests`、`IslandPeekTests`、`IslandFrameSpringTests`、`IslandInteractionTests`、`CompactIslandPolicyTests`。动到设置持久化 / Autopilot 文案时加对应 `*Settings*` / `Autopilot*`。

Live 用例只在 `WCHUD_LIVE_COMPANION_AI=1` 时跑；未设置时必须是显式 skip。不要为了「全绿」去设这个变量。

走查写到日志：悬停谁、按下谁、展开什么、失败走哪。点名的控件文案必须出现在本刀 diff 里。`make preview` 只在本机有图形会话且改了可见布局时跑。

完成：相关测试绿；release 能编；走查是交互，不是静帧。

---

## 5. 记

追加 `docs/design/frontend-craft-loop-log.md` 一节，并改状态板。有实质代码再 commit。不要把 `docs/overnight/` 未跟踪笔记塞进这一刀。消息写 why。

```markdown
## Cycle N — YYYY-MM-DD — <页面名>

- Surface: <队列名>
- Files: <路径>
- Before: 总分 x.x（主动词/空气/短句/物理/状态戏/稀疏/回执）
- Debt picked: <一句话>
- After: 总分 x.x（七维，没改到的维 = Before）
- Changed: <用户能感到的变化>
- Verified: <命令与结果>
- Next: <留下则写下一条债；达到换表面条件才写换到哪一页>
```

完成：日志含 Before/After、改了什么、测了什么、下一刀是谁。1–13 未 done 则接着砍，不要把「这一轮到此」当成 Goal 结束。

---

## 停

| 情况 | 做什么 |
|---|---|
| 测试或 release 编不过，这一刀内修不回 | 树回到可编译。Goal 保持。不要标 `done` |
| 下一条债必须改产品规则才能「更好看」（例如默认自动发送） | 跳过，按圈债表换债。整轮继续 |
| 连续两刀总分升幅都 < 0.3，且该页**已经**有过总分 ≥ 8.0 | 换到 1–13 下一个 `queued`。本页保持 `in-progress` |
| 连续两刀升幅都 < 0.3，但该页还没有到过 8.0 | 留下，换债。`Next` 不写换表面 |

不要因为过了一晚、已经砍了十几刀、或 release 编完的系统通知就把 Goal 标完成或停手。整轮完成 = 状态板 1–13 都是 `done`。那时才结束 Goal。

---

## 目标感

每一刀用这七条验收，而不是「更好看一点」。

1. **主动词** — 一屏一个明显下一步。其余是次级、悬停、或披露后才出现。
2. **稀疏** — 设置页先给 2–5 个日常决定；高级进披露。当前任务必需的信息不藏。
3. **空气** — 层级靠间距和字重。同一卡片只一层分组底。标题与内容同左缘。
4. **物理** — 悬停洗层，按下 0.96，弹出从上下文长出。曲线走 `CompanionMotion`。
5. **短句** — 标题是人话动词或名词，副标题一句后果。日常文案不出现 API、JSON、schema、WAL、provider。
6. **状态是戏** — 空 / 加载 / 成功 / 失败各有内容和下一步。只在真有过程时演戏，不为静态页造假进度。
7. **回执** — 会改变世界的动作留下可见结果。可逆的给撤销。

对标 CleanMyMac 的是工艺，不是抄它的机器人、星球、营销口号、扫盘进度环。

| 世界 | 窗口 | 用户在干什么 | 视觉 |
|---|---|---|---|
| **岛** | 吸顶 `NSPanel`，不抢焦点 | 瞥一眼、展开收件箱、看横幅 | 黑底、青玉、10.5–15 |
| **工作台** | `SettingsWindow` + `NavigationSplitView` | 处理、回顾、配置 | 浅底/深底、青玉主操作、10.5–17 |

岛只修工艺，不重做弹簧 / 测量 / mask / peek 时序。主战场是工作台与设置。

---

## 硬轨

- Autopilot：默认关、置信度 0.8、敏感词、金融 pending、群聊人工确认、会话上限 50。文案说真话。
- 岛弹簧 / 测量 / mask / peek：除非这一刀就是修已证实的卡顿，并且 `Island*Tests` 先红后绿。
- 不新开窗口。三级用行内展开、右侧详情、`CompanionDialog`。
- 界面中文。`brandPromise` 保持空。
- 可操作控件有 label；浮层留在宿主 AX 树；尊重 reduceMotion / reduceTransparency。
- 不提交真实微信消息、token、密钥。Preview 只用虚构数据。
- 不把 18 个侧栏项一次合并。改信息架构必须保留旧 `Tab.rawValue` 与深链。
- 不引入 Lottie / 第三方动画 SDK。
- 不改写 `docs/design/ui-language.md` 的条文来迁就一刀。

设计系统已经存在。一刀是用它把页面做干净。

| 用途 | 只走这里 |
|---|---|
| 青玉 / 底 / 边 / mist | `CompanionPalette` |
| 工作台字号 | `WorkspaceType` + `workspaceDisplay/Title/RowTitle/Body/Meta/Micro` |
| 岛字号与行高 | `IslandType` / `IslandMetrics` / `island*` |
| 岛墨色阶 | `IslandInk`（可读字不低于 `meta`） |
| 动效 | `CompanionMotion` + `withMotion` / `companionAnimation` |
| 按压 | `CompanionPressStyle` 或 `IslandPillButtonStyle` |
| 设置行 | `SettingsSection` / `SettingsRow` / `SettingsToggleRow` |
| 用户可见字符串 | `CompanionProductCopy` 或该页 `*Copy` |
| 模态 | `CompanionDialog` |

新字号、新颜色、新手写 `withAnimation` / `.animation(`、新 22pt 大标题，这一刀失败。

需要时再读：`docs/design/ui-language.md`、`CompanionStyle.swift`、`IslandStyle.swift`、`CompanionMotion.swift`、`SettingsRow.swift`、`CompanionProductCopy.swift`、`docs/2026-09-08-module-navigation-design.md` 里该模块的 1/2/3 级。

---

## 表面队列

按用户看见的频率排。状态记在日志。不要跳到队尾做「更好做的重构」。

| 序 | 表面 | 主文件 | 逼近 |
|---|---|---|---|
| 1 | 今天 | `AssistantTodayView.swift`、`CompanionSetupCard.swift` | 一句现状，一条「需要回复」，一个下一步；设置卡只在未就绪时出现 |
| 2 | 岛·展开收件箱 | `InboxView.swift`、`InboxRowView.swift`、`ActionPanelView.swift` | 分组清楚；一行一个主动作；悬停才出次动作 |
| 3 | 岛·通知横幅 | `NotificationBannerView.swift` | 消息是英雄；按下/悬停洗层完整；高度仍走测量 |
| 4 | 岛·紧凑/peek | `CompactInboxBar.swift`、`PixelBuddyView.swift` | 翼上无正文；peek 只加宽；Buddy 悬停才展开详情 |
| 5 | 待确认回复 | `ApprovalWorkspaceView.swift` | 队列 + 一条确认；不是仪表盘 |
| 6 | 自动回复设置 | `AutopilotSettingsView.swift` | 主开关 + 一句后果；连发窗口留在首屏（`AutopilotCopyConsistencyTests` 钉死）。每小时上限、会话上限、排除名单进高级 |
| 7 | AI 服务 | `AISettingsView.swift`（service） | 已连接/未连接一句；表单不要压过「能不能用」 |
| 8 | 微信连接 | `SyncSettingsView.swift` connection、`WeChatConnectionSetupView.swift` | 已连/缺什么/下一步；诊断进披露 |
| 9 | 首次引导 | `OnboardingView.swift`、`FirstLaunchAISetupView.swift` | 每步一个决定；点完成不等于已连上或已授权发送 |
| 10 | 关注谁 | `ContactsSettingsView.swift` | 列表 + 一个添加；账号 ID 默认收起 |
| 11 | 待办 / 我答应的 / 草稿 | `DiscussionWorkspaceView.swift`、`CommitmentTabView.swift`、`ReplyDraftsView.swift` | 一刀只改其中一页；行上一个动词 |
| 12 | 今日小结 / 聊天回顾 / 关系雷达 | `DailyReportTabView.swift`、`ChatInsightView.swift`、`RelationshipRadarView.swift` | 一刀只改其中一页；结论在上，无数据不编故事 |
| 13 | 提醒方式 / 使用偏好 / 本地资料 / 怎么用 | 对应 Settings 页、`CompanionGuideView.swift` | 一刀只改其中一页；指南只写已实现能力 |
| 14 | 侧栏与页头 | `SettingsView.swift` | 分组仍是处理/回顾/代回复/设置；不删路由 |
| 15 | 对话详情 / 对话框 | `ConversationDetailView.swift`、`DetailPanelView.swift`、`CompanionDialog` | 先建议后原文；发送有确认和回执 |
| 16 | 全站微交互巡检 | `CompanionStyle.swift`、`CompanionMotion.swift` 的调用点 | 每个可点物有按压；每个可悬停列表有洗层 |

同一页可多刀，直到总分 ≥ 8.5 且主动词 / 空气 / 短句都不低于 8，才标 `done`。

---

## 评分

每项 0–10。总分加权。改前改后都打。

| 维 | 权重 | 10 | 4 |
|---|---|---|---|
| 主动词 | 20% | 3 秒内能说出下一步，主按钮只有一个 | 一排同等按钮，或没有下一步 |
| 空气 | 15% | 用现有 token，扫一眼有节奏 | 卡片套卡片，疏密随机 |
| 短句 | 15% | 方言语气，与代码一致，无实现词 | 读完副标题才知道开关干什么 |
| 物理 | 15% | 悬停/按/开/关走 `CompanionMotion` | 瞬切，或手写动画 |
| 状态戏 | 15% | 空/忙/成/败都能走下去 | 空白、失败只 print |
| 稀疏 | 10% | 日常决定在首屏，高级在披露里 | 首屏是表单墙 |
| 回执 | 10% | 做完看得到，错了能重来 | 点了没反应，或假成功 |

惩罚（每项 −0.5，可叠）：新开窗口；新色盘；岛弹簧被无测试改动；日常文案出现实现词；主按钮超过一个还同样强调；把必看信息只放进 tooltip。

打分纪律：

- 没改到的维，After = Before。同一处编辑明显连带的，最多 +0.2。
- 圈定维单刀升幅 > 2.0 视为灌分，压回 ≤ 2.0。
- 走查点名的文案必须出现在本刀 diff 里。

两道门槛：

| 门槛 | 何时 | 做什么 |
|---|---|---|
| 换表面 | 该页日志里**曾经**总分 ≥ 8.0，且最近连续两刀总分升幅都 < 0.3 | 换下一个 `queued`，本页保持 `in-progress` |
| 该页 `done` | 总分 ≥ 8.5，且主动词 / 空气 / 短句 ≥ 8 | 状态板改成 `done` |
