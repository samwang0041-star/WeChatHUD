# Frontend Craft Loop — 进度

循环规格：`docs/design/frontend-craft-loop.md`。
一刀一节，新的写在最上面。

## 状态板

| 序 | 表面 | 状态 | 最近总分 | 下一刀提示 |
|---|---|---|---|---|
| 1 | 今天 | in-progress | 8.0 | 卡片仍用裸字号、无悬停洗层；右侧「接下来」和连接卡仍在抢视线 |
| 2 | 岛·展开收件箱 | queued | — | |
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

## Cycle 1 — 2026-09-13 — 今天

- Surface: 今天
- Files: `Sources/WeChatHUD/Views/AssistantTodayView.swift`、`Tests/WeChatHUDTests/ProductWorkspaceTests.swift`
- Before: 总分 6.1（主动词 5.5 / 空气 6 / 短句 6.5 / 物理 5.5 / 状态戏 7 / 稀疏 5 / 回执 7）
- Debt picked: 三个同等胶囊加「先处理这些事」让人找不到下一步；改成一句现状，下面只留一条需要回复的列表。
- After: 总分 8.0（主动词 8.5 / 空气 7 / 短句 8.5 / 物理 6.5 / 状态戏 7 / 稀疏 7 / 回执 7.5）
- Changed: 打开今天先看到「现在有 N 件需要回复」。我要做 / 等对方变成安静跳转；没有普通更新时不再出现「全部」。点已处理后，句子和列表一起收。
- Verified: `swift test --filter ProductWorkspaceTests`；`swift test --filter CompanionMotionTests`；`swift test --filter CompanionProductCopyTests`；`swift test --filter IslandStyleTests`；`swift build -c release`。走查：悬停次级跳转有按压缩放；按下「理解上下文与回复」进详情；点已处理出撤销；空列表时状态句仍是「现在没有要回的」，空态说明待办在侧。
- Next: 今天第二刀 — 把消息卡和右侧栏收回 `workspace*` token，补行悬停洗层，让「理解上下文与回复」是卡上唯一强调按钮。

### 改前债（只修了第一条）

1. 主动词被三个胶囊和第二个标题拆散。
2. 消息卡裸 `font(.system)`，字号 11/13/14/16 混用。
3. 卡头 `.buttonStyle(.plain)`，无悬停洗层。
4. 右侧连接卡两个按钮与主列表抢。
5. 设置卡未就绪时正确出现，未动。
