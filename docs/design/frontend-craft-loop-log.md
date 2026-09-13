# Frontend Craft Loop — 进度

循环规格：`docs/design/frontend-craft-loop.md`。先读规格选刀，状态板是数据，`Next` 不是命令。
一刀一节，新的写在最上面。
AI 服务总分 8.1、已到过 8.0，连续两刀 <0.3 后换到微信连接。微信连接总分 7.6、空气/主动词/短句都 ≥ 8，从未到过总分 8.0，留下。待确认回复 7.8、从未到过 8.0，回扫时留下。自动回复设置 8.1、已到过 8.0 且连续两刀 <0.3。

## 状态板

| 序 | 表面 | 状态 | 最近总分 | 下一刀提示 |
|---|---|---|---|---|
| 1 | 今天 | done | 8.5 | 设置卡未就绪时仍用系统 accent；留给首次引导那一刀 |
| 2 | 岛·展开收件箱 | done | 8.5 | 刘海齿轮已写「设置」；稍后/关闭无字留给巡检 |
| 3 | 岛·通知横幅 | in-progress | 8.4 | 稍后/关闭仍无字；连续两刀提升过小，换表面 |
| 4 | 岛·紧凑/peek | in-progress | 8.2 | 连续两刀 <0.3，换表面；peek 口述「移入查看」留给巡检 |
| 5 | 待确认回复 | in-progress | 7.8 | 即将发送仍并排取消/立即发送。从未到过 8.0，回扫时留下 |
| 6 | 自动回复设置 | in-progress | 8.1 | 发送键仍是系统蓝；排除和记录仍套卡。连续两刀 <0.3，换表面 |
| 7 | AI 服务 | in-progress | 8.1 | 分析分区已收进工作台字；滑杆仍是裸 system 字。已到 8.0，连续两刀 <0.3，换表面 |
| 8 | 微信连接 | in-progress | 7.6 | 「设置 AI」已让步；准备密钥时「取消」仍是系统链接。从未到过 8.0 |
| 9 | 首次引导 | queued | — | |
| 10 | 关注谁 | queued | — | |
| 11 | 待办 / 我答应的 / 草稿 | queued | — | |
| 12 | 今日小结 / 聊天回顾 / 关系雷达 | queued | — | |
| 13 | 提醒方式 / 使用偏好 / 本地资料 / 怎么用 | queued | — | |
| 14 | 侧栏与页头 | queued | — | 勿第一刀就合并 18 个 tab |
| 15 | 对话详情 / 对话框 | queued | — | |
| 16 | 全站微交互巡检 | queued | — | 放在多数页面主动词成立之后 |

## Cycle 53 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Debt picked: 高级里「设置 AI」是青玉系统链接，和「去选对话」抢按压。
- After: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Changed: 「设置 AI」是安静可按的次级，按下缩回并去 AI 服务。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 52 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」仍是青玉 → 打开「高级连接设置」→ 按下「设置 AI」缩回并切到 AI 服务。
- Next: 微信连接还要再来：主动词/空气/短句都 ≥ 8，圈状态戏——准备密钥时「取消」仍是系统链接。总分未到 8.0，不换表面。

## Cycle 52 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 7.0 / 回执 6.0）
- Debt picked: 保存失败是连接卡上方的红字「重试保存设置」。
- After: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Changed: 没存上时，连接卡下面出现「刚才没存上。」和「再试一次」。按下缩回并重试保存。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 51 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」→ 卡上没有红字「重试保存设置」→ 失败回执若出现，是「刚才没存上。」和「再试一次」。
- Next: 微信连接还要再来：主动词/空气/短句都 ≥ 8，圈物理——高级里「设置 AI」仍是系统链接。总分未到 8.0，不换表面。

## Cycle 51 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 展开「高级连接设置」直接铺开轮询间隔和诊断墙。
- After: 总分 7.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 7.0 / 回执 6.0）
- Changed: 打开「高级连接设置」先看到「读取聊天」和「设置 AI」。轮询间隔和诊断在「库路径与同步」里。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 50 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」→ 打开「高级连接设置」→ 看到「读取聊天」，没有「轮询间隔」→ 打开「库路径与同步」→ 看到「轮询间隔」。
- Next: 微信连接还要再来：主动词/空气/短句都 ≥ 8，圈回执——保存失败仍是红字「重试保存设置」。总分未到 8.0，不换表面。

## Cycle 50 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 确认框里「先不换」是系统按钮，按下没有缩回。
- After: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Changed: 「先不换」是安静可按的次级，按下缩回。青玉仍只在「继续更换」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 49 个用例全绿；`swift build -c release`。走查：开微信连接 → 按下「更换微信账号」→ 看到「先不换」按下缩回、框关掉 → 「继续更换」仍是青玉。
- Next: 微信连接还要再来：主动词/空气/短句都 ≥ 8，圈稀疏——高级连接设置展开仍是轮询间隔和诊断墙。总分未到 8.0，不换表面。

## Cycle 49 — 2026-09-13 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 连接卡标题是 title3，和「去选对话」不在同一块工作台字上。
- After: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Changed: 「微信已连接」和下一步说明是工作台标题和正文。检查项、上次同步、出错提示跟同一套字。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 48 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「微信已连接」和「下一步：选择要整理的对话。」是工作台字 → 「去选对话」仍是青玉 → 「只读取聊天，不改微信里的内容。」仍在卡上。
- Next: 微信连接还要再来：主动词/空气/短句都 ≥ 8，圈物理——确认框里「先不换」还是系统按钮。总分未到 8.0，不换表面。

## Cycle 48 — 2026-09-13 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.6（主动词 7.0 / 空气 7.5 / 短句 8.0 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 「更换微信账号」是系统链接，和「去选对话」抢视线。
- After: 总分 6.8（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Changed: 「更换微信账号」是安静可按的次级，按下缩回。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 47 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」仍是青玉 → 按下「更换微信账号」缩回并弹出确认 → 「检查更新」同样让步。
- Next: 微信连接还要再来：连接卡标题仍是 title3；确认框里「先不换」还是系统按钮。总分未到 8.0，不换表面。

## Cycle 47 — 2026-09-13 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.3（主动词 7.0 / 空气 7.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 连接卡上一直挂着「更换账号」长说明，还在说 AI 分析。
- After: 总分 6.6（主动词 7.0 / 空气 7.5 / 短句 8.0 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Changed: 卡上只留「只读取聊天，不改微信里的内容。」换号的范围在点「更换微信账号」之后才说。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 46 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」和「只读取聊天，不改微信里的内容。」→ 没有更换账号长说明 → 按下「更换微信账号」→ 框里仍是按账号分开。
- Next: 微信连接还要再来：「更换微信账号」仍是系统链接；高级里仍是轮询间隔。总分未到 8.0，不换表面。

## Cycle 46 — 2026-09-13 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.0（主动词 7.0 / 空气 5.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 「去选对话」下面还有一张「读取聊天 / 设置 AI」卡，同一屏两块底板。
- After: 总分 6.3（主动词 7.0 / 空气 7.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Changed: 打开页只剩连接卡和「高级连接设置」。读取聊天、设置 AI 进高级，不再压在「去选对话」下面。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 45 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」→ 下面没有「读取聊天」「设置 AI」→ 打开「高级连接设置」→ 看到「读取聊天」和「设置 AI」。
- Next: 微信连接还要再来：连接卡上仍有「更换账号」长说明；高级里仍是接口字。总分未到 8.0，不换表面。

## Cycle 45 — 2026-09-13 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 5.6（主动词 5.0 / 空气 5.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Debt picked: 已连接时写着「下一步：选择要整理的对话」，主按钮却是「检查更新」。
- After: 总分 6.0（主动词 7.0 / 空气 5.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 5.0 / 回执 6.0）
- Changed: 设置里连上之后，青玉主按钮是「去选对话」，打开「关注谁」。「检查更新」退成安静次级。首次引导仍用「检查更新」做连接复查。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 44 个用例全绿；`swift build -c release`。走查：开微信连接 → 已连接时看到「微信已连接」和「去选对话」→ 按下进入「关注谁」→ 「检查更新」按下缩回并复查 → 首次引导页仍是「检查更新」。
- Next: 微信连接还要再来：读取聊天 / 设置 AI 仍和「去选对话」抢下一步。总分未到 8.0，不换表面。

## Cycle 44 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.0）
- Debt picked: 分析分区仍是裸 system 字，「去 AI 服务配置」是系统小边框按钮。
- After: 总分 8.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.6 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.0）
- Changed: 「分析与建议」用工作台字。「去 AI 服务配置」是安静可按的次级，按下缩回，不是第二颗青玉。「你始终可以查看原文」和「随 AI 服务」同一套尺子。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 43 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」仍是青玉 → 切到「分析与建议」→ 按下「去 AI 服务配置」缩回并回到服务 → 「你始终可以查看原文」和「随 AI 服务」不再是系统字。
- Next: 连续两刀升幅都 < 0.3，且本页已到过 8.0。换到微信连接。本页保持 in-progress：高级设置里滑杆数字仍是裸 system 字。

## Cycle 43 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 6.7 / 回执 8.0）
- Debt picked: 选 ChatGPT 时，「不必再填密钥」在「接到哪」里说过，下面又垫了一块 system 字。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.0）
- Changed: 选 ChatGPT 只在「接到哪」看到「用这台 Mac 上已登录的 ChatGPT，不必再填密钥。」下面不再重复一块。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 42 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」→ 选 ChatGPT → 「接到哪」是「用这台 Mac 上已登录的 ChatGPT，不必再填密钥。」→ 下面没有第二块同样的话。
- Next: AI 服务还要再来：高级设置里滑杆数字仍是裸 system 字；分析分区仍是裸 system 字。总分已到 8.0，未到 8.5，不换表面。

## Cycle 42 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 6.7 / 稀疏 6.7 / 回执 8.0）
- Debt picked: 按下「确认能用」时清空结果，卡上会露出「已保存」。
- After: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 6.7 / 回执 8.0）
- Changed: 确认进行中，卡上改说「正在确认…」，不再露出「已保存」。结束后仍是「刚才确认过了」或失败句。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 41 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 按下「确认能用」→ 卡上是「正在确认…」不是「已保存」→ 结束后「刚才确认过了」或「这次没连上。」→ 「再试一次」仍再确认。
- Next: AI 服务还要再来：选 ChatGPT 时说明仍是裸 system 字；高级设置里滑杆数字同样。总分未到 8.0，不换表面。

## Cycle 41 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 6.7 / 稀疏 6.7 / 回执 6.6）
- Debt picked: 点「确认能用」失败后，卡上仍可能出现 HTTP、接口、API Key。
- After: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 6.7 / 稀疏 6.7 / 回执 8.0）
- Changed: 确认失败改说「这次没连上。」「这会儿忙，过会儿再试。」或「请核对地址、模型和密钥，再点「确认能用」」。「再试一次」仍是再确认。校验串未改。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 40 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 按下「确认能用」→ 失败时卡上是「这次没连上。」或「请核对地址、模型和密钥，再点「确认能用」」→ 按下「再试一次」缩回并再测 → 没有 HTTP、API Key、接口。
- Next: AI 服务还要再来：按下「确认能用」时卡上仍可能露出「已保存」；高级设置里滑杆数字仍是裸 system 字。总分未到 8.0，不换表面。

## Cycle 40 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.7 / 状态戏 6.7 / 稀疏 6.7 / 回执 6.6）
- Debt picked: 自己填时「接到哪」藏在「高级连接设置」里，还用裸 system 字。
- After: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 6.7 / 稀疏 6.7 / 回执 6.6）
- Changed: 选「自己填」直接看到「接到哪」，不必再打开「高级连接设置」。未加密警告用工作台元数据。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 39 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」→ 选「自己填」→ 直接看到「接到哪」→ 没有「高级连接设置」→ HTTP 警告跟在地址下面。
- Next: AI 服务还要再来：确认失败仍可能带上校验串里的 HTTP；高级设置里滑杆数字仍是裸 system 字。总分未到 8.0，不换表面。

## Cycle 39 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 6.7 / 回执 6.6）
- Debt picked: 「去拿密钥」是系统 mini 边框按钮，按下不让步，和「确认能用」不是一套手感。
- After: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.7 / 状态戏 6.7 / 稀疏 6.7 / 回执 6.6）
- Changed: 「去拿密钥」是安静可按的工作台次级，按下缩回，不是系统小按钮。刷新模型同样让步。青玉仍只在「确认能用」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 38 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」仍是青玉 → 按下「去拿密钥」缩回 → 按下模型旁刷新缩回，不是系统边框。
- Next: AI 服务还要再来：自己填时「高级连接设置」和滑杆数字仍是裸 system 字。总分未到 8.0，不换表面。

## Cycle 38 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.6）
- Debt picked: 打开页就能看到写作习惯和数据与隐私两行披露，日常决定被铺开。
- After: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 6.7 / 回执 6.6）
- Changed: 首屏只留用哪家、哪一家、密钥、用哪个模型。写作习惯和数据与隐私收进同一张卡上的「高级设置」，默认收起。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 37 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」→ 表单是「用哪家」到「用哪个模型」→ 底部一行「高级设置」→ 打开后看到「慢慢想清楚再答」和「数据与隐私」，还在这一张卡里。
- Next: AI 服务还要再来：去拿密钥仍是系统小按钮。总分未到 8.0，不换表面。

## Cycle 37 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.7（主动词 7.4 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.4）
- Debt picked: 页头是「确认能用」，页底又写「已保存。还没点「确认能用」」，两处都在说下一步。
- After: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.6）
- Changed: 保存和确认回执都在「确认能用」同一张卡上。闲时不说话。存上了只写「已保存」，不再催你去点确认。没存上时「再试一次」仍是再存。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 37 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 页底没有「还没点「确认能用」」→ 按下「确认能用」→ 「刚才确认过了」出现在同一张卡 → 改一行后看到「已保存」仍在这张卡上，不是第二处说话。
- Next: AI 服务还要再来：去拿密钥仍是系统小按钮；表单仍从用哪家铺到写作习惯。总分未到 8.0，不换表面。

## Cycle 36 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.6（主动词 7.4 / 空气 7.8 / 短句 7.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.2）
- Debt picked: 确认结果还说「连接成功」，页底是「重试保存 / 连接已验证」，隐私里仍是「访问凭据」。
- After: 总分 6.7（主动词 7.4 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.4）
- Changed: 确认成功写「刚才确认过了」。页底改成「已保存。还没点「确认能用」」；没存上时「再试一次」再存，不是「重试保存」。隐私说密钥只留在这台电脑里。护栏未改。校验串里的 API Key 未动。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 37 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 按下「确认能用」→ 看到「刚才确认过了」或「再试一次」→ 页底「已保存。还没点「确认能用」」→ 没存上时按下「再试一次」缩回并再存 → 打开「数据与隐私」看到「密钥只留在这台电脑里」。
- Next: AI 服务还要再来：页头「确认能用」和页底「已保存」仍是两处说话；去拿密钥仍是系统小按钮。总分未到 8.0，不换表面。

## Cycle 35 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.4（主动词 7.4 / 空气 6.8 / 短句 7.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.2）
- Debt picked: 「写作习惯」和「数据与隐私」是披露外再套一层卡，同一屏三块底板。
- After: 总分 6.6（主动词 7.4 / 空气 7.8 / 短句 7.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.2）
- Changed: 「写作习惯」和「数据与隐私」收进和「用哪家」同一张卡，打开后仍在这层底上，不再套第二张卡。默认收起。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 36 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」→ 往下只有一张表单 → 底部「写作习惯」「数据与隐私」→ 打开「写作习惯」看到「慢慢想清楚再答」，还在这一张卡里。
- Next: AI 服务还要再来：页底「重试保存」和隐私里的「访问凭据」、校验串里的 API Key 仍是实现词。总分未到 8.0，不换表面。

## Cycle 34 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.2（主动词 6.7 / 空气 6.8 / 短句 7.0 / 物理 4.7 / 状态戏 6.5 / 稀疏 4.7 / 回执 6.0）
- Debt picked: 点「确认能用」之后，结果落在表单里的橙色「连接没有通过」，刷新模型还占用同一块回执。
- After: 总分 6.4（主动词 7.4 / 空气 6.8 / 短句 7.0 / 物理 4.7 / 状态戏 6.7 / 稀疏 4.7 / 回执 6.2）
- Changed: 确认结果出现在「确认能用」同一张状态卡上。失败时「再试一次」是安静可按的退路，再跑刚才那次确认，不是第二颗青玉。刷新模型的说明只在模型行下。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 35 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 按下「确认能用」→ 回执出现在同一张卡 → 失败时按下「再试一次」缩回并再测 → 表单里没有橙色「连接没有通过」→ 刷新模型只在「用哪个模型」下面说话。
- Next: AI 服务还要再来：写作习惯和数据与隐私仍是套在披露外的第二层卡。页底「重试保存」还在抢回执。总分未到 8.0，不换表面。

## Cycle 33 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 5.9（主动词 6.7 / 空气 6.8 / 短句 5.2 / 物理 4.7 / 状态戏 6.5 / 稀疏 4.7 / 回执 6.0）
- Debt picked: 页头已经说「可以用 / 确认能用」，表单仍是 API 控制台：服务来源、供应商、访问凭据、获取 API Key。
- After: 总分 6.2（主动词 6.7 / 空气 6.8 / 短句 7.0 / 物理 4.7 / 状态戏 6.5 / 稀疏 4.7 / 回执 6.0）
- Changed: 同一张卡改成「用哪家」：常用服务 / 自己填。行是「哪一家」「接到哪」「密钥」「用哪个模型」。旁路是「去拿密钥」。没选模型时页头写「还没选模型」。失败句指向再点「确认能用」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 34 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」→ 往下「用哪家」是常用服务 / 自己填 → 「哪一家」「密钥」和「去拿密钥」→ 没模型时「还没选模型」→ 失败时「请核对地址、模型和密钥，再点「确认能用」」。
- Next: AI 服务还要再来：失败块和刷新模型仍不像「确认能用」。写作习惯、高级连接设置、校验串里的 API Key 还在。总分未到 8.0，不换表面。

## Cycle 32 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 5.6（主动词 6.5 / 空气 5.0 / 短句 5.2 / 物理 4.7 / 状态戏 6.5 / 稀疏 4.5 / 回执 6.0）
- Debt picked: 服务来源和供应商各占一张卡，表单里的「状态」还和页头抢「能不能用」。
- After: 总分 5.9（主动词 6.7 / 空气 6.8 / 短句 5.2 / 物理 4.7 / 状态戏 6.5 / 稀疏 4.7 / 回执 6.0）
- Changed: 「服务来源」和供应商、模型在同一张卡上。页头仍是「确认能用」；表单不再重复「已启用 · 已验证」。预设供应商 / 自定义供应商还在。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 33 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「确认能用」→ 往下只有一张表单，先是「服务来源」再是供应商 → 切换预设/自定义，表单还是这一张卡。
- Next: AI 服务还要再来：写作习惯和数据与隐私仍是套在披露外的第二层卡。总分未到 8.0，不换表面。

## Cycle 31 — 2026-09-13 — AI 服务

- Surface: AI 服务
- Files: `Sources/WeChatHUD/Views/Settings/AISettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 5.1（主动词 4.5 / 空气 5.0 / 短句 5.0 / 物理 4.5 / 状态戏 6.5 / 稀疏 4.5 / 回执 6.0）
- Debt picked: 打开 AI 服务，第一颗按钮是「更换服务」，而这页已经是服务页；能不能用被表单和火花图标压住。
- After: 总分 5.6（主动词 6.5 / 空气 5.0 / 短句 5.2 / 物理 4.7 / 状态戏 6.5 / 稀疏 4.5 / 回执 6.0）
- Changed: 页头改说「可以用 / 还不能用 / 还没确认能不能用」。右边一颗青玉「确认能用」。表单里的「测试连接」改成安静可按。分析页「去 AI 服务配置」仍走真实 tab 切换。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 32 个用例全绿；`swift build -c release`。走查：开 AI 服务 → 看到「还没确认能不能用」或「可以用」→ 按下「确认能用」→ 测试中禁用 → 表单里「测试连接」按下缩回，不是第二颗青玉。
- Next: AI 服务还要再来：服务来源和供应商表单仍压过能不能用。总分未到 8.0，不换表面。

## Cycle 30 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.2 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.2）
- Debt picked: 展开「高级设置」后又套一张叫「高级」的卡。
- After: 总分 8.1（主动词 8.0 / 空气 8.2 / 短句 8.0 / 物理 8.2 / 状态戏 8.0 / 稀疏 8.3 / 回执 8.2）
- Changed: 打开高级设置，回复风格、哪些一定交给你、连发上限和发送键直接长在同一张卡上，不再先看到第二块「高级」。群聊那句用工作台正文。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 31 个用例全绿；`swift build -c release`。走查：开页 → 打开高级设置 → 先看到「回复风格」和「哪些一定交给你」，没有第二张「高级」标题 → 群聊说明仍是「不会自动发出」→ 发送键仍是系统蓝。
- Next: 连续两刀升幅都 < 0.3，且本页已到过 8.0。换到 AI 服务。本页保持 in-progress：发送键仍是系统蓝，排除和记录仍是套卡。

## Cycle 29 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.4 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.2）
- Debt picked: 展开高级设置后，排除名单和记录仍是裸系统字，去掉和清除按下没有让步。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.2 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.2）
- Changed: 「添加排除对象」能读全、能按。名单里的去掉是安静可按，不再是淡红圆点。「清除历史」同样让步。记录行用工作台字号和青玉，不再用绿/橙。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 30 个用例全绿；`swift build -c release`。走查：开页 → 打开高级设置 → 看到「添加排除对象」→ 按下缩回 → 名单空态「还没有添加」→ 有记录时按下「清除历史」缩回并弹出确认。
- Next: 自动回复设置还要再来：高级里仍套一张叫「高级」的卡，发送键还是系统蓝。总分已到 8.0，未到 8.5，不换表面。

## Cycle 28 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 8.0 / 稀疏 8.0 / 回执 7.5）
- Debt picked: 保存成功/失败是系统 callout；清记录失败时「重试保存设置」会去存配置，不是重做刚才那件事。
- After: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.4 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.2）
- Changed: 「设置已保存」用工作台元数据和青玉，跟页头同一口气。失败时「再试一次」是安静可按的退路：存配置失败就再存，清记录失败就再清。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 29 个用例全绿；`swift build -c release`。走查：开页 → 拖「多有把握才发出去」→ 看到「设置已保存」→ 打开高级设置 → 清记录走确认后，失败会留下「记录没清掉」和「再试一次」，按下是再清，不是去存开关。
- Next: 自动回复设置还要再来：展开高级设置后，排除名单和记录仍是裸系统字。总分未到 8.0，不换表面。

## Cycle 27 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 8.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 首屏挤着回复风格和「哪些一定交给你」，日常决定看不清。
- After: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 8.0 / 稀疏 8.0 / 回执 7.5）
- Changed: 打开页只剩自动发出去、群里 @我、多有把握才发出去、连发时等几秒一起回。回复风格和「哪些一定交给你」进高级设置。连发窗口仍在首屏；护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 28 个用例全绿；`swift build -c release`。走查：开页 → 看不到回复风格和「哪些一定交给你」→ 打开高级设置 → 看到两者仍可改 → 拖把握滑杆 → 设置已保存。
- Next: 自动回复设置还要再来：保存成功/失败仍用系统 callout 字号，不像这一页的回执。总分未到 8.0，不换表面。

## Cycle 26 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 开「自动发出去」的确认框仍像系统对话框：13pt 系统字、两颗默认按钮并排。
- After: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 8.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 「开启自动发送？」用工作台正文说话。「保持手动」是安静可按的退路；「允许发送」才是青玉主许可。护栏未改：关着才弹，允许后仍只改设置、不会马上发出去。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 27 个用例全绿；`swift build -c release`。走查：开页 → 打开自动发出去 → 看到「开启自动发送？」和「只修改设置，不会马上发出去」→ 按下「保持手动」缩回、开关仍关 → 再开 → 按下「允许发送」→ 设置已保存。
- Next: 自动回复设置还要再来：首屏仍挤着回复风格和「哪些一定交给你」，日常决定该只留开关、把握、连发窗口。总分未到 8.0，不换表面。

## Cycle 25 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 7.0 / 物理 7.0 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 「自动发送把握程度」读起来像字段名，副标题还在说门槛和约束。
- After: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 滑杆改叫「多有把握才发出去」。不到这个数只写草稿；群聊、转账、红包仍要你确认。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 26 个用例全绿；`swift build -c release`。走查：开页 → 自动发出去 → 看到「多有把握才发出去」和百分比 → 拖滑杆 → 设置已保存；开自动发出去仍弹确认。
- Next: 自动回复设置还要再来：开自动发出去的确认框仍像系统对话框。总分未到 8.0，不换表面。

## Cycle 24 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 页头「查看待确认回复」用 .plain，按下没有让步。
- After: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 7.0 / 物理 7.0 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 点「查看待确认回复」会缩放，仍是次级去处，不是青玉主按钮。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 26 个用例全绿；`swift build -c release`。走查：开页 → 按下「查看待确认回复」缩放 → 松开进待确认；开自动发出去仍弹确认。
- Next: 连续两刀提升都小于 0.3，换到 AI 服务。自动回复设置未到 8.5，回扫时再收确认框字号和按下。

## Cycle 23 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.2（主动词 8.0 / 空气 7.5 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 把握程度、哪些一定交给你用裸 system 字号和更窄的内边距，和其他行不是一套尺子。
- After: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 把握程度和「哪些一定交给你」与开关、连发同一行高、同一套字。百分比不再用青玉抢视线。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 26 个用例全绿；`swift build -c release`。走查：开页 → 自动发出去 → 拖把握滑杆，数字与其他行同号 → 「哪些一定交给你」与连发同一层；开自动发出去仍弹确认。
- Next: 自动回复设置第五刀 — 页头「查看待确认回复」仍无按下。总分未过 8.0。

## Cycle 22 — 2026-09-13 — 自动回复设置

- Surface: 自动回复设置
- Files: `Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 6.9（主动词 8.0 / 空气 5.5 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Debt picked: 连发窗口是卡片套卡片，同一层两个分组底。
- After: 总分 7.2（主动词 8.0 / 空气 7.5 / 短句 7.0 / 物理 5.5 / 状态戏 7.0 / 稀疏 7.5 / 回执 7.5）
- Changed: 「连发时等几秒一起回」和其他设置同一行高、同一层底。仍在首屏。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 25 个用例全绿；`swift build -c release`。走查：开页 → 自动发出去 → 连发是同一张卡里的一行，展开菜单改秒数 → 设置已保存；开自动发出去仍弹确认。
- Next: 自动回复设置第四刀 — 把握程度、哪些一定交给你仍用裸 system 字号。总分未过 8.0。

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
