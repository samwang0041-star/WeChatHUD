# Frontend Craft Loop — 进度

循环规格：`docs/design/frontend-craft-loop.md`。
一刀一节，新的写在最上面。

## 状态板

| 序 | 表面 | 状态 | 最近总分 | 下一刀提示 |
|---|---|---|---|---|
| 1 | 今天 | done | 8.5 | 设置卡未就绪时仍用系统 accent；留给首次引导那一刀 |
| 2 | 岛·展开收件箱 | in-progress | 7.7 | 展开后的解读卡仍用系统 accent 方块；应收进 IslandInk / 青玉 |
| 3 | 岛·通知横幅 | queued | — | |
| 4 | 岛·紧凑/peek | queued | — | |
| 5 | 待确认回复 | queued | — | |
| 6 | 自动回复设置 | queued | — | |
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
