# Frontend Craft Loop — 进度

循环规格：`docs/design/frontend-craft-loop.md`（长期目标：一刀接一刀，直到队列 1–13 done）。
一刀一节，新的写在最上面。

## 状态板

| 序 | 表面 | 状态 | 最近总分 | 下一刀提示 |
|---|---|---|---|---|
| 1 | 今天 | done | 8.5 | 设置卡未就绪时仍用系统 accent；留给首次引导那一刀 |
| 2 | 岛·展开收件箱 | done | 8.5 | 刘海齿轮已写「设置」；稍后/关闭无字留给巡检 |
| 3 | 岛·通知横幅 | in-progress | 8.4 | 稍后/关闭仍无字；连续两刀提升过小，换表面 |
| 4 | 岛·紧凑/peek | in-progress | 8.2 | 连续两刀 <0.3，换表面；peek 口述「移入查看」留给巡检 |
| 5 | 待确认回复 | in-progress | 7.8 | 连续两刀 <0.3，换表面；即将发送仍并排取消/立即发送 |
| 6 | 自动回复设置 | in-progress | 6.9 | 连发卡仍套在卡片里；页头链接仍无按下 |
| 7 | AI 服务 | queued | — | |
| 8 | 微信连接 | queued | — | |
| 9 | 首次引导 | queued | — | |
| 10 | 关注谁 | queued | — | |
| 11 | 待办 / 我答应的 / 草稿 | queued | — | |
| 12 | 今日小结 / 聊天回顾 / 关系雷达 | queued | — | |
| 13 | 提醒方式 / 使用偏好 / 本地资料 / 怎么用 | queued | — | |
| 14 | 侧栏与页头 | queued | — | 勿第一刀就合并 18 个 tab |
| 15 | 对话详情 / 对话框 | queued | — | |
| 16 | 全站微交互巡检 | queued | — | 放在多数页面主动词成立之后 |

## Cycle 21 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.6（主动词 6.5 / 空气 5.5 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 页头「查看待确认回复」用青玉、中字重，看起来像这一页的下一步，把「自动发出去」挤到后面。
- After: 总分 6.9（主动词 8.0 / 空气 5.5 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 页头只说现在有没有在整理；「查看待确认回复」是安静的次级去处。下一步是「自动发出去」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 24 个用例全绿；`swift build -c release`。走查：开页 → 先看到状态句 → 主开关在卡片第一行 → 点「查看待确认回复」仍进待确认；开自动发出去仍弹确认。
- Next: 自动回复设置第三刀 — 连发卡仍套在卡片里。总分未过 8.0。

## Cycle 20 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.0（主动词 6.0 / 空气 5.0 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 4.0 / 回执 7.5）
- Debt picked: 首屏是表单墙：每小时上限、会话上限、排除名单和日常发送规则挤在一起。
- After: 总分 6.6（主动词 6.5 / 空气 5.5 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 打开这一页先看到能不能发、把握门槛、连发要等几秒、哪些一定交给你。上限和排除名单在「高级设置」里。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 23 个用例全绿；`swift build -c release`。走查：开页 → 自动发出去（关则草稿）→ 连发窗口仍在首屏 → 展开高级设置才见每小时/本次整理/不会自动回复的人；开自动发出去仍弹确认。
- Next: 自动回复设置第二刀 — 页头「查看待确认回复」和主开关抢视线；连发卡仍套在卡片里。总分未过 8.0，主动词未到 8。

## Cycle 19 — 2026-09-13 — 待确认回复

- Surface: 待确认回复
- Files: `Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 7.8 / 短句 8.0 / 物理 8.0 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.0）
- Debt picked: 列表、即将发送、回执、确认框还在用裸 system 字号。
- After: 总分 7.8（主动词 8.0 / 空气 8.2 / 短句 8.0 / 物理 8.0 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.5）
- Changed: 这一页字都走 workspace token。倒计时仍是等宽数字。护栏未改。
- Verified: `swift test --filter ApprovalWorkspaceTests --filter AutopilotCopyConsistencyTests --filter AutopilotStartReceiptTests` 32 个用例全绿；`swift build -c release`。走查：队列行、即将发送、回执、确认框字号与工作台一致。
- Next: 连续两刀提升都小于 0.3，换到 自动回复设置。待确认回复未到 8.5，巡检时再收「立即发送」并排。

## Cycle 18 — 2026-09-13 — 待确认回复

- Surface: 待确认回复
- Files: `Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.5（主动词 8.0 / 空气 6.8 / 短句 8.0 / 物理 7.5 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.0）
- Debt picked: 「查看聊天记录」无按下；详情区字号是裸数字。
- After: 总分 7.7（主动词 8.0 / 空气 7.8 / 短句 8.0 / 物理 8.0 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.0）
- Changed: 「查看聊天记录」按下会缩放。详情字走 workspace token。护栏未改。
- Verified: `swift test --filter ApprovalWorkspaceTests --filter AutopilotCopyConsistencyTests --filter AutopilotStartReceiptTests` 31 个用例全绿；`swift build -c release`。走查：点查看聊天记录缩放 → 打开对话；回复区字号与工作台一致。
- Next: 待确认回复第五刀 — 列表、即将发送、回执收回 token。总分未过 8.0。

## Cycle 17 — 2026-09-13 — 待确认回复

- Surface: 待确认回复
- Files: `Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.2（主动词 8.0 / 空气 6.8 / 短句 8.0 / 物理 6.0 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.0）
- Debt picked: 队列行用 .plain，按下没有让步。
- After: 总分 7.5（主动词 8.0 / 空气 6.8 / 短句 8.0 / 物理 7.5 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.0）
- Changed: 点左侧一条草稿，行会缩放。选中仍是青玉洗。护栏未改。
- Verified: `swift test --filter ApprovalWorkspaceTests --filter AutopilotCopyConsistencyTests --filter AutopilotStartReceiptTests` 30 个用例全绿；`swift build -c release`。走查：按下队列行缩放 → 松开右侧出现回复。
- Next: 待确认回复第四刀 — 「查看聊天记录」补按下，并把详情裸字号收回 token。总分未过 8.0。

## Cycle 16 — 2026-09-13 — 待确认回复

- Surface: 待确认回复
- Files: `Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 6.2 / 短句 6.2 / 物理 6.0 / 状态戏 7.5 / 稀疏 6.5 / 回执 7.0）
- Debt picked: 编辑区标题是「拟回复」，旁边还挂着「AI 草稿」徽章。
- After: 总分 7.2（主动词 8.0 / 空气 6.8 / 短句 8.0 / 物理 6.0 / 状态戏 7.5 / 稀疏 7.0 / 回执 7.0）
- Changed: 这一栏只叫「回复」。没有星星，也不再声明这是 AI。护栏未改。
- Verified: `swift test --filter ApprovalWorkspaceTests --filter AutopilotCopyConsistencyTests --filter AutopilotStartReceiptTests` 29 个用例全绿；`swift build -c release`。走查：点一条草稿 → 看到「回复」和正文 → 青玉确认发送。
- Next: 待确认回复第三刀 — 列表行补按下；总分未过 8.0。

## Cycle 15 — 2026-09-13 — 待确认回复

- Surface: 待确认回复
- Files: `Sources/WeChatHUD/Views/ApprovalWorkspaceView.swift`、`Tests/WeChatHUDTests/ApprovalWorkspaceTests.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 5.9（主动词 5.0 / 空气 5.5 / 短句 5.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Debt picked: 页头是仪表盘（筛选 + 开始整理 + 自动发送），详情里确认/保存/取消一样重。
- After: 总分 6.8（主动词 8.0 / 空气 6.2 / 短句 6.2 / 物理 6.0 / 状态戏 7.5 / 稀疏 6.5 / 回执 7.0）
- Changed: 空着时只看到「开始整理」。有草稿时页头只剩一句现状，确认发送是青玉主按钮，保存和取消安静。护栏未改。
- Verified: `swift test --filter ApprovalWorkspaceTests --filter AutopilotCopyConsistencyTests --filter AutopilotStartReceiptTests` 28 个用例全绿；`swift build -c release`。走查：空页 → 青玉开始整理；有草稿 → 青玉确认发送 → 对话框再确认 → 回执。
- Next: 待确认回复第二刀 — 拿掉「拟回复 / AI 草稿」；总分未过 8.0，还要再来。

## Cycle 14 — 2026-09-13 — 岛·紧凑/peek

- Surface: 岛·紧凑/peek（刘海右翼齿轮在展开收件箱头里）
- Files: `Sources/WeChatHUD/Views/InboxView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.1（主动词 8.0 / 空气 8.2 / 短句 8.2 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.0）
- Debt picked: 切口带齿轮只靠 tooltip 说「打开 WeChatHUD」，看不见字。
- After: 总分 8.2（主动词 8.2 / 空气 8.2 / 短句 8.4 / 物理 8.2 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.0）
- Changed: 齿轮旁边写「设置」，帮助是「打开设置」。按下会缩放。切口高度和弹簧未动。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter InboxViewLogicTests --filter CompanionProductCopyTests --filter IslandPeekTests --filter CompactErrorAffordanceTests` 58 个用例全绿；`swift build -c release`。走查：展开收件箱 → 右翼看到「设置」→ 按下缩放 → 松开打开工作台。
- Next: 连续两刀同一表面提升都小于 0.3，换到 待确认回复。peek 口述「移入查看」留给巡检。

## Cycle 13 — 2026-09-13 — 岛·紧凑/peek

- Surface: 岛·紧凑/peek
- Files: `Sources/WeChatHUD/Data/CompactIslandPolicy.swift`、`Tests/WeChatHUDTests/CompactIslandPolicyTests.swift`
- Before: 总分 8.0（主动词 8.0 / 空气 8.2 / 短句 7.5 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 7.5）
- Debt picked: 口述仍说「AI 正在整理」，和瞥见「整理中」不是同一句话。
- After: 总分 8.1（主动词 8.0 / 空气 8.2 / 短句 8.2 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.0）
- Changed: VoiceOver / 帮助改成「正在整理。移入查看。」瞥见仍是「整理中」。弹簧和 peek 宽度未动。
- Verified: `swift test --filter CompactIslandPolicyTests --filter CompactErrorAffordanceTests --filter AutopilotCopyConsistencyTests --filter IslandPeekTests --filter PixelBuddyTests` 59 个用例全绿；`swift build -c release`。走查：整理中时口述不再提 AI；左翼帮助跟口述走；悬停 peek 只加宽。
- Next: 岛·紧凑/peek 第三刀 — 刘海齿轮仍无字；不要动弹簧。这一刀只 +0.1，未过连续两刀 <0.3 的换表面线。

## Cycle 12 — 2026-09-13 — 岛·紧凑/peek

- Surface: 岛·紧凑/peek
- Files: `Sources/WeChatHUD/Views/CompactInboxBar.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 6.5 / 短句 7.5 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 7.5）
- Debt picked: 左翼圆点用系统红黄蓝，数字还是裸 11pt。
- After: 总分 8.0（主动词 8.0 / 空气 8.2 / 短句 7.5 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 7.5）
- Changed: 紧急是岛上的红/琥珀，整理仍是薄荷。数字走 islandMeta。弹簧和 peek 宽度未动。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter CompactErrorAffordanceTests --filter CompactIslandPolicyTests --filter IslandPeekTests --filter PixelBuddyTests` 等 84 个用例全绿；`swift build -c release`。走查：悬停 peek 只加宽；按下左翼仍打开收件箱；连不上仍是琥珀感叹号。
- Next: 岛·紧凑/peek 第二刀 — 口述「AI 正在整理」改成人话；不要动弹簧

## Cycle 11 — 2026-09-13 — 岛·通知横幅

- Surface: 岛·通知横幅
- Files: `Sources/WeChatHUD/Views/InboxRowView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.3（主动词 8.2 / 空气 8.3 / 短句 8.1 / 物理 8.5 / 状态戏 8.0 / 稀疏 8.4 / 回执 8.0）
- Debt picked: 稍后菜单每一行是 .plain，按下没有让步。
- After: 总分 8.4（主动词 8.2 / 空气 8.3 / 短句 8.1 / 物理 8.7 / 状态戏 8.0 / 稀疏 8.4 / 回执 8.0）
- Changed: 点「30 分钟后 / 1 小时后 / 明天上午」时行会缩放。弹簧和测量未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter NotificationBannerLayoutTests --filter NotificationBannerClickTests --filter BannerSnoozeFailureTests` 等 64 个用例全绿；`swift build -c release`。走查：稍后 → 按下时间行缩放 → 松开出回执。
- Next: 连续两刀同一表面提升都小于 0.3，换到 岛·紧凑/peek。横幅稍后/关闭仍无字，留给巡检。

## Cycle 10 — 2026-09-13 — 岛·通知横幅

- Surface: 岛·通知横幅
- Files: `Sources/WeChatHUD/Views/NotificationBannerView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.2（主动词 8.2 / 空气 8.3 / 短句 8.1 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.4 / 回执 8.0）
- Debt picked: 点消息打开前后文，按下时卡片没有让步。
- After: 总分 8.3（主动词 8.2 / 空气 8.3 / 短句 8.1 / 物理 8.5 / 状态戏 8.0 / 稀疏 8.4 / 回执 8.0）
- Changed: 按下消息，字略缩、洗层加深。稍后和关闭的点击槽不跟着动，避免点偏。弹簧和测量未改。
- Verified: `swift test --filter NotificationBannerClickTests --filter NotificationBannerLayoutTests --filter AutopilotCopyConsistencyTests` 等 77 个用例全绿；`swift build -c release`。走查：悬停洗层 → 按下消息缩放 → 松开打开简报；点关闭仍只关闭。
- Next: 岛·通知横幅第四刀 — 稍后菜单每一行补按下；不要动弹簧

## Cycle 9 — 2026-09-13 — 岛·通知横幅

- Surface: 岛·通知横幅
- Files: `Sources/WeChatHUD/Views/GroupContextBriefingButton.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.8（主动词 8.2 / 空气 6.5 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.2 / 回执 8.0）
- Debt picked: 简报把「在聊 / 为什么找你 / 下一步 / 原文」各自装进圆角方块，卡片套卡片。
- After: 总分 8.2（主动词 8.2 / 空气 8.3 / 短句 8.1 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.4 / 回执 8.0）
- Changed: 点开后先看到为什么找你这一句。在聊和下一步是安静行。原文不再套一层底。高度仍走测量（展开从约 473 收到 329），弹簧未动。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter BriefingRetryTests --filter NotificationBanner*` 等 79 个用例全绿；`swift build -c release`。走查：点消息 → 一句原因 + 安静行 + 青玉去微信；无套卡。
- Next: 岛·通知横幅第三刀 — 收起横幅按下要有缩放，不要动弹簧和测量

## Cycle 8 — 2026-09-13 — 岛·通知横幅

- Surface: 岛·通知横幅
- Files: `Sources/WeChatHUD/Views/GroupContextBriefingButton.swift`、`Sources/WeChatHUD/Views/NotificationBannerView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`、`Tests/WeChatHUDTests/BriefingRetryTests.swift`
- Before: 总分 7.2（主动词 6.5 / 空气 6.5 / 短句 6.5 / 物理 7.5 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.0）
- Debt picked: 点开横幅后，「去微信回复」和「稍后提醒」一样宽；标题还写「AI 解读」。
- After: 总分 7.8（主动词 8.2 / 空气 6.5 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.2 / 回执 8.0）
- Changed: 简报标题改成「为什么找你」，不再提 AI。主按钮是一条青玉「去微信回复」；稍后收成旁边的安静胶囊。失败是「再试一次」。高度仍走测量，弹簧未动。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter BriefingRetryTests --filter NotificationBanner*` 等 78 个用例全绿（含点击与 hug）；`swift build -c release`。走查：点消息 → 为什么找你；按下青玉去微信；稍后不抢主位；失败 → 再试一次。
- Next: 岛·通知横幅第二刀 — 拿掉简报里三张套卡，改成岛上的安静行；收起横幅的按下缩放另算一刀

## Cycle 7 — 2026-09-13 — 岛·展开收件箱

- Surface: 岛·展开收件箱
- Files: `Sources/WeChatHUD/Views/ActionPanelView.swift`、`Sources/WeChatHUD/Data/InboxItem.swift`、`Sources/WeChatHUD/Views/InboxRowView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.4（主动词 8.3 / 空气 8.3 / 短句 8.3 / 物理 8.4 / 状态戏 7.6 / 稀疏 8.0 / 回执 8.0）
- Debt picked: 展开区仍说「分析暂不可用 / AI 正在整理重点」，失败还把内部错误摊在用户眼前。
- After: 总分 8.5（主动词 8.3 / 空气 8.3 / 短句 8.6 / 物理 8.4 / 状态戏 8.2 / 稀疏 8.0 / 回执 8.2）
- Changed: 整理中改成「正在整理这条消息…」。失败改成「先看原文」加一句去向，不再出现「分析」。失败可「再试一次」；回复建议同样说人话。内部超时文案不再上屏。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter IslandStyleTests --filter CompanionProductCopyTests --filter CompanionMotionTests` 39 个用例全绿；`swift build -c release`。走查：展开等待中 → 正在整理这条消息；失败 → 先看原文 + 再试一次；主按钮仍是打开微信。
- Next: 岛·通知横幅。刘海齿轮仍无字，不要在横幅那一刀顺手改弹簧。

## Cycle 6 — 2026-09-13 — 岛·展开收件箱

- Surface: 岛·展开收件箱
- Files: `Sources/WeChatHUD/Views/InboxView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.2（主动词 8.2 / 空气 8.3 / 短句 7.5 / 物理 8.3 / 状态戏 7.5 / 稀疏 8.0 / 回执 7.8）
- Debt picked: 底栏只有图标；溢出行写「查看全部（新窗口）」，用户不知道会去哪。
- After: 总分 8.4（主动词 8.3 / 空气 8.3 / 短句 8.3 / 物理 8.4 / 状态戏 7.6 / 稀疏 8.0 / 回执 8.0）
- Changed: 溢出改成「还有 N 条，打开今天查看」，并真的打开今天。底栏写「待办」「今天」，按下有缩放。刘海齿轮这一刀没动，避免撑高切口带。
- Verified: `swift test --filter AutopilotCopyConsistencyTests --filter IslandStyleTests --filter CompanionProductCopyTests --filter CompanionMotionTests` 38 个用例全绿；`swift build -c release`。走查：溢出行 → 今天；底栏待办 → 岛上待办面；底栏今天 → 工作台今天。
- Next: 岛·展开收件箱第四刀 — 展开区「分析暂不可用 / AI 正在整理重点」改成人话；齿轮仍留给下一刀，不要动弹簧

## Cycle 5 — 2026-09-13 — 岛·展开收件箱

- Surface: 岛·展开收件箱
- Files: `Sources/WeChatHUD/Views/ActionPanelView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.7（主动词 8.2 / 空气 7.5 / 短句 7.5 / 物理 8.2 / 状态戏 7 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 解读卡是系统强调色方块，还套了一层边框。
- After: 总分 8.2（主动词 8.2 / 空气 8.3 / 短句 7.5 / 物理 8.3 / 状态戏 7.5 / 稀疏 8.0 / 回执 7.8）
- Changed: 展开一行后，重点不再装在彩色卡片里。标题用岛上的薄荷色，等你才用琥珀。建议行按下有缩放；失败重试是薄荷色，不是系统红和系统蓝。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 等 35 个用例全绿；`swift build -c release`。走查：展开 → 一句重点 + 青玉主按钮；失败 → 重试。
- Next: 岛·展开收件箱第三刀 — 底栏图标补人话；「查看全部（新窗口）」改成用户能懂的去向

## Cycle 4 — 2026-09-13 — 岛·展开收件箱

- Surface: 岛·展开收件箱
- Files: `Sources/WeChatHUD/Views/ActionPanelView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.9（主动词 6 / 空气 7 / 短句 7.5 / 物理 7.5 / 状态戏 7 / 稀疏 7 / 回执 7.5）
- Debt picked: 展开一行后两个按钮一样宽，主按钮还是系统强调色，不是青玉胶囊。
- After: 总分 7.7（主动词 8.2 / 空气 7.5 / 短句 7.5 / 物理 8.2 / 状态戏 7 / 稀疏 7.5 / 回执 7.5）
- Changed: 点开一行，先看到一条青玉「打开微信回复」；「回复建议」收成旁边的安静胶囊，按下有缩放。悬停时钟/关闭未动，从行移到展开区仍不收起。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 等 60 个用例全绿（含 IslandInteractionTests）；`swift build -c release`。走查：悬停行 → 次动作；按下展开 → 青玉主按钮；再按回复建议。
- Next: 岛·展开收件箱第二刀 — 解读卡去掉系统 accent 方块，改走 IslandInk / CompanionPalette.jade

## Cycle 3 — 2026-09-13 — 今天

- Surface: 今天
- Files: `Sources/WeChatHUD/Views/AssistantTodayView.swift`、`Tests/WeChatHUDTests/ProductWorkspaceTests.swift`
- Before: 总分 8.3（主动词 8.8 / 空气 8.2 / 短句 8.5 / 物理 8.0 / 状态戏 7 / 稀疏 7 / 回执 7.5）
- Debt picked: 连接正常时右侧仍摊开状态卡和两个按钮，和主列表抢。
- After: 总分 8.5（主动词 8.8 / 空气 8.4 / 短句 8.5 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.6 / 回执 7.5）
- Changed: 微信正常时右侧不再出现连接卡。没有答应的事时「接下来」整块消失。异常时只留一个主按钮：过期同步是「查看新消息」，其它是「检查连接」。字号收回 token。
- Verified: `swift test --filter ProductWorkspaceTests` 等 60 个用例全绿；`swift build -c release`。走查：正常打开今天 → 只有待回列表和小结入口；断开微信 → 右侧出现一句状态和一个检查连接；过期同步 → 查看新消息。
- Next: 岛·展开收件箱

## Cycle 2 — 2026-09-13 — 今天

- Surface: 今天
- Files: `Sources/WeChatHUD/Views/AssistantTodayView.swift`、`Tests/WeChatHUDTests/ProductWorkspaceTests.swift`
- Before: 总分 8.0（主动词 8.5 / 空气 7 / 短句 8.5 / 物理 6.5 / 状态戏 7 / 稀疏 7 / 回执 7.5）
- Debt picked: 消息卡裸字号、无悬停、展开后两个同等按钮。
- After: 总分 8.3（主动词 8.8 / 空气 8.2 / 短句 8.5 / 物理 8.0 / 状态戏 7 / 稀疏 7 / 回执 7.5）
- Changed: 鼠标移到一条待回上，卡片轻轻洗一层；按下标题有缩放。展开后只有「理解上下文与回复」是青玉主按钮，「已处理」收成安静文字。字号走工作台 token，不再 14/16 混用。
- Verified: `swift test --filter ProductWorkspaceTests` 等 60 个用例全绿；`swift build -c release`。走查：悬停（打开后约 0.22 秒才启用，避免指针压在第一张上就亮）→ 按下标题展开 → 主按钮进详情；已处理出撤销条。
- Next: 今天第三刀 — 右侧栏收回 token；连接卡只在异常时出现，日常不要两个按钮和主列表抢。

## Cycle 1 — 2026-09-13 — 今天

- Surface: 今天
- Files: `Sources/WeChatHUD/Views/AssistantTodayView.swift`、`Tests/WeChatHUDTests/ProductWorkspaceTests.swift`
- Before: 总分 6.1（主动词 5.5 / 空气 6 / 短句 6.5 / 物理 5.5 / 状态戏 7 / 稀疏 5 / 回执 7）
- Debt picked: 三个同等胶囊加「先处理这些事」让人找不到下一步；改成一句现状，下面只留一条需要回复的列表。
- After: 总分 8.0（主动词 8.5 / 空气 7 / 短句 8.5 / 物理 6.5 / 状态戏 7 / 稀疏 7 / 回执 7.5）
- Changed: 打开今天先看到「现在有 N 件需要回复」。我要做 / 等对方变成安静跳转；没有普通更新时不再出现「全部」。点已处理后，句子和列表一起收。
- Verified: `swift test --filter ProductWorkspaceTests`；`swift test --filter CompanionMotionTests`；`swift test --filter CompanionProductCopyTests`；`swift test --filter IslandStyleTests`；`swift build -c release`。走查：悬停次级跳转有按压缩放；按下「理解上下文与回复」进详情；点已处理出撤销；空列表时状态句仍是「现在没有要回的」，空态说明待办在侧。
- Next: 今天第二刀 — 把消息卡和右侧栏收回 `workspace*` token，补行悬停洗层，让「理解上下文与回复」是卡上唯一强调按钮。
