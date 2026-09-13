# Frontend Craft Loop — 进度

循环规格：`docs/design/frontend-craft-loop.md`。先读规格选刀，状态板是数据，`Next` 不是命令。
一刀一节，新的写在最上面。
AI 服务总分 8.1、已到过 8.0，连续两刀 <0.3 后换到微信连接。微信连接总分 8.2、已到过 8.0，连续两刀 <0.3 后换到首次引导。首次引导总分 8.3、已到过 8.0，连续两刀 <0.3 后换到关注谁。关注谁总分 8.1、已到过 8.0，连续两刀 <0.3 后换到待办。待办总分 8.0、已到过 8.0，连续两刀 <0.3 后换到今日小结。今日小结总分 8.1、已到过 8.0，连续两刀 <0.3 后换到提醒方式。提醒方式总分 8.0、已到过 8.0，连续两刀 <0.3 后换到使用偏好。使用偏好总分 8.3、已到过 8.0，连续两刀 <0.3 后换到本地资料。本地资料总分 8.0、已到过 8.0，连续两刀 <0.3 后换到怎么用。怎么用总分 6.3、从未到过 8.0。待确认回复 7.8、从未到过 8.0，回扫时留下。自动回复设置 8.1、已到过 8.0 且连续两刀 <0.3。

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
| 8 | 微信连接 | in-progress | 8.2 | 选账号已让步；准备时「取消」仍是系统链接。已到 8.0，连续两刀 <0.3，换表面 |
| 9 | 首次引导 | in-progress | 8.3 | 名单先出；人多时「找人」才出搜索。已到 8.0，连续两刀 <0.3，换表面 |
| 10 | 关注谁 | in-progress | 8.1 | 添加框筛选已让出青玉。已到 8.0，连续两刀 <0.3 |
| 11 | 待办 | in-progress | 8.0 | 恢复未完成会说话。已到 8.0，连续两刀 <0.3 |
| 12 | 今日小结 | in-progress | 8.1 | 跟进不再每行「查看待办」。已到 8.0，连续两刀 <0.3 |
| 13 | 提醒方式 / 使用偏好 / 本地资料 / 怎么用 | in-progress | 6.3 | 三步会说人话。从未到过 8.0。本刀：怎么用 |
| 14 | 侧栏与页头 | queued | — | 勿第一刀就合并 18 个 tab |
| 15 | 对话详情 / 对话框 | queued | — | |
| 16 | 全站微交互巡检 | queued | — | 放在多数页面主动词成立之后 |

## Cycle 137 — 2026-09-14 — 怎么用

- Surface: 怎么用
- Files: `Sources/WeChatHUD/Views/CompanionGuideView.swift`、`Tests/WeChatHUDTests/CompanionGuideContractTests.swift`
- Before: 总分 6.0（主动词 6.5 / 空气 7.0 / 短句 6.0 / 物理 4.5 / 状态戏 6.0 / 稀疏 4.7 / 回执 5.5）
- Debt picked: 三步说明仍偏说明书。
- After: 总分 6.3（主动词 6.5 / 空气 7.0 / 短句 8.0 / 物理 4.5 / 状态戏 6.0 / 稀疏 4.7 / 回执 5.5）
- Changed: 三步写「登录这台 Mac 的微信。」「选一个人或一个群。」「今天看待回和待办。」护栏未改。
- Verified: `swift test --filter CompanionGuideContractTests` 4 个用例全绿；`swift build -c release`。走查：开怎么用 → 看到「先连接微信」→ 看到「选择对话」和「打开今天」→ 看到「登录这台 Mac 的微信」。
- Next: 怎么用还要再来：总分 6.3，从未到过 8.0。圈主动词——三步并排三个同等按钮。

## Cycle 136 — 2026-09-14 — 怎么用

- Surface: 怎么用
- Files: `Sources/WeChatHUD/Views/CompanionGuideView.swift`、`Tests/WeChatHUDTests/CompanionGuideContractTests.swift`
- Before: 总分 5.7（主动词 6.5 / 空气 5.0 / 短句 6.0 / 物理 4.5 / 状态戏 6.0 / 稀疏 4.7 / 回执 5.5）
- Debt picked: 三步仍用系统 accent 圆点，和页头抢层级。
- After: 总分 6.0（主动词 6.5 / 空气 7.0 / 短句 6.0 / 物理 4.5 / 状态戏 6.0 / 稀疏 4.7 / 回执 5.5）
- Changed: 三步的编号是安静次要字，不是系统 accent 实心圆。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter CompanionGuideContractTests` 3 个用例全绿；`swift build -c release`。走查：开怎么用 → 看到「先连接微信」→ 看到「选择对话」和「打开今天」→ 编号不是色块圆点。
- Next: 怎么用还要再来：总分 6.0，从未到过 8.0。圈短句——三步说明仍偏说明书。

## Cycle 135 — 2026-09-14 — 怎么用

- Surface: 怎么用
- Files: `Sources/WeChatHUD/Views/CompanionGuideView.swift`、`Tests/WeChatHUDTests/CompanionGuideContractTests.swift`
- Before: 总分 5.3（主动词 4.5 / 空气 5.0 / 短句 6.0 / 物理 4.5 / 状态戏 6.0 / 稀疏 4.5 / 回执 5.5）
- Debt picked: 打开页是说明书墙，不知道先做什么。
- After: 总分 5.7（主动词 6.5 / 空气 5.0 / 短句 6.0 / 物理 4.5 / 状态戏 6.0 / 稀疏 4.7 / 回执 5.5）
- Changed: 打开先看到「先连接微信，再选人，再看今天。」和三步。点「还要看其余说明」才看到每天怎么用。护栏未改。
- Verified: `swift test --filter CompanionGuideContractTests` 2 个用例全绿；`swift build -c release`。走查：开怎么用 → 看到「先连接微信」→ 看到「选择对话」和「打开今天」→ 没有铺开的「每天怎么用」→ 点「还要看其余说明」。
- Next: 怎么用还要再来：总分 5.7，从未到过 8.0。圈空气——三步仍用系统 accent 圆点，和页头抢层级。

## Cycle 134 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.5 / 稀疏 7.4 / 回执 6.7）
- Debt picked: 「导出到桌面」仍是系统青玉按钮。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 7.5 / 稀疏 7.4 / 回执 6.7）
- Changed: 「导出到桌面」和「查看文件」按下会缩，不再是青玉主按钮。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 10 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」和「承诺」→ 点「还要导出」→ 按下「导出到桌面」会让步、不是青玉。
- Next: 本地资料已到 8.0，连续两刀 <0.3，换到怎么用。本地资料保持 in-progress。

## Cycle 133 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.5 / 稀疏 5.4 / 回执 6.7）
- Debt picked: 名单行仍堆着类型胶囊和百分比。
- After: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.5 / 稀疏 7.4 / 回执 6.7）
- Changed: 提问行只留人和摘要。撤回行不再跟 AI 胶囊。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 9 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」和「承诺」→ 点「提问」→ 行上没有百分比。
- Next: 本地资料还要再来：总分 7.8，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「导出到桌面」仍是系统青玉按钮。

## Cycle 132 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 6.7）
- Debt picked: 空名单只是一句空话，没有下一步。
- After: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.5 / 稀疏 5.4 / 回执 6.7）
- Changed: 承诺或提问空了，写那句空话，下面是「去待办里看」。不是青玉。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 8 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」和「承诺」→ 空时看到「近两周没有记下的承诺」和「去待办里看」。
- Next: 本地资料还要再来：总分 7.6，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——名单行仍堆着类型胶囊和百分比。

## Cycle 131 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 5.0）
- Debt picked: 改记录失败仍是顶上一道红条。
- After: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 6.7）
- Changed: 改记录失败写「刚才没记上。」没有顶上红条。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 7 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」和「承诺」→ 失败时看到「刚才没记上」，不是红条。
- Next: 本地资料还要再来：总分 7.3，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——空名单只是一句空话，没有下一步。

## Cycle 130 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 5.0）
- Debt picked: 「完成」「取消」仍是系统小按钮。
- After: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 5.0）
- Changed: 「完成」「取消」「已处理」「忽略」按下会缩，不再是系统小按钮。不是青玉。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 6 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」和「承诺」→ 按下「完成」会让步。
- Next: 本地资料还要再来：总分 7.1，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——改记录失败仍是顶上一道红条。

## Cycle 129 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 6.7（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 5.0）
- Debt picked: 名单仍套在系统卡里，和页头「近两周」抢层级。
- After: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 5.0）
- Changed: 筛选和名单直接坐在画布上，不再另套一张卡。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 5 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」→ 看到「承诺」→ 名单不在另一张卡里。
- Next: 本地资料还要再来：总分 6.8，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「完成」「取消」仍是系统小按钮。

## Cycle 128 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 6.4（主动词 6.5 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 5.0）
- Debt picked: 搜索框仍和名单抢第一步。
- After: 总分 6.7（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.4 / 回执 5.0）
- Changed: 打开先看到「承诺」「提问」「撤回记录」。点「还要找」才看到搜索。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 5 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」和「承诺」→ 没有铺开的「找人或内容」→ 点「还要找」。
- Next: 本地资料还要再来：总分 6.7，从未到过 8.0。圈空气——名单仍套在系统卡里，和页头「近两周」抢层级。

## Cycle 127 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 6.1（主动词 6.5 / 空气 7.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 5.0）
- Debt picked: 搜索框和「待处理的提问」仍在讲实现。
- After: 总分 6.4（主动词 6.5 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 5.0）
- Changed: 搜索写「找人或内容」。筛选是「提问」，不是「待处理的提问」。空名单写「近两周没有记下的提问」。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 4 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」→ 看到「承诺」和「提问」→ 搜索框是「找人或内容」。
- Next: 本地资料还要再来：总分 6.4，从未到过 8.0。圈主动词——搜索框仍和名单抢第一步。

## Cycle 126 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 5.7（主动词 6.5 / 空气 5.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 5.0）
- Debt picked: 「记录回溯」仍是单独一张卡，和页头「近两周」叠着。
- After: 总分 6.1（主动词 6.5 / 空气 7.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 5.0）
- Changed: 名单卡不再写「记录回溯」。「只看近 14 天整理过的记录。」坐在画布上，不在卡里。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 3 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」→ 看到「只看近」和「承诺」→ 卡里没有「记录回溯」。
- Next: 本地资料还要再来：总分 6.1，从未到过 8.0。圈短句——搜索框和「待处理的提问」仍在讲实现。

## Cycle 125 — 2026-09-14 — 本地资料

- Surface: 本地资料
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/LocalDataSettingsContractTests.swift`
- Before: 总分 5.3（主动词 4.5 / 空气 5.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 5.0）
- Debt picked: 打开页不知道近两周整理过几件，导出报告抢第一步。
- After: 总分 5.7（主动词 6.5 / 空气 5.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 5.0）
- Changed: 打开先看到「近两周整理过 3 件事。」或「近两周没有整理过的记录。」点「还要导出」才看到导出。护栏未改。
- Verified: `swift test --filter LocalDataSettingsContractTests` 2 个用例全绿；`swift build -c release`。走查：开本地资料 → 看到「近两周」→ 看到「记录回溯」和「承诺」→ 没有铺开的「导出到桌面」→ 点「还要导出」。
- Next: 本地资料还要再来：总分 5.7，从未到过 8.0。圈空气——「记录回溯」仍是单独一张卡，和页头「近两周」叠着。

## Cycle 124 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 8.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 7.7 / 稀疏 7.2 / 回执 8.2）
- Debt picked: 系统通知仍和登录、微信操作抢首屏。
- After: 总分 8.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 7.7 / 稀疏 8.5 / 回执 8.2）
- Changed: 打开先看到登录和微信操作权限。点「还要管通知」才看到系统通知。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 12 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」和「登录时启动」和「显示位置」→ 没有铺开的「系统通知」→ 点「还要管通知」。
- Next: 使用偏好已到 8.3，连续两刀 <0.3，换到本地资料。使用偏好保持 in-progress。

## Cycle 123 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 7.7 / 稀疏 7.2 / 回执 6.7）
- Debt picked: 重新检查后的说明仍是实现句。
- After: 总分 8.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 7.7 / 稀疏 7.2 / 回执 8.2）
- Changed: 点「重新检查权限」后写「可以跳转微信了。」或「还没授权。关掉助手再打开一次。」没有「权限已生效」。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 12 个用例全绿；`swift build -c release`。走查：开使用偏好 → 按下「重新检查权限」→ 看到「可以跳转微信了」或「还没授权」→ 看到「浮窗在」和「显示位置」。
- Next: 使用偏好还要再来：总分 8.2，已到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——系统通知仍和登录、微信操作抢首屏。

## Cycle 122 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 5.7 / 稀疏 7.2 / 回执 6.7）
- Debt picked: 权限未开时仍是卡内橙条。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 7.7 / 稀疏 7.2 / 回执 6.7）
- Changed: 未授权时写「还没授权跳转微信。点「打开辅助功能设置」。」没有橙条图标。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 11 个用例全绿；`swift build -c release`。走查：开使用偏好 → 未授权时看到「还没授权跳转微信」和「打开辅助功能设置」→ 看到「浮窗在」和「显示位置」。
- Next: 使用偏好还要再来：总分 8.0，已到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——重新检查后的说明仍是实现句。

## Cycle 121 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.7 / 稀疏 7.2 / 回执 6.7）
- Debt picked: 「打开辅助功能设置」仍是系统按钮。
- After: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 5.7 / 稀疏 7.2 / 回执 6.7）
- Changed: 「打开辅助功能设置」「重新检查权限」「允许系统通知」按下会缩，不再是系统描边。不是青玉。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 10 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」→ 按下「打开辅助功能设置」或「重新检查权限」会让步 → 看到「显示位置」。
- Next: 使用偏好还要再来：总分 7.7，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——权限未开时仍是卡内橙条。

## Cycle 120 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.7 / 稀疏 5.2 / 回执 6.7）
- Debt picked: 「动画与透明度」还在首屏。
- After: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.7 / 稀疏 7.2 / 回执 6.7）
- Changed: 打开先看到登录、微信操作权限和系统通知。点「还要看动画」才看到动画与透明度。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 9 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」和「登录时启动」→ 没有铺开的「动画与透明度」→ 点「还要看动画」。
- Next: 使用偏好还要再来：总分 7.5，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「打开辅助功能设置」仍是系统按钮。

## Cycle 119 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 4.7）
- Debt picked: 存失败仍是顶上一道红条「重试保存设置」。
- After: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.7 / 稀疏 5.2 / 回执 6.7）
- Changed: 存失败写「刚才没记上。」并出现「再试一次」。没有顶上红条。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 8 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」和「显示位置」→ 失败时看到「刚才没记上」和「再试一次」，不是红条「重试保存设置」。
- Next: 使用偏好还要再来：总分 7.3，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——「动画与透明度」还在首屏。

## Cycle 118 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 4.7）
- Debt picked: 显示位置仍是系统菜单。
- After: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 4.7）
- Changed: 「原生屏幕」和「扩展屏」是安静胶囊，按下会缩。不是系统菜单，也不是青玉。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 7 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」→ 按下「原生屏幕」或「扩展屏」会让步 → 看到「显示位置」。
- Next: 使用偏好还要再来：总分 7.1，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——存失败仍是顶上一道红条「重试保存设置」。

## Cycle 117 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 6.7（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 4.7）
- Debt picked: 显示位置仍是单独一张卡，和权限卡叠着。
- After: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 4.7）
- Changed: 显示位置只有一行，不再先写一遍标题再写一遍。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 6 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」→ 看到一行「显示位置」，上面没有第二句同样的标题。
- Next: 使用偏好还要再来：总分 6.8，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——显示位置仍是系统菜单。

## Cycle 116 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 6.4（主动词 6.7 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.7）
- Debt picked: 版本与更新和权限卡抢第一步。
- After: 总分 6.7（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.2 / 回执 4.7）
- Changed: 打开先看到浮窗在哪和权限。点「还要看版本」才看到更新。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 5 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」和「显示位置」和「登录时启动」→ 没有铺开的「检查更新」→ 点「还要看版本」。
- Next: 使用偏好还要再来：总分 6.7，从未到过 8.0。圈空气——显示位置仍是单独一张卡，和权限卡叠着。

## Cycle 115 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 6.1（主动词 6.7 / 空气 7.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.7）
- Debt picked: 「微信操作权限」和动画行仍在讲实现。
- After: 总分 6.4（主动词 6.7 / 空气 7.5 / 短句 8.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.7）
- Changed: 显示位置写「浮窗出现在哪块屏。」微信操作写「跳转微信和发出回复要用。读聊天不用这个。」没有「不影响读取聊天」。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 4 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」和「显示位置」→ 看到「跳转微信和发出回复要用」。
- Next: 使用偏好还要再来：总分 6.4，从未到过 8.0。圈主动词——版本与更新和权限卡抢第一步。

## Cycle 114 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 5.7（主动词 6.5 / 空气 5.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.5）
- Debt picked: 权限卡里永远挂着青玉「更改已保存」，和显示位置叠成两张系统卡。
- After: 总分 6.1（主动词 6.7 / 空气 7.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.7）
- Changed: 权限卡只剩开关和权限行。没有永远在的「更改已保存」。「关闭这个窗口后，助手仍留在顶部和菜单栏。」坐在画布上。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 3 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在」和「显示位置」→ 权限卡里没有「更改已保存」→ 卡下看到「关闭这个窗口后」。
- Next: 使用偏好还要再来：总分 6.1，从未到过 8.0。圈短句——「微信操作权限」和动画行仍在讲实现。

## Cycle 113 — 2026-09-14 — 使用偏好

- Surface: 使用偏好
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Tests/WeChatHUDTests/PreferencesSettingsContractTests.swift`
- Before: 总分 5.3（主动词 4.5 / 空气 5.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.5）
- Debt picked: 打开页不知道浮窗在哪块屏，显示位置图标还是青玉。
- After: 总分 5.7（主动词 6.5 / 空气 5.5 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 5.0 / 回执 4.5）
- Changed: 打开先看到「浮窗在原生屏幕。」或「浮窗在扩展屏。」显示位置图标不是青玉。护栏未改。
- Verified: `swift test --filter PreferencesSettingsContractTests` 2 个用例全绿；`swift build -c release`。走查：开使用偏好 → 看到「浮窗在原生屏幕」或「浮窗在扩展屏」→ 看到「显示位置」。
- Next: 使用偏好还要再来：总分 5.7，从未到过 8.0。圈空气——权限卡里永远挂着青玉「更改已保存」，和显示位置叠成两张系统卡。

## Cycle 112 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 8.0 / 稀疏 7.7 / 回执 8.2）
- Debt picked: 展开后展示时间仍是系统 Picker。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.7 / 回执 8.2）
- Changed: 「3 秒 / 5 秒 / 8 秒 / 15 秒」是安静胶囊，按下会缩。不是系统 Picker，也不是青玉。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 7 个用例全绿；`swift build -c release`。走查：开提醒方式 → 看到「现在会弹出」→ 按下「还要改展示多久」→ 按下「3 秒」会让步、不是青玉 → 看到「群里 @ 我的消息」。
- Next: 提醒方式已到 8.0，连续两刀 <0.3，换到使用偏好。提醒方式保持 in-progress。

## Cycle 111 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 8.0 / 稀疏 7.7 / 回执 6.2）
- Debt picked: 「已经记下」和没改时同一句次要字。
- After: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 8.0 / 稀疏 7.7 / 回执 8.2）
- Changed: 改完写「已经记下。」是正文。没改时仍是「改了就生效。」没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 6 个用例全绿；`swift build -c release`。走查：开提醒方式 → 拨一个开关 → 看到「已经记下」比「改了就生效」更重 → 看到「现在会弹出」和「群里 @ 我的消息」。
- Next: 提醒方式还要再来：总分 7.9，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——展开后展示时间仍是系统 Picker。

## Cycle 110 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 6.0 / 稀疏 7.7 / 回执 6.2）
- Debt picked: 关掉全部弹出后，页上没有「现在不会弹出」之外的下一步。
- After: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 8.0 / 稀疏 7.7 / 回执 6.2）
- Changed: 三项全关时写「现在浮窗不会自己弹出。」下面是「打开上面一项，有消息才会弹出。」没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 5 个用例全绿；`swift build -c release`。走查：开提醒方式 → 关掉三项 → 看到「现在浮窗不会自己弹出」和「打开上面一项」→ 看到「群里 @ 我的消息」。
- Next: 提醒方式还要再来：总分 7.7，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——「已经记下」和没改时同一句次要字。

## Cycle 109 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.2 / 状态戏 6.0 / 稀疏 7.7 / 回执 6.2）
- Debt picked: 「还要改展示多久」仍是系统 DisclosureGroup，按下没有让步。
- After: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.0 / 状态戏 6.0 / 稀疏 7.7 / 回执 6.2）
- Changed: 「还要改展示多久」按下会缩。不是系统 DisclosureGroup。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 4 个用例全绿；`swift build -c release`。走查：开提醒方式 → 看到「现在会弹出」→ 按下「还要改展示多久」会让步 → 看到「展示时间」→ 看到「群里 @ 我的消息」。
- Next: 提醒方式还要再来：总分 7.4，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——关掉全部弹出后，页上没有「现在不会弹出」之外的下一步。

## Cycle 108 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 6.9（主动词 7.0 / 空气 8.0 / 短句 8.0 / 物理 5.2 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.2）
- Debt picked: 「展示时间」和三个弹出开关抢第一步。
- After: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.2 / 状态戏 6.0 / 稀疏 7.7 / 回执 6.2）
- Changed: 打开先看到三个弹出开关。「还要改展示多久」才展开展示时间。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 4 个用例全绿；`swift build -c release`。走查：开提醒方式 → 看到「现在会弹出」和「群里 @ 我的消息」→ 没有铺开的秒数选择 → 点「还要改展示多久」才看到「展示时间」。
- Next: 提醒方式还要再来：总分 7.1，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「还要改展示多久」仍是系统 DisclosureGroup，按下没有让步。

## Cycle 107 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 6.7（主动词 7.0 / 空气 8.0 / 短句 6.5 / 物理 5.2 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.0）
- Debt picked: 「关注对话的普通更新」和「更改会自动保存，即时生效」仍是系统口吻。
- After: 总分 6.9（主动词 7.0 / 空气 8.0 / 短句 8.0 / 物理 5.2 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.2）
- Changed: 第三项是「关注的人普通说话」。改完写「改了就生效。」或「已经记下。」失败写「没记住。点「再试一次」。」没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 3 个用例全绿；`swift build -c release`。走查：开提醒方式 → 看到「现在会弹出」→ 看到「群里 @ 我的消息」和「关注的人普通说话」，没有「普通更新」。
- Next: 提醒方式还要再来：总分 6.9，从未到过 8.0。圈主动词——「展示时间」和三个弹出开关抢第一步。

## Cycle 106 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 6.4（主动词 7.0 / 空气 6.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.0）
- Debt picked: 保存说明还套在开关卡里，用系统 caption。
- After: 总分 6.7（主动词 7.0 / 空气 8.0 / 短句 6.5 / 物理 5.2 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.0）
- Changed: 开关卡只剩开关和展示时间。说明和「设置已保存」坐在画布上，不是系统 caption。没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 2 个用例全绿；`swift build -c release`。走查：开提醒方式 → 看到「现在会弹出」→ 开关卡里没有「设置已保存」→ 卡下看到说明。
- Next: 提醒方式还要再来：总分 6.7，从未到过 8.0。圈短句——「关注对话的普通更新」和「更改会自动保存，即时生效」仍是系统口吻。

## Cycle 105 — 2026-09-14 — 提醒方式

- Surface: 提醒方式
- Files: `Sources/WeChatHUD/Views/Settings/NotificationSettingsView.swift`、`Tests/WeChatHUDTests/NotificationSettingsContractTests.swift`
- Before: 总分 6.0（主动词 5.0 / 空气 6.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.0）
- Debt picked: 打开页不知道现在浮窗会不会弹出。
- After: 总分 6.4（主动词 7.0 / 空气 6.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.0 / 稀疏 7.5 / 回执 6.0）
- Changed: 打开先看到「现在会弹出：群 @、重点的人。」全关时写「现在浮窗不会自己弹出。」没有青玉主按钮。护栏未改。
- Verified: `swift test --filter NotificationSettingsContractTests` 1 个用例全绿；`swift build -c release`。走查：开提醒方式 → 看到「现在会弹出」→ 看到「群里 @ 我的消息」和「重点关注的人」。
- Next: 提醒方式还要再来：总分 6.4，从未到过 8.0。圈空气——保存说明还套在开关卡里，用系统 caption。

## Cycle 104 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Debt picked: 每条事项并排「标记完成」和「查看待办」。
- After: 总分 8.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.2 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.0）
- Changed: 日报跟进每行只留「标记完成」。名单底下只有一句「在待办里看」。没有每行「查看待办」。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 8 个用例全绿；`swift build -c release`。走查：开今日小结 → 跟进行上没有「查看待办」→ 底下看到「在待办里看」→ 行上看到「标记完成」→ 看到「导出」。
- Next: 今日小结已到 8.0，连续两刀 <0.3，换到提醒方式。今日小结保持 in-progress。

## Cycle 103 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Debt picked: 来源未验证时「重新生成」仍是系统蓝字，按下没有让步。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Changed: 「重新生成」按下会缩，不再是系统蓝。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 7 个用例全绿；`swift build -c release`。走查：开今日小结 → 来源未验证看到「重新生成」按下会让步、不是蓝字 → 看到「导出」。
- Next: 今日小结还要再来：总分 8.0，已到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——每条事项并排「标记完成」和「查看待办」。

## Cycle 102 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportCommandCenterView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 6.5 / 稀疏 7.8 / 回执 8.0）
- Debt picked: 日报正文空着时把内部错误摊出来，还坐在系统窗口底上。
- After: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Changed: 写不出来时是「小结没写出来。点「再写一次」。」没有内部错误。还没有小结时写「还没有今日小结。连上微信后再看。」「再写一次」按下会缩，不是青玉。工作台正文坐在画布上。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 6 个用例全绿；`swift build -c release`。走查：开今日小结 → 空或失败看到「小结没写出来」和「再写一次」→ 没有内部错误串 → 看到「导出」。
- Next: 今日小结还要再来：总分 7.9，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——来源未验证时「重新生成」仍是系统蓝字，按下没有让步。

## Cycle 101 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 6.5 / 稀疏 7.8 / 回执 6.5）
- Debt picked: 导出失败仍是一条红字，没有下一步。
- After: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 6.5 / 稀疏 7.8 / 回执 8.0）
- Changed: 导出失败写「小结没写上。点「再试一次」。」并出现「再试一次」。成功仍是「小结已放到桌面。」和「打开这份小结」。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 5 个用例全绿；`swift build -c release`。走查：开今日小结 → 导出失败看到「小结没写上」和「再试一次」→ 成功看到「打开这份小结」→ 看到「导出」。
- Next: 今日小结还要再来：总分 7.7，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——日报正文空着时把内部错误摊出来，还坐在系统窗口底上。

## Cycle 100 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 每条跟进旁边都有「查看待办」，结论被按钮墙挡住。
- After: 总分 7.5（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 6.5 / 稀疏 7.8 / 回执 6.5）
- Changed: 周报跟进是名单。底下只有一句「在待办里看」。没有每行「查看待办」。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 4 个用例全绿；`swift build -c release`。走查：开今日小结 → 周报 → 跟进行上没有「查看待办」→ 底下看到「在待办里看」→ 看到「导出」。
- Next: 今日小结还要再来：总分 7.5，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——导出失败仍是一条红字，没有下一步。

## Cycle 99 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.4 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 「查看待办」仍是系统 `.plain` 青玉字。
- After: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.2 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Changed: 周报「查看待办」和「还有 N 件在待办里」按下会缩，不再是青玉。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 4 个用例全绿；`swift build -c release`。走查：开今日小结 → 周报 → 「查看待办」按下会让步、不是青玉 → 看到「导出」。
- Next: 今日小结还要再来：总分 7.3，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——每条跟进旁边都有「查看待办」，结论被按钮墙挡住。

## Cycle 98 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 6.9（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 5.4 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 周报已完成项仍是青玉数字圆。
- After: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.4 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Changed: 周报「已经推进」是普通序号，不是青玉圆。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 4 个用例全绿；`swift build -c release`。走查：开今日小结 → 周报 → 「已经推进」是普通数字 → 看到「导出」。
- Next: 今日小结还要再来：总分 7.0，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「查看待办」仍是系统 `.plain` 青玉字。

## Cycle 97 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 6.8（主动词 7.5 / 空气 7.5 / 短句 8.0 / 物理 5.2 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 日期左右还是系统描边，和「导出」抢手。
- After: 总分 6.9（主动词 8.0 / 空气 7.5 / 短句 8.0 / 物理 5.4 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Changed: 前一天 / 后一天是安静字，按下会缩。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 3 个用例全绿；`swift build -c release`。走查：开今日小结 → 点前一天/后一天不是系统描边小按钮 → 看到「导出」。
- Next: 今日小结还要再来：总分 6.9，从未到过 8.0。圈空气——周报已完成项仍是青玉数字圆。

## Cycle 96 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 6.6（主动词 7.5 / 空气 7.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 加载写「正在整理」；导出后写「打开结果」。
- After: 总分 6.8（主动词 7.5 / 空气 7.5 / 短句 8.0 / 物理 5.2 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Changed: 加载时写「正在写今天的小结。」或「正在写这周的小结。」导出后写「小结已放到桌面。」和「打开这份小结」。没有「正在整理」「打开结果」。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 3 个用例全绿；`swift build -c release`。走查：开今日小结 → 加载时看到「正在写今天的小结。」→ 导出后看到「小结已放到桌面。」和「打开这份小结」→ 看到「导出」。
- Next: 今日小结还要再来：总分 6.8，从未到过 8.0。圈主动词——日期左右还是系统描边，和「导出」抢手。

## Cycle 95 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 6.3（主动词 7.5 / 空气 5.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 工具条下面仍有一条 Divider，整页还坐在系统 windowBackground 上。
- After: 总分 6.6（主动词 7.5 / 空气 7.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Changed: 工作台今日小结没有横线，坐在画布上。青玉仍只在「导出」。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 2 个用例全绿；`swift build -c release`。走查：开今日小结 → 日报/周报和内容之间没有横线 → 看到「导出」。
- Next: 今日小结还要再来：总分 6.6，从未到过 8.0。圈短句——「正在整理」；导出回执仍写系统口吻。

## Cycle 94 — 2026-09-14 — 今日小结

- Surface: 今日小结
- Files: `Sources/WeChatHUD/Views/DailyReportTabView.swift`、`Tests/WeChatHUDTests/DailyReportWorkspaceContractTests.swift`
- Before: 总分 5.9（主动词 5.5 / 空气 5.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Debt picked: 「日报 / 周报」是青玉胶囊，「导出」是系统强调色，抢下一步。
- After: 总分 6.3（主动词 7.5 / 空气 5.5 / 短句 6.5 / 物理 5.0 / 状态戏 6.5 / 稀疏 6.0 / 回执 6.5）
- Changed: 「日报 / 周报」是安静胶囊。「导出」是青玉主按钮。护栏未改。
- Verified: `swift test --filter DailyReportWorkspaceContractTests` 1 个用例全绿；`swift build -c release`。走查：开今日小结 → 看到「日报」「周报」不是青玉实心胶囊 → 「导出」是青玉。
- Next: 今日小结还要再来：总分 6.3，从未到过 8.0。圈空气——工具条下面仍有一条 Divider，整页还坐在系统 windowBackground 上。

## Cycle 93 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.5 / 状态戏 8.0 / 稀疏 8.0 / 回执 7.0）
- Debt picked: 恢复未完成仍写「事项状态已保存」。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.5 / 状态戏 8.0 / 稀疏 8.0 / 回执 8.2）
- Changed: 点「恢复为未完成」后写「「名字」已恢复成未完成。」没有「事项状态已保存」。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 5 个用例全绿；`swift build -c release`。走查：开待办 → 选一条 → 标记完成 → 看已处理的 → 恢复为未完成 → 看到「已恢复成未完成」→ 看到「标记完成」。
- Next: 待办已到 8.0，连续两刀 <0.3，换到今日小结。待办保持 in-progress。

## Cycle 92 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.5 / 状态戏 6.5 / 稀疏 8.0 / 回执 7.0）
- Debt picked: 空名单仍是系统 ContentUnavailableView，收起时看起来像「还没有待办」。
- After: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.5 / 状态戏 8.0 / 稀疏 8.0 / 回执 7.0）
- Changed: 空着时是一句人话。被收起时写「有 N 条被收起」和「全部都记」。搜不到时是「清除搜索」。没有选中时写「从左边选一条」。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 4 个用例全绿；`swift build -c release`。走查：开待办 → 空名单看到「还没有待办」或「有 N 条被收起」→ 有列表时从左边选一条 → 看到「标记完成」。
- Next: 待办还要再来：总分 7.9，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——恢复未完成仍写「事项状态已保存」。

## Cycle 91 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 8.0 / 回执 7.0）
- Debt picked: 「较早收起」点开查看是系统 `.plain` 青玉字，按下没有让步。
- After: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.5 / 状态戏 6.5 / 稀疏 8.0 / 回执 7.0）
- Changed: 「N 件过期未处理，点开查看」和「收起」按下会缩一下，不再是青玉。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 3 个用例全绿；`swift build -c release`。走查：开待办 → 「看已处理的」→ 看到「点开查看」按下会让步 → 选一条看到「标记完成」。
- Next: 待办还要再来：总分 7.7，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——空名单仍是系统 ContentUnavailableView。

## Cycle 90 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 6.8 / 回执 7.0）
- Debt picked: 「保留」分段和「看已处理的」开关占满首屏。
- After: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 8.0 / 回执 7.0）
- Changed: 打开先看到范围和名单。「看已处理的」是安静字。「保留」在菜单里。有收起时才出现「已收起 N 条 · 展开」。没有「当前只显示还没做完的」。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 2 个用例全绿；`swift build -c release`。走查：开待办 → 看到「全部 / 我要做」和「看已处理的」→ 打开「保留」看到「全部都记」→ 没有分段开关铺在名单上 → 选一条看到「标记完成」。
- Next: 待办还要再来：总分 7.4，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——名单行和「较早收起」按下仍是系统 `.plain`。

## Cycle 89 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Debt picked: 「找待办」仍铺在名单上。
- After: 总分 7.3（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 6.8 / 回执 7.0）
- Changed: 打开先看到范围和名单。人多时才出现次级「找待办」。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 2 个用例全绿；`swift build -c release`。走查：开待办 → 没有铺开的搜索框 → 人多时按下「找待办」才出输入 → 选一条看到「标记完成」。
- Next: 待办还要再来：总分 7.3，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——「保留」和「看已处理的」仍占满首屏。

## Cycle 88 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 7.0（主动词 7.7 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Debt picked: 范围胶囊仍是实心青玉，和「标记完成」抢下一步。
- After: 总分 7.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Changed: 「全部 / 我要做 / 等对方 / 共同推进 / 信息备忘」是安静胶囊。青玉只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 2 个用例全绿；`swift build -c release`。走查：开待办 → 范围不是青玉实心胶囊 → 选一条看到「标记完成」是青玉。
- Next: 待办还要再来：总分 7.1，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——「找待办」仍铺在名单上；「保留」和「看已处理的」占满首屏。

## Cycle 87 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 6.8（主动词 7.7 / 空气 8.0 / 短句 7.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Debt picked: 搜索仍写「搜索待办或对话」。
- After: 总分 7.0（主动词 7.7 / 空气 8.0 / 短句 8.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Changed: 搜索框写「找待办」。没有「搜索待办或对话」。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 2 个用例全绿；`swift build -c release`。走查：开待办 → 看到「找待办」，没有「搜索待办或对话」→ 选一条看到「标记完成」。
- Next: 待办还要再来：总分 7.0，从未到过 8.0。圈主动词——范围胶囊仍是实心青玉，和「标记完成」抢下一步。

## Cycle 86 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 6.5（主动词 7.5 / 空气 6.0 / 短句 7.0 / 物理 5.5 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Debt picked: 「保留」铺在一块底上；搜索再套一层框。
- After: 总分 6.8（主动词 7.7 / 空气 8.0 / 短句 7.0 / 物理 5.7 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Changed: 「保留」和搜索直接放在画布上，没有底卡。「清除搜索」不再是青玉。青玉仍只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 2 个用例全绿；`swift build -c release`。走查：开待办 → 看到「保留」和「搜索待办或对话」没有套卡 → 选一条看到「标记完成」。
- Next: 待办还要再来：总分 6.8，从未到过 8.0。圈短句——搜索仍写「搜索待办或对话」；范围胶囊仍是实心青玉。

## Cycle 85 — 2026-09-14 — 待办

- Surface: 待办
- Files: `Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift`、`Tests/WeChatHUDTests/DiscussionWorkspaceContractTests.swift`
- Before: 总分 6.1（主动词 5.5 / 空气 6.0 / 短句 7.0 / 物理 5.5 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Debt picked: 「更正归属」「查看原文」是青玉，「标记完成」是系统强调色，抢下一步。
- After: 总分 6.5（主动词 7.5 / 空气 6.0 / 短句 7.0 / 物理 5.5 / 状态戏 6.5 / 稀疏 5.0 / 回执 7.0）
- Changed: 选中一条后，「标记完成」是青玉主按钮。「更正归属」「查看原文」是安静字。青玉只在「标记完成」。护栏未改。
- Verified: `swift test --filter DiscussionWorkspaceContractTests` 1 个用例全绿；`swift build -c release`。走查：开待办 → 选一条 → 看到「标记完成」是青玉 → 「更正归属」「查看原文」不是青玉。
- Next: 待办还要再来：总分 6.5，从未到过 8.0。圈空气——「保留」铺在一块底上；搜索再套一层框。

## Cycle 84 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Debt picked: 添加框筛选仍是青玉胶囊，和「添加关注」抢颜色。
- After: 总分 8.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.5 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Changed: 添加框里「全部 / 联系人 / 群聊」和名单上的筛选一样，是安静胶囊。青玉只留在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 11 个用例全绿；`swift build -c release`。走查：开关注谁 → 添加关注 → 看到「全部 / 联系人 / 群聊」不是青玉胶囊 → 青玉只在「添加关注」。
- Next: 关注谁已到 8.0，连续两刀 <0.3，换到待办。关注谁保持 in-progress。

## Cycle 83 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 7.8 / 回执 7.0）
- Debt picked: 改关注级别后没有一句刚才改成了什么；删除确认仍写「确认删除联系人」。
- After: 总分 7.9（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 7.8 / 回执 8.0）
- Changed: 改级别后名单上方写「已改成重点关注。」之类。去掉关注时问「不再关注「名字」？」，按钮是「移除关注」，没有「确认删除联系人」。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 11 个用例全绿；`swift build -c release`。走查：开关注谁 → 选一个人 → 改关注级别 → 看到「已改成…」→ 点「移除关注」看到「不再关注「…」？」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.9，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——添加框筛选仍是青玉胶囊，和「添加关注」抢颜色。

## Cycle 82 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 7.0 / 稀疏 7.8 / 回执 7.0）
- Debt picked: 「TA 是谁」仍是关系/层级/口吻表加百分比条。
- After: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 8.0 / 稀疏 7.8 / 回执 7.0）
- Changed: 有画像时，「TA 是谁」是一句「关系，层级。说话偏口吻。」没有百分比条，也没有「已人工校准」。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 11 个用例全绿；`swift build -c release`。走查：开关注谁 → 选一个有画像的人 → 看到一句人话，没有「关系」表和百分比 → 点「再看看」仍是「正在看这个人是谁。」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.8，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——改关注级别后没有一句刚才改成了什么；删除确认仍写「确认删除联系人」。

## Cycle 81 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 7.0 / 稀疏 6.5 / 回执 7.0）
- Debt picked: 右侧仍是「整理范围 / TA 是谁 / 操作」三块说明书。
- After: 总分 7.7（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 7.0 / 稀疏 7.8 / 回执 7.0）
- Changed: 选中后没有「操作」标题。关注级别分段和「编辑详情」「移除关注」直接放在下面。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 11 个用例全绿；`swift build -c release`。走查：开关注谁 → 选一个人 → 看到「整理范围」「TA 是谁」，没有「操作」标题 → 看到「编辑详情」「移除关注」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.7，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——「TA 是谁」仍是关系/层级/口吻表加百分比条。

## Cycle 80 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.0 / 稀疏 6.5 / 回执 7.0）
- Debt picked: 添加框名单行是系统 `.plain`；「编辑详情」「移除关注」是系统描边。
- After: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 7.8 / 状态戏 7.0 / 稀疏 6.5 / 回执 7.0）
- Changed: 添加框里点人、「取消」，以及「编辑详情」「移除关注」，按下会缩一下。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 11 个用例全绿；`swift build -c release`。走查：开关注谁 → 添加关注 → 点名单行和「取消」会让步 → 选一个人 → 「编辑详情」「移除关注」不是系统描边 → 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.6，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——右侧仍是「整理范围 / TA 是谁 / 操作」三块说明书，「关注级别」分段和页头徽章重复。

## Cycle 79 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.0 / 稀疏 6.5 / 回执 5.5）
- Debt picked: 「添加关注」关掉后名单没有一句刚才加了谁；「移除关注」也没有留下结果。
- After: 总分 7.4（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.0 / 稀疏 6.5 / 回执 7.0）
- Changed: 加上一个人后，名单上方写「已关注「名字」。」并选中这个人。去掉关注后写「已不再关注「名字」。」青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 10 个用例全绿；`swift build -c release`。走查：开关注谁 → 添加关注 → 关掉框后看到「已关注「…」。」→ 移除关注后看到「已不再关注「…」。」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.4，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——添加框名单行还是 `.plain`；「编辑详情」「移除关注」仍是系统描边。

## Cycle 78 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 6.5 / 回执 5.5）
- Debt picked: 选中一个人后，右侧是「关注级别 / 类型 / 提醒时机」说明书，看不出会发生什么。
- After: 总分 7.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 7.0 / 稀疏 6.5 / 回执 5.5）
- Changed: 选中后，「整理范围」说「优先提醒该回的消息。」「会整理这个人的聊天。」或「不日常提醒。」有窗口时再说「N 分钟后提醒」。点「再看看」时变成「正在看这个人是谁。」没有「只整理已关注的对话」。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 9 个用例全绿；`swift build -c release`。走查：开关注谁 → 选一个人 → 右侧看到会发生什么，不是「关注级别」表 → 点「再看看」看到「正在看这个人是谁。」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.2，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——「添加关注」关掉后名单没有一句刚才加了谁；「移除关注」也没有留下结果。

## Cycle 77 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 5.5 / 稀疏 6.5 / 回执 5.5）
- Debt picked: 名单行是系统 `.plain`，「再看看」是系统描边，按下没有让步。
- After: 总分 7.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 6.5 / 状态戏 5.5 / 稀疏 6.5 / 回执 5.5）
- Changed: 点名单、点「再看看」，按钮会缩一下。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 8 个用例全绿；`swift build -c release`。走查：开关注谁 → 点一个人，名单行按下会让步 → 右侧点「再看看」，不是系统描边小按钮 → 看到「添加关注」。
- Next: 关注谁还要再来：总分 7.0，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——选中后检查器仍像一块说明书；添加框名单行还是 `.plain`。

## Cycle 76 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 6.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.7 / 回执 5.5）
- Debt picked: 「更多」一次倒出四条去处；添加框再用「已选 N 个」和一句说明压名单。
- After: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 5.5 / 稀疏 6.5 / 回执 5.5）
- Changed: 添加框是名单和「添加关注」。没有「已选 N 个」，也没有「只开始整理选中的对话」。「不看谁」和「静音」在「更多 → 不看和静音」里。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 7 个用例全绿；`swift build -c release`。走查：开关注谁 → 按下「添加关注」→ 看到名单，没有「已选」和「只开始整理选中的对话」→ 打开「更多」先看到「什么会提醒我」「推荐关注」「看看这些人是谁」→ 「不看谁」在「不看和静音」里。
- Next: 关注谁还要再来：总分 6.8，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——名单行和「再看看」按下仍是系统按钮。

## Cycle 75 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 6.5（主动词 8.0 / 空气 8.0 / 短句 7.4 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.7 / 回执 5.5）
- Debt picked: 检查器写「微信 ID」和「重新整理」。
- After: 总分 6.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.7 / 回执 5.5）
- Changed: 「账号信息」里是「账号」，不是「微信 ID」。TA 是谁旁边是「再看看」。还不知道时说「点「再看看」」。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 6 个用例全绿；`swift build -c release`。走查：开关注谁 → 选一个人 → 看到「再看看」，没有「重新整理」→ 打开「账号信息」看到「账号」，没有「微信 ID」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 6.6，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈稀疏——「更多」仍一次倒出四条去处；添加框仍报「已选 N 个」。

## Cycle 74 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 6.4（主动词 7.4 / 空气 8.0 / 短句 7.4 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Debt picked: 「搜索联系人或群聊」铺在名单上，和页头「添加关注」抢第一步。
- After: 总分 6.5（主动词 8.0 / 空气 8.0 / 短句 7.4 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.7 / 回执 5.5）
- Changed: 打开先看到「全部 / 重点关注 / 群聊」和名单。没有铺开的搜索框。人多时才出现次级「找人」。没有人时是「还没有关注的人」和「点「添加关注」选对话。」青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 5 个用例全绿；`swift build -c release`。走查：开关注谁 → 看到「添加关注」和「全部」→ 没有铺开的「搜索联系人或群聊」→ 人多时按下「找人」才出搜索 → 空名单看到「还没有关注的人」。
- Next: 关注谁还要再来：总分 6.5，从未到过 8.0。圈短句——检查器仍写「微信 ID」；「重新整理」仍在。

## Cycle 73 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 6.2（主动词 7.4 / 空气 7.0 / 短句 7.4 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Debt picked: 右侧检查器用三条 Divider 切开「整理范围」「TA 是谁」「操作」；整理状态铺在系统小底上。
- After: 总分 6.4（主动词 7.4 / 空气 8.0 / 短句 7.4 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Changed: 选中一个人后，右侧「整理范围」「TA 是谁」「操作」用间距分开，没有横线。整理状态是工作台字，不是系统小底。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 4 个用例全绿；`swift build -c release`。走查：开关注谁 → 选一个人 → 右侧看到「整理范围」「TA 是谁」「操作」，之间没有横线 → 空态仍是「选择一个人或一个群」。
- Next: 关注谁还要再来：总分 6.4，从未到过 8.0。圈主动词——「搜索联系人或群聊」仍铺在名单上。

## Cycle 72 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 6.0（主动词 7.4 / 空气 6.8 / 短句 6.0 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Debt picked: 「更多」里写「批量整理关系」，名单行上写 Nm。
- After: 总分 6.2（主动词 7.4 / 空气 7.0 / 短句 7.4 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Changed: 「更多」里是「看看这些人是谁」。名单上是「N 分钟」，不是 Nm。青玉仍只在「添加关注」。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 3 个用例全绿；`swift build -c release`。走查：开关注谁 → 打开「更多」看到「看看这些人是谁」，没有「批量整理关系」→ 名单上是「N 分钟」→ 看到「添加关注」。
- Next: 关注谁还要再来：总分 6.2，从未到过 8.0。圈空气——检查器仍是多层 Divider；整理状态仍是系统小底。

## Cycle 71 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/SettingsView.swift`、`Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 5.6（主动词 5.7 / 空气 6.8 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Debt picked: 页头「添加关注」是系统 prominent，「返回关注列表」是青玉，和添加抢下一步。
- After: 总分 6.0（主动词 7.4 / 空气 6.8 / 短句 6.0 / 物理 4.7 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Changed: 「添加关注」是青玉，按下缩回。「返回关注列表」是工作台次级字。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 2 个用例全绿；`swift build -c release`。走查：开关注谁 → 看到青玉「添加关注」→ 按下「添加关注」缩回 → 打开「更多」里的「推荐关注」→ 按下「返回关注列表」缩回，不是青玉。
- Next: 关注谁还要再来：总分 6.0，从未到过 8.0。圈短句——「更多」里仍是「批量整理关系」；行上仍写 Nm。

## Cycle 70 — 2026-09-14 — 关注谁

- Surface: 关注谁
- Files: `Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift`、`Tests/WeChatHUDTests/ContactsSettingsContractTests.swift`
- Before: 总分 5.3（主动词 5.5 / 空气 5.0 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Debt picked: 「搜索联系人或群聊」和「更多」铺在一块盘子上，筛选「全部 / 重点关注 / 群聊」是青玉实心，压在名单上面。
- After: 总分 5.6（主动词 5.7 / 空气 6.8 / 短句 6.0 / 物理 4.5 / 状态戏 5.5 / 稀疏 4.5 / 回执 5.5）
- Changed: 「搜索联系人或群聊」和「更多」直接在画布上。筛选「全部 / 重点关注 / 群聊」不是青玉实心。页头「添加关注」仍在。护栏未改。
- Verified: `swift test --filter ContactsSettingsContractTests` 1 个用例全绿；`swift build -c release`。走查：开关注谁 → 看到「搜索联系人或群聊」和「更多」不在盘子上 → 看到「全部」「重点关注」「群聊」不是青玉实心 → 看到名单。
- Next: 关注谁还要再来：总分 5.6，从未到过 8.0。圈主动词——页头「添加关注」仍是系统 prominent；「返回关注列表」仍是青玉。

## Cycle 69 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/FirstLaunchContactPicker.swift`、`Sources/WeChatHUD/Data/FirstLaunchGuide.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 8.2（主动词 8.2 / 空气 8.8 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.2）
- Debt picked: 「搜索联系人或群聊」铺在名单上，和「从一个人或一个群开始」抢第一眼。
- After: 总分 8.3（主动词 8.2 / 空气 8.8 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 9.5 / 回执 8.2）
- Changed: 「从一个人或一个群开始」下面就是名单。没有搜索框。人多时才出现次级「找人」。「开始使用」仍在底栏。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 16 个用例全绿；`swift build -c release`。走查：开首次引导 → 连上后到选择关注 → 看到「从一个人或一个群开始」和名单 → 没有「搜索联系人或群聊」→ 人多时按下「找人」才出搜索 → 看到「开始使用」。
- Next: 连续两刀升幅都 < 0.3，且本页已到过 8.0。换到关注谁。本页保持 in-progress：人多时「找人」仍是次级；联系人行按下仍是 `.plain`。

## Cycle 68 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/FirstLaunchContactPicker.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 8.0（主动词 8.2 / 空气 8.6 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.0 / 回执 8.2）
- Debt picked: 名单下用系统字再报一遍「已选 N 个对话」，勾选已经说明选了谁。
- After: 总分 8.2（主动词 8.2 / 空气 8.8 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.2）
- Changed: 「从一个人或一个群开始」下面就是名单。没有「已选 N 个对话」。「开始使用」仍在底栏。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 15 个用例全绿；`swift build -c release`。走查：开首次引导 → 连上后到选择关注 → 看到「从一个人或一个群开始」和名单 → 没有「已选」→ 看到「开始使用」。
- Next: 首次引导还要再来：总分 8.2，未到 8.5。主动词/空气/短句都 ≥ 8，圈稀疏——「搜索联系人或群聊」仍铺在名单上。

## Cycle 67 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/FirstLaunchContactPicker.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 7.7（主动词 8.2 / 空气 8.4 / 短句 8.0 / 物理 8.0 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Debt picked: 名单为空是系统 callout，关注没存上是红字「关注范围没有保存成功，请重试。」
- After: 总分 8.0（主动词 8.2 / 空气 8.6 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.0 / 回执 8.2）
- Changed: 空名单说「也可以稍后再选。」失败是「刚才没存上。」和「再试一次」。按下缩回并重试。没有红字。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 14 个用例全绿；`swift build -c release`。走查：开首次引导 → 连上后到选择关注 → 空名单看到「也可以稍后再选。」没有红字 → 失败回执若出现，是「刚才没存上。」和「再试一次」→ 看到「开始使用」。
- Next: 首次引导还要再来：总分刚到 8.0，未到 8.5。主动词/空气/短句都 ≥ 8，圈稀疏——「已选 N 个对话」仍是系统字压在名单下。

## Cycle 66 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 7.5（主动词 8.0 / 空气 8.4 / 短句 8.0 / 物理 6.7 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Debt picked: 「开始使用」是系统边框主按钮，按下没有缩回。
- After: 总分 7.7（主动词 8.2 / 空气 8.4 / 短句 8.0 / 物理 8.0 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Changed: 「开始使用」是青玉，按下缩回。未连上时「下一步」仍不是青玉，青玉在连接卡「连接微信」。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 13 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到连接卡「连接微信」→ 连上后到选择关注 → 看到青玉「开始使用」→ 按下「开始使用」缩回。
- Next: 首次引导还要再来：总分 7.7，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈状态戏——名单为空或失败时仍是红字/系统 callout。

## Cycle 65 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Sources/WeChatHUD/Data/FirstLaunchGuide.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 7.3（主动词 8.0 / 空气 8.2 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 7.0 / 回执 6.0）
- Debt picked: 介绍进度没存上是滚动区里的红字 callout。
- After: 总分 7.5（主动词 8.0 / 空气 8.4 / 短句 8.0 / 物理 6.7 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Changed: 没存上时，连接卡下面出现「刚才没存上。」和「再试一次」。按下缩回并重试。没有红字「介绍进度未能保存」。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 12 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到连接卡「连接微信」→ 页上没有红字「介绍进度未能保存」→ 失败回执若出现，是「刚才没存上。」和「再试一次」。
- Next: 首次引导还要再来：总分 7.5，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「开始使用」仍是系统边框，按下没有缩回。

## Cycle 64 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 7.0（主动词 8.0 / 空气 8.2 / 短句 8.0 / 物理 4.7 / 状态戏 6.5 / 稀疏 7.0 / 回执 6.0）
- Debt picked: 「稍后设置」按下没有缩回。
- After: 总分 7.3（主动词 8.0 / 空气 8.2 / 短句 8.0 / 物理 6.5 / 状态戏 6.5 / 稀疏 7.0 / 回执 6.0）
- Changed: 「稍后设置」和「上一步」按下缩回。青玉仍只在品牌标和连接卡「连接微信」。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 11 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到连接卡「连接微信」→ 按下「稍后设置」缩回。
- Next: 首次引导还要再来：总分 7.3，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈回执——介绍进度没存上仍是红字 callout。

## Cycle 63 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.5 / 稀疏 5.3 / 回执 6.0）
- Debt picked: 「选择关注」在列表下再讲一遍「只整理你选中的对话，之后可以随时调整。AI 可选，不影响开始使用。」
- After: 总分 7.0（主动词 8.0 / 空气 8.2 / 短句 8.0 / 物理 4.7 / 状态戏 6.5 / 稀疏 7.0 / 回执 6.0）
- Changed: 「从一个人或一个群开始」下面就是名单。没有那句底部说明。「开始使用」仍在底栏。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 11 个用例全绿；`swift build -c release`。走查：开首次引导 → 连上后到选择关注 → 看到「从一个人或一个群开始」→ 没有「只整理你选中的对话，之后可以随时调整。AI 可选，不影响开始使用。」→ 看到「开始使用」。
- Next: 首次引导还要再来：总分 7.0，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「稍后设置」按下没有缩回。

## Cycle 62 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 6.7（主动词 8.0 / 空气 7.6 / 短句 8.0 / 物理 4.5 / 状态戏 6.5 / 稀疏 5.3 / 回执 6.0）
- Debt picked: 底栏「稍后设置」是系统按钮，和页头工作台字不是一套节奏。
- After: 总分 6.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 4.7 / 状态戏 6.5 / 稀疏 5.3 / 回执 6.0）
- Changed: 「稍后设置」和「上一步」是工作台次级字，不是系统边框。青玉仍只在品牌标和连接卡「连接微信」。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 10 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到连接卡「连接微信」→ 底栏「稍后设置」是工作台字，不是系统边框 → 没有「下一步」。
- Next: 首次引导还要再来：总分 6.8，从未到过 8.0。主动词/空气/短句都 ≥ 8，圈物理——「稍后设置」按下没有缩回。

## Cycle 61 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 6.5（主动词 7.4 / 空气 7.4 / 短句 7.8 / 物理 4.5 / 状态戏 6.5 / 稀疏 5.1 / 回执 6.0）
- Debt picked: 未连上时底栏仍放一颗不能按的「下一步」，旁边再写「连上微信后才能继续」，和连接卡「连接微信」抢下一步。
- After: 总分 6.7（主动词 8.0 / 空气 7.6 / 短句 8.0 / 物理 4.5 / 状态戏 6.5 / 稀疏 5.3 / 回执 6.0）
- Changed: 未连上时底栏只有「稍后设置」。没有「下一步」，也没有「连上微信后才能继续」。下一步在连上之后才出现。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 9 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到连接卡「连接微信」→ 底栏是「稍后设置」，没有「下一步」→ 没有「连上微信后才能继续」。
- Next: 首次引导还要再来：总分 6.7，从未到过 8.0。圈空气——「稍后设置」仍是系统字，底栏提示仍是裸 system 12。

## Cycle 60 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 6.2（主动词 7.2 / 空气 7.2 / 短句 6.2 / 物理 4.5 / 状态戏 6.5 / 稀疏 4.9 / 回执 6.0）
- Debt picked: 页题「先连接你的微信」和连接卡「连接你的微信」抢同一句话；连上后页题还在说先连接。
- After: 总分 6.5（主动词 7.4 / 空气 7.4 / 短句 7.8 / 物理 4.5 / 状态戏 6.5 / 稀疏 5.1 / 回执 6.0）
- Changed: 第一步没有「先连接你的微信」。现状由连接卡说：未连是「连接你的微信」，连上是「微信已连接」。卡下仍是「AI 和自动回复稍后按需开启。」护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 8 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到步骤「连接微信」→ 看到连接卡「连接你的微信」或「微信已连接」→ 没有「先连接你的微信」→ 卡下「AI 和自动回复稍后按需开启。」
- Next: 首次引导还要再来：总分 6.5，从未到过 8.0。圈主动词——底栏「连上微信后才能继续」仍和连接卡、「下一步」抢下一步。

## Cycle 59 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 5.8（主动词 7.0 / 空气 5.2 / 短句 6.2 / 物理 4.5 / 状态戏 6.5 / 稀疏 4.7 / 回执 6.0）
- Debt picked: 页头品牌是系统 headline，下面再铺青玉编号圆点，「连接微信」和「选择关注」像第二套步骤奖章。
- After: 总分 6.2（主动词 7.2 / 空气 7.2 / 短句 6.2 / 物理 4.5 / 状态戏 6.5 / 稀疏 4.9 / 回执 6.0）
- Changed: WeChatHUD 和工作台步骤「连接微信 · 选择关注」同一行。没有青玉圆点。青玉仍只在品牌标和连接卡。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 8 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到 WeChatHUD 和「连接微信 · 选择关注」同一行 → 没有青玉编号圆点 → 「连接微信」是当前步。
- Next: 首次引导还要再来：总分 6.2，从未到过 8.0。圈短句——底栏「连上微信后才能继续」仍和页题抢话。

## Cycle 58 — 2026-09-14 — 首次引导

- Surface: 首次引导
- Files: `Sources/WeChatHUD/Views/OnboardingView.swift`、`Tests/WeChatHUDTests/OnboardingStepContractTests.swift`
- Before: 总分 5.4（主动词 5.0 / 空气 5.0 / 短句 6.0 / 物理 4.5 / 状态戏 6.5 / 稀疏 4.5 / 回执 6.0）
- Debt picked: 第一步用三步编号和笔记本讲了一遍连接，真正可按的连接卡被压在下面。
- After: 总分 5.8（主动词 7.0 / 空气 5.2 / 短句 6.2 / 物理 4.5 / 状态戏 6.5 / 稀疏 4.7 / 回执 6.0）
- Changed: 第一步是「先连接你的微信」和连接卡。没有「在这台 Mac 上登录微信」，也没有「等待连接」。一句「AI 和自动回复稍后按需开启。」留在卡下。未重开 AI 页。护栏未改。
- Verified: `swift test --filter OnboardingStepContractTests` 7 个用例全绿；`swift build -c release`。走查：开首次引导 → 看到「先连接你的微信」→ 看到连接卡，没有「在这台 Mac 上登录微信」、没有「等待连接」→ 卡下看到「AI 和自动回复稍后按需开启。」
- Next: 首次引导还要再来：总分 5.8，从未到过 8.0。圈空气——页头品牌仍是系统 headline，步骤点仍是系统 11 号字。

## Cycle 57 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 9.0）
- Debt picked: 「选择要连接的微信账号」是系统边框行，按下没有缩回。
- After: 总分 8.2（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.6 / 状态戏 8.0 / 稀疏 8.5 / 回执 9.0）
- Changed: 账号行是安静可按的次级，按下缩回。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 55 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」仍是青玉 → 按下「更换微信账号」→「继续更换」→ 看到「选择要连接的微信账号」→ 按下账号行缩回。
- Next: 连续两刀升幅都 < 0.3，且本页已到过 8.0。换到首次引导。本页保持 in-progress：准备密钥时「取消」仍是系统链接。

## Cycle 56 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.0）
- Debt picked: 改轮询后的回执埋在目录表单里，还说「高级连接设置将在助手重新打开后应用。」
- After: 总分 8.1（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 9.0）
- Changed: 改「轮询间隔」后，连接卡下面出现「下次打开助手后生效。」青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 54 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」→ 打开「高级连接设置」→ 打开「库路径与同步」→ 改「轮询间隔」→ 连接卡下看到「下次打开助手后生效。」
- Next: 微信连接还要再来：总分 8.1，未到 8.5。圈物理——准备密钥时「取消」仍是系统链接。

## Cycle 55 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift`、`Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.0 / 回执 8.0）
- Debt picked: 展开「库路径与同步」同时铺开轮询间隔和诊断墙。
- After: 总分 8.0（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 8.5 / 回执 8.0）
- Changed: 打开「库路径与同步」先看到「轮询间隔」。诊断概况再收一层。青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 53 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」→ 打开「高级连接设置」→ 打开「库路径与同步」→ 看到「轮询间隔」，没有「复制诊断概况」→ 打开「诊断概况」→ 看到「复制诊断概况」。
- Next: 微信连接还要再来：总分刚到 8.0，未到 8.5。圈物理——准备密钥时「取消」仍是系统链接。

## Cycle 54 — 2026-09-14 — 微信连接

- Surface: 微信连接
- Files: `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift`、`Tests/WeChatHUDTests/AutopilotCopyConsistencyTests.swift`
- Before: 总分 7.6（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 6.5 / 稀疏 7.0 / 回执 8.0）
- Debt picked: 「开始准备」是系统确认框，准备这一出戏从系统菜单开始。
- After: 总分 7.8（主动词 8.0 / 空气 8.0 / 短句 8.0 / 物理 8.0 / 状态戏 8.0 / 稀疏 7.0 / 回执 8.0）
- Changed: 「需要一次本机准备」是工作台确认。「暂不」按下缩回，「开始准备」是这一出的青玉。页上青玉仍只在「去选对话」。护栏未改。
- Verified: `swift test --filter AutopilotCopyConsistencyTests` 53 个用例全绿；`swift build -c release`。走查：开微信连接 → 看到「去选对话」→ 未连接时点连接主按钮 → 看到「需要一次本机准备」→ 按下「暂不」缩回并关掉框 → 「开始准备」仍是青玉。
- Next: 微信连接还要再来：主动词/空气/短句都 ≥ 8，圈稀疏——「库路径与同步」展开仍是轮询间隔和诊断墙。总分未到 8.0，不换表面。

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
