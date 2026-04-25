# 复盘 Tab 设计规范 v0.3.1

**Date**: 2026-04-25
**Status**: Draft (pending GATE 1 re-review after revisions)
**Replaces**: 现有 `日报` tab 中的 `周报` 段（`DailyReportTabView` 的 `weeklyContent` 及其 hierarchy 三段式）

**Changelog v0.3 → v0.3.1（针对 GATE 1 必改项）**：

- §3.3 ⌘Z 撤销栈实现明确为自定义 UndoStore + NSEvent 监听器（不用 Cocoa UndoManager）
- §2.3 菜单栏进度信号引入 MenuBarController 单例做 owner 协调
- §4.0 新增浮窗高度预算与溢出策略
- §4.2 时间轴渲染明确用 SwiftUI List + .id + ScrollViewReader
- §5 schema migration 改为沿用 IF NOT EXISTS + ALTER 模式（不引入 schema_version）
- §5 末尾澄清 HUDStore 是 ObservableObject 不是 actor，新方法标 nonisolated
- §6.1 模块清单加 RetrospectiveConfig / TextSimilarity / UndoStore / MenuBarController
- §6.2 跨 chat 并发明确为 TaskGroup maxConcurrent=4 + 总超时 30 分钟
- §6.2 step 7 carry-forward dedupe 改为 Jaccard / msg_ids 重叠 / involved+deadline 三条件
- §6.5 新增任务持久化与崩溃恢复机制
- §6.6 新增渐进显示推送机制（NotificationCenter + RetrospectiveLiveStore）
- §6.7 新增 RedBannerDetector 算法
- §7.2 时间字段统一 unix epoch
- §8.1.5 新增 ai_data_ledger BEGIN…COMMIT 批写策略
- §9.1 ReportMode.weekly 删除前必须 grep 全仓
- §9.2 文件清单细化 + 行数预算 + SwiftUI 状态注入路径
- §10 测试列表扩充（UndoStore / TextSimilarity / Codex / 渐进显示通知顺序 / 崩溃恢复）

---

## 1. 功能定位

替换现有固定 7 天周报。让用户复盘**指定时间范围内**"我都做了什么、有什么待办"，主要服务两个场景：

- **周五下午写周报** —— 把 AI 抽取的内容快速编辑成可贴飞书/Notion 的 Markdown
- **周一早上看上周遗留** —— 持久化待办跨周延续，加红 banner 主动催"承诺过但未动"的事

不替换现有 `日报` 的 daily 模式，仅替换其 weekly 段。

---

## 2. 容器形态

**采用 F2：浮窗 tab 显示概要 + 独立窗口显示完整内容 + 菜单栏 icon 显示长任务进度。**

### 2.1 浮窗 tab（420×520）— 一屏判断

只放最高密度的判断信号：

- 紧凑范围切换（3 个按钮）
- 红 banner（主动催办）
- AI 总结块（Top 3 + Risk + 漏掉）
- "AI 不确定" 卡片栈（≤3 张固定平铺）
- ⤢ 弹独立窗口按钮 + 复制 MD 按钮

**不放**：完整 24 条 highlights / 12 条 todos / 数据账本入口 / 群筛管理 / 时间轴密度行。

### 2.2 独立窗口（800×900，可缩放）— thinking work

通过浮窗 tab 顶部 ⤢ 按钮启动 `RetrospectiveWindow`：

- 完整时间轴密度行（重点 + 待办合并展示，按时间倒序）
- 待办四态操作 + 撤销栈
- 跨周延续可视化（越久越红越顶）
- 完整范围切换器（含自定义日期）
- 数据账本 + 群筛管理 入口（也可在 ⌘, Preferences 进入）

不受浮窗 hover-dismiss 约束。可常驻、可后台、可截图、可拖动。

### 2.3 菜单栏 icon 进度信号

长任务（重新生成）启动后：

- compact bar 不再承担进度——它太窄
- 菜单栏 NSStatusItem 切换为旋转进度环（参考 Bartender / CleanShot）
- 完成时发系统通知 "复盘已就绪 · [查看]"
- 点通知或点菜单栏 icon → 唤起独立窗口（如已开则置顶；未开则打开）
- 失败时 icon 变红 + tooltip 显示失败摘要

**菜单栏 owner 协调（关键）**：

现有 AppDelegate.setupMenuBarItem 已经在用 `statusItem.button.title` 跑 ChatMonitor 的 unread badge。复盘任务进度信号必须**通过单一 owner 协调**：

- 引入 `MenuBarController` 单例（`@MainActor`），是 NSStatusItem.button 唯一的写入方
- AppDelegate 不再直接更新 statusItem，改为发布一个 `unreadCount` 属性给 MenuBarController
- ChatMonitor unread → MenuBarController.unreadCount; RetrospectiveJob progress → MenuBarController.jobState
- MenuBarController 内部按优先级渲染：jobState != idle → 进度环 / 红 X；否则 → unread badge
- 任务完成后切回 unread badge 显示（即使进度环是临时态）
- 进度环用 `NSImage` 系列帧（5 帧 8°旋转 SF Symbol `arrow.triangle.2.circlepath`）通过 timer 切换，避免 SwiftUI ProgressView snapshot 性能开销

---

## 3. 用户流程

### 3.1 进入 tab（浮窗）

1. 切到 `复盘` tab → load 缓存（命中显示，不命中显示空白态 "[点击生成本周复盘 ↻]"）
2. 默认范围 = `自上次复盘`（基线 = 上次成功生成的 `range_end` 时间戳，存 `review_runs.generated_at`）
3. 顶栏简化为 3 个按钮：`[自上次复盘●] [本周] [自定义…]`
4. 范围切换 = **instant filter for cache**（仅展示该范围已有缓存的内容；如无缓存显示"该范围无缓存，点击生成 ↻"）
5. 顶部右侧持久按钮：`[重新生成 ↻]` `[⤢ 完整窗口]` `[复制 MD]`

### 3.2 触发重新生成

1. 点击 `[重新生成 ↻]` → 弹 macOS 原生 `NSAlert`（非自定义 toast）：
   ```
   将分析 18 个对话 ≈ 3200 条消息
   预计 90 秒 / ~15k token
   隐私：本地脱敏已开 · 将向 OpenAI 发送代号化文本

   [取消]  [开始]
   ```
2. 用户确认 → 任务进 `RetrospectiveJob` 队列（actor），菜单栏 icon 进入进度态
3. 浮窗可正常 hover/移开，任务不受影响
4. 渐进显示：每个对话分析完即写入 `review_highlights` / `review_todos`，独立窗口 reactive 追加；浮窗不实时变化（避免 hover 视图抖动），等任务完成后下次 hover 再 refresh
5. 完成时菜单栏 icon → 通知 + dot；浮窗下次打开顶部金条提示 "新复盘已生成于 16:47 · [查看新版本] [保留旧版]"

### 3.3 待办四态操作

每个待办行有四个按钮 `[完成 1] [推迟下周 2] [不是我的事 3] [转给别人 4]`（数字为聚焦时键盘快捷键，仅独立窗口；浮窗里无此操作）。

操作后：

- 该行从主列表移除（status 转换 + 写 undo_stack 一行）
- 底部 6 秒 toast `已标记为「不是你的事」 · [撤销 ⌘Z]`
- 「已处理待办」归档视图（30 天保留），可手动回滚

**⌘Z 撤销栈实现**（不依赖 Cocoa UndoManager）：

- 自实现 `UndoStore` actor，内存里持有当前 user-action 顺序队列 + DB 持久化备份
- 撤销范围 = 30 分钟（写 `undo_stack.ts < now-1800 → 自动归档清理`）
- ⌘Z 触发：通过 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 在独立窗口 / 浮窗 tab 各装一个监听器，识别 ⌘Z 后调用 `UndoStore.popLatest(in: .retrospective)`
- 监听器 scope 严格限定为复盘相关 view，不污染其他 tab 的 ⌘Z 行为
- 选择不用 Cocoa UndoManager：UndoManager 是 per-responder 且会随 keyWindow 切换失效，跨独立窗口 + 浮窗 tab 共享会乱
- payload_before / payload_after 存 JSON snapshot（review_todos 行的整体），撤销 = 反向 update

### 3.4 红 banner 反驳路径

```
⚠ 你 6 天前对张总说周五前给方案,至今未在群里提及
   [其实我回过 ▾]  [AI 弄错了]  [先别提醒 24h]
```

- **其实我回过** → 弹小输入框，用户贴一句话或 message_id；写 `red_banner_dismissals` + 影响后续承诺判断（同 chat 内同 keyword 的承诺降权）
- **AI 弄错了** → 该承诺标 `dismissed_by_user`，同 pattern 在本会话降权
- **先别提醒 24h** → snooze 24 小时
- 反馈量化进数据账本: "本周纠正 AI N 次"

---

## 4. UI 详细设计

### 4.0 浮窗高度预算与溢出策略

420×520 浮窗里，§4.1 元素占高估算（包含 padding）：

| 段 | 高度 |
|---|---|
| 顶栏（3 范围按钮 + 3 操作 icon） | 28pt |
| 红 banner（含反驳路径行） | 52pt |
| AI 总结块（5 行 × 36pt 平均） | ~180pt |
| AI 不确定卡片栈（≤3 张 × 80pt） | ~240pt（最坏） |
| 隐私 disclosure（折叠态） | 16pt |
| 上下 padding + 分隔线 | ~24pt |
| **静态总计（最坏）** | **~540pt** |

超出 520pt 上限。规则：

- AI 不确定卡片栈 **超过 1 张时启用纵向滚动**（卡片栈高度上限 = 剩余空间 - 16pt 安全 padding）
- 红 banner 超过 1 条时合并为 `⚠ 你有 3 件承诺未跟进 [展开]`，展开后显示 top 1，剩余通过 ⤢ 独立窗口看
- AI 总结块固定 5 行；如某行内容长，按 ellipsis 截断 + chip 点击看完整
- 永远不滚整个 tab——溢出由各段内部处理；保证用户始终能看到顶栏 + 红 banner + AI 总结至少 3 行

### 4.1 浮窗 tab 概要视图（420×520）

```
┌────────────────────────────────────────────────┐
│ [自上次复盘●] [本周] [自定义…]    [↻] [⤢] [📋]│ 顶栏 28pt
├────────────────────────────────────────────────┤
│ ⚠ 你 6 天前对张总说周五前给方案,至今未在群里提及│ 红 banner ~52pt
│   [其实我回过 ▾] [AI 弄错了] [先别提醒]        │
├────────────────────────────────────────────────┤
│ AI 总结                                         │
│  • 决定 v2 周一上线,砍掉地图模块 [3 条原话]    │
│    └ 上级 · AI项目群早会 · 04-22                │
│  • ...[3 条原话]                                │ 5 行,每行 ~36pt
│  • ...[2 条原话]                                │
│  ⚡ 跟王总的预算讨论一直没收尾 [4 条原话]       │
│  💡 老张主动提了离职,你只回了"加油"[1 条原话] [☆]│ ☆=标记为待跟进
├────────────────────────────────────────────────┤
│ ❓ AI 不确定,请你判断 (3)                       │
│ ┌──────────────────────────────────────────┐  │
│ │ 「这个我跟一下」 — 你/王总?  [是我][是他][跳]│ │ 卡片栈
│ │   原话: ...                                 │ │ 平铺 ~80pt × 3
│ └──────────────────────────────────────────┘  │
├────────────────────────────────────────────────┤
│ 🔒 隐私与范围 ›                                 │ 折叠 disclosure 16pt
└────────────────────────────────────────────────┘
```

**关键设计决策：**
- 不显示完整 24 条 highlights —— 这些放独立窗口
- "📋 复制 MD" 按钮在顶栏，按钮 icon-only（hover tooltip "复制 Markdown 周报"）
- ⤢ 按钮 = SF Symbol `arrow.up.left.and.arrow.down.right` 风格 = "弹出"
- 数据流向折成 `🔒 隐私与范围 ›` disclosure，默认折叠；展开显示 KB 数 + 三个二级入口 hint
- AI 总结的"💡 容易漏" 行尾的 ☆ = 一键创建 `ReviewTodo` (direction=mine, status=pending, content=该行 summary)

### 4.2 独立窗口完整视图（800×900）

```
┌──────────────────────────────────────────────────────────────────┐
│ 复盘 · 2026-04-19 ~ 04-25                              [⌘W 关闭]│
├──────────────────────────────────────────────────────────────────┤
│ 范围: [自上次复盘●][今日][本周][上周][本月][自定义…]            │
│ 上次生成 16:23 · 数据已新增 12 条 · [重新生成 ↻] [复制 MD]      │
├──────────────────────────────────────────────────────────────────┤
│ ⚠ 红 banner (与浮窗同)                                           │
├──────────────────────────────────────────────────────────────────┤
│ AI 总结 (与浮窗同 5 行 + 证据 chip)                              │
├──────────────────────────────────────────────────────────────────┤
│ ❓ AI 不确定 (3) — 卡片栈                                        │
├──────────────────────────────────────────────────────────────────┤
│ 时间轴 ▼  排序: [按时间⏷] [按关系] [仅待办] [仅重点]             │
│                                                                   │
│ ▌04-23  上级 · 张总 · AI项目群早会          ⚠ 决议              │
│ │       决定 v2 周一上线,砍掉地图模块                            │
│ │       涉及: 张总, 老王         [3 条原话 ›]    [☆ 标记为待办] │
│ ├─                                                                │
│ ▌04-23  上级 · 张总 · AI项目群早会          📌 待办 我承诺      │
│ │       周五前提交修订版 PRD                                     │
│ │       截止: 4-25  ·  已延续 0 周                               │
│ │       [完成 1] [推迟 2] [不是我的事 3] [转给别人 4]            │
│ ├─                                                                │
│ ▌04-22  平级 · 老王 · 产品小群              💬 讨论              │
│ │       预算讨论无结论 · 已挂 4 天                                │
│ │       涉及: 老王, 财务部                       [4 条原话 ›]    │
│ ├─                                                                │
│ ▌04-21  下级 · 小李 · 私聊                  📌 待办 已延续 3 周 ⚠│ 越久越红
│ │       帮忙看下 API 文档                                         │
│ │       [完成 1] [推迟 2] [建议归档?] [转给别人 4]               │ 4 周触发归档建议
│                                                                   │
│ ─── ⚠ 2 个对话分析失败 [群A][群B]  [重试]  ──────────             │
└──────────────────────────────────────────────────────────────────┘
```

**关键设计决策：**

- **D3 时间轴密度行替代表格**——左侧 2pt 色条载关系语义（上级橙 `#F59E0B` / 平级 accent 蓝 / 下级中性灰 / 客户红 / 私聊朋友透明）
- 每行 3 段：第一段 elem (日期 / 关系 / 来源 / 类型徽标)；第二段内容；第三段 actions / 元数据
- 重点 + 待办合并展示按时间倒序，徽标区分类型（⚠决议 / 📌待办 / 💬讨论 / ⚡风险）
- 排序器允许"按关系" / "仅待办"等切片
- **D10 已延续可视化**：`已延续 0 周`= 灰，`1 周`= 黄，`2 周`= 橙，`3 周`= 红，`4 周+`= 红 + 自动顶部置顶 + 出现 `[建议归档?]` 替代`[不是我的事]`（`建议归档` 把 `status` 改为 `archived`，移出主视图，可在 Preferences 的"已处理待办归档"页查回）
- 跨周持久 todo 在新周报里**视觉上和当周新发现的一样**，不打"continued"标签污染（标签放在副信息区"已延续 N 周"）

**列表渲染策略（性能必须）**：

- 时间轴用 SwiftUI `List` + `.listStyle(.plain)` + `.scrollContentBackground(.hidden)`，**不要** `VStack` in `ScrollView`（50+ rows 会全量渲染）
- 每行用 `.id(\.id)` 显式标识（review_todos.id 或 review_highlights.id 唯一即可）
- 行内交互按钮（四态 / 撤销）用 `Button(role: .destructive/.cancel)` 时注意 `buttonStyle(.plain)` 防止 List 默认行点击吞掉
- 滚动到指定行通过 `ScrollViewReader` proxy.scrollTo(id:)
- 渐进追加新数据时**不打断用户当前滚动位置**：RetrospectiveLiveStore 在追加 row 后判断 if `currentScrollOffset > 100` then 仅 append silently（顶部出现 "↑ 3 条新内容 [跳到顶部]" 浮提示），else 平滑滚动至顶

### 4.3 证据 chip 设计（D4）

每条 AI 输出（包括总结块和详细行）后挂一个 chip。confidence 阈值定义：

- 高: `confidence >= 0.8` → chip 形如 `[3 条原话]`，白 0.4
- 中: `0.5 <= confidence < 0.8` → chip 偏灰（白 0.3）
- 低: `confidence < 0.5` 或 `direction == "unclear"` → chip 形如 `[?]` 黄角标，**同时该条进 "AI 不确定" 卡片栈，不在主时间轴展示**（独立窗口可勾"显示 AI 不确定项"切换）
- 点击 chip → 浮层显示 source_msg_ids 对应的原话片段（截 80 字 + "查看完整对话 ›")
- 浮层底部固定 `[这条归错人了] [AI 总结的不准]` 反馈按钮

### 4.4 "AI 不确定" 卡片栈（D5）

3 张卡片（最多）平铺，每张：

```
┌──────────────────────────────────────────────────┐
│ 「这个我跟一下」 — 是承诺还是客套?              │
│  原话: 04-23 14:32 张总: "...这个我跟一下"      │
│  上下文: 我前一句问了"谁来对接 v2 上线?"        │
│  [是承诺,加待办] [客套,跳过] [我来判断]         │
└──────────────────────────────────────────────────┘
```

用户处理后该卡片消失，新的不确定项补位（如有）。

如不确定 > 3，独立窗口里全部展示；浮窗只展示 top 3。

---

## 5. 数据模型

落 `~/.wechat-hud/hud.sqlite3`。所有新表纳入 `HUDStore` schema migration。

```sql
-- 每次"重新生成"= 一行(运行中也是一行,先写 status='running' 再分析)
CREATE TABLE review_runs (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    range_start           INTEGER NOT NULL,    -- unix ts
    range_end             INTEGER NOT NULL,
    generated_at          INTEGER NOT NULL,    -- unix ts: started_at on insert, finalized on completion
    summary_top3          TEXT,                -- JSON array of {text, evidence_highlight_ids[]} - null while running
    summary_risk          TEXT,                -- JSON {text, evidence_highlight_ids[]}
    summary_missed        TEXT,                -- JSON {text, evidence_highlight_ids[]}
    chat_count            INTEGER NOT NULL,    -- target count
    progress_chat_count   INTEGER NOT NULL DEFAULT 0,   -- 已完成数,UI 显示 8/18
    msg_count             INTEGER NOT NULL DEFAULT 0,
    failed_chats          TEXT,                -- JSON array of chat names
    status                TEXT NOT NULL        -- 'running' / 'completed' / 'partial' / 'failed'
);

-- 持久化待办(跨周延续核心)
CREATE TABLE review_todos (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    origin_run_id            INTEGER NOT NULL REFERENCES review_runs(id),
    last_run_id              INTEGER NOT NULL REFERENCES review_runs(id),
    content                  TEXT NOT NULL,
    deadline                 INTEGER,                  -- nullable
    direction                TEXT NOT NULL,            -- 'mine' / 'theirs' / 'unclear'
    involved                 TEXT,                     -- JSON array of names
    source_chat_username     TEXT NOT NULL,
    source_chat_name         TEXT NOT NULL,
    source_msg_ids           TEXT NOT NULL,            -- JSON array
    confidence               REAL NOT NULL,            -- 0.0-1.0
    status                   TEXT NOT NULL,            -- 'pending' / 'completed' / 'snoozed' / 'not_mine' / 'delegated' / 'archived'
    created_at               INTEGER NOT NULL,
    completed_at             INTEGER,
    snoozed_to               INTEGER,
    delegated_to             TEXT,
    carry_count              INTEGER NOT NULL DEFAULT 0,  -- 跨多少次 review_run 还在 pending
    last_user_action_at      INTEGER                       -- for ⌘Z 撤销栈
);

-- 重点事项(每个 run 重新抽,不持久化跨 run)
CREATE TABLE review_highlights (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id                   INTEGER NOT NULL REFERENCES review_runs(id),
    date                     INTEGER NOT NULL,         -- unix ts of source message
    summary                  TEXT NOT NULL,
    quoted_snippet           TEXT,                     -- 原话片段 ≤120 字
    involved                 TEXT,                     -- JSON array
    source_chat_username     TEXT NOT NULL,
    source_chat_name         TEXT NOT NULL,
    relation                 TEXT,                     -- 'superior' / 'peer' / 'subordinate' / 'client' / 'friend' / 'unknown'
    source_msg_ids           TEXT NOT NULL,
    confidence               REAL NOT NULL,
    flagged_uncertain        INTEGER NOT NULL DEFAULT 0  -- 是否进 "AI 不确定" 区
);

-- 群筛三态记忆
CREATE TABLE group_scope_policy (
    chat_username    TEXT PRIMARY KEY,
    decision         TEXT NOT NULL,            -- 'include' / 'exclude' / 'ask_each_time'
    source           TEXT NOT NULL,            -- 'ai' / 'user'
    decided_at       INTEGER NOT NULL,
    sample_hash      TEXT,                     -- hash of last screening sample, for drift detection
    user_authorized  INTEGER NOT NULL DEFAULT 0  -- 用户首次启用某群的"我已获授权"勾选
);

-- AI 调用账本
CREATE TABLE ai_data_ledger (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL,
    provider        TEXT NOT NULL,            -- 'openai' / 'codex' / 'ollama' / ...
    model           TEXT NOT NULL,
    purpose         TEXT NOT NULL,            -- 'group_screen' / 'chat_analysis' / 'summary_synth'
    chat_count      INTEGER,
    msg_count       INTEGER,
    byte_count      INTEGER NOT NULL,
    token_in        INTEGER,
    token_out       INTEGER,
    redacted        INTEGER NOT NULL DEFAULT 1   -- 是否经过本地脱敏
);

-- 红 banner 反馈
CREATE TABLE red_banner_dismissals (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    todo_id         INTEGER NOT NULL REFERENCES review_todos(id),
    action          TEXT NOT NULL,            -- 'replied_externally' / 'ai_wrong' / 'snoozed'
    reason_text     TEXT,                     -- 用户填的反馈
    snoozed_to      INTEGER,
    created_at      INTEGER NOT NULL
);

-- 用户撤销栈(30 分钟保留)
CREATE TABLE undo_stack (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL,
    target_table    TEXT NOT NULL,            -- 'review_todos' 等
    target_id       INTEGER NOT NULL,
    operation       TEXT NOT NULL,            -- 'status_change' 等
    payload_before  TEXT NOT NULL,            -- JSON 原状态
    payload_after   TEXT NOT NULL
);
```

**迁移机制**（沿用现有 HUDStore 模式，**不引入 schema_version 表**）：

- 所有新建表使用 `CREATE TABLE IF NOT EXISTS`，幂等
- 后续若需改列结构，使用 `try? db.exec("ALTER TABLE ... ADD COLUMN ...")` 模式（与 HUDStore.swift 现有 ALTER 调用一致），失败静默忽略（旧版列已存在）
- 不删除任何旧表（包括 DiscussionItem 相关历史表）
- HUDStore 启动时调用新增的 `migrateRetrospective()` private 方法，按建表顺序跑 7 次 IF NOT EXISTS
- 索引一并 IF NOT EXISTS：
  ```sql
  CREATE INDEX IF NOT EXISTS idx_review_todos_status_run ON review_todos(status, last_run_id);
  CREATE INDEX IF NOT EXISTS idx_review_highlights_run ON review_highlights(run_id);
  CREATE INDEX IF NOT EXISTS idx_ai_data_ledger_ts ON ai_data_ledger(ts);
  CREATE INDEX IF NOT EXISTS idx_undo_stack_ts ON undo_stack(ts);
  ```

**HUDStore 类型契约**：HUDStore 是 `final class : ObservableObject`，**不是 actor**，依靠 SQLITE_OPEN_FULLMUTEX 保证线程安全。所有新增的 `HUDStore+Retrospective.swift` 方法必须声明为 `nonisolated` 同步函数（与现有 ChatAnalyzer 跨 actor 调用 `store.writeAIAudit` 模式一致），不引入 async。actors（RetrospectiveJob 等）跨 isolation 直接同步调用即可。

---

## 6. 后端管线

### 6.1 模块划分

```
Services/Retrospective/
├── RetrospectiveJob.swift            — actor 队列,接收"重新生成"请求
├── RetrospectiveConfig.swift         — 常量(并发数 / timeout / 上限)
├── ScopeResolver.swift               — 解析时间范围 + 候选对话(白名单 ∩ 范围内有消息)
├── GroupScreener.swift               — 候选群 → AI 二次筛 → 写 group_scope_policy
├── RetrospectiveAnalyzer.swift       — 对单个对话跑深度分析,返回 highlights+todos
├── SummarySynthesizer.swift          — 所有对话结果合 → 生成 Top3+Risk+Missed
├── ReviewTodoManager.swift           — 待办持久化 + 跨周延续 + 状态机
├── UndoStore.swift                   — 自定义撤销栈服务(非 Cocoa UndoManager)
├── DataLedger.swift                  — 每次 AI 调用记账
├── Redactor.swift                    — 本地脱敏管道
├── TextSimilarity.swift              — 纯函数 Jaccard / 字面距离
└── RedBannerDetector.swift           — 检测"承诺过但未动",生成红 banner

Sources/WeChatHUD/App/
└── MenuBarController.swift           — 单例,owns NSStatusItem.button.image
                                        协调 ChatMonitor unread badge ↔ RetrospectiveJob 进度
```

### 6.2 RetrospectiveJob 流程

```
1. ScopeResolver.resolve(range) → 候选对话列表 (whitelist ∩ has messages in range)
2. GroupScreener.screen(candidates) → 决定 include/exclude(查 group_scope_policy 缓存,
   只对新群和 sample drift 大的群跑 AI)
3. 写 ai_data_ledger 一行 (purpose=group_screen)
4. 对 included 中的每个 chat:
   a. Redactor.redact(messages) → 脱敏后消息
   b. ChatAnalyzer.analyzeForRetrospective(redacted_msgs) → highlights + todos
   c. 解码代号回真实人名 (用 Redactor.reverseMap)
   d. 写 ai_data_ledger 一行 (purpose=chat_analysis)
   e. 写 review_highlights / review_todos 行(reactive 推送独立窗口刷新)
5. SummarySynthesizer.synthesize(all_highlights, all_todos) → Top3+Risk+Missed
6. 写 review_runs 一行
7. ReviewTodoManager.carryForward(prev_run_id, new_run_id):
   a. 查 review_todos WHERE status='pending' AND last_run_id < new_run_id
   b. 对每条 carried 的 todo,检查本 run 新抽出的 todos 是否包含 dedupe 命中。**dedupe 算法（不依赖 embedding）**:
      - 命中条件 1: `source_msg_ids` 集合有任意重叠
      - 命中条件 2: 同 `source_chat_username` AND 内容字面 Jaccard 相似度 > 0.6 (中文 bigram 切分,英文 word 切分,去停用词)
      - 命中条件 3: 同 `source_chat_username` AND `involved` 集合 ≥ 1 个共同人 AND deadline 同日(精确到 day)
      - 任一条件触发即视为 dedupe 命中
   c. 命中 → 把新抽出的同类 todo 丢弃,把现有 todo 的 last_run_id 更新为 new_run_id, carry_count += 1
   d. 未命中 (上 run 已 pending 但本 run 没再被抽出) → 直接 last_run_id = new_run_id, carry_count += 1
   e. 新抽出但无 carry-forward 命中 → 真正新发现的 todo,直接插入

   **Jaccard 实现细节**: `Sources/WeChatHUD/Services/Retrospective/TextSimilarity.swift` 提供 `jaccardCJK(a:b:) -> Double`,纯函数,可单测。中文 bigram 通过 String 滑动窗口实现,不引入第三方依赖。
8. RedBannerDetector.detect() → 生成红 banner 候选
9. 菜单栏 icon → 完成态 + 系统通知
```

### 6.3 本地脱敏管道

`Redactor` 维护一个 per-run 的双向 map：

- 人名 → 代号 (A1, A2, ...)
  - **codename key** = `senderUsername` 优先（微信 wxid_xxx 唯一），fallback 到 `normalize(displayName)`
  - 同一 run 内同一 username 永远映同一代号；多个群里"张总" 如果 wxid 相同 → 同代号；wxid 不同 → 不同代号（这是正确行为）
- 手机号 → `[手机]`
- 邮箱 → `[邮箱]`
- 金额 (`¥xxx` / `xxx 万` / `xxx K`) → `[金额]`
- 公司名 (从 RelationshipProfile 读) → `[公司]`

发 AI 之前替换；接回 AI 输出后用 reverseMap 还原。脱敏映射表**仅内存,不落盘**。
AI 调用失败 / parse 失败时 reverseMap 也要兜底走一遍（避免代号泄漏到错误日志），失败原因写 ai_data_ledger.purpose='chat_analysis_failed' 一行。

用户可关闭脱敏（Preferences），关闭时 ai_data_ledger 的 `redacted=0`。

### 6.4 并发、超时与失败兜底

**跨 chat 并发**：

- §6.2 step 4 用 `withThrowingTaskGroup` 跑，并发上限 4（写在 `RetrospectiveConfig.maxConcurrentChats`,可在 Preferences 调）
- 单 chat AI 调用 timeout = 60s，retry 一次（同 v0.1 ChatAnalyzer 模式）
- 整个 RetrospectiveJob 总超时 30 分钟（写在 `RetrospectiveConfig.totalTimeout`），到点未完成的 chats 标 failed
- AIService 内部已有 rate limit 队列，不需要在 RetrospectiveJob 层再做

**失败处理**：

- per-chat 失败 → 该 chat 名追加到 `review_runs.failed_chats`（JSON array），不影响其他 chat
- `review_runs.status` 取值：`running` / `completed` / `partial` / `failed`
- 全部 chats 都失败 → status='failed'；部分失败 → 'partial'；全成功 → 'completed'

### 6.5 任务持久化与崩溃恢复

**RetrospectiveJob 必须先写 review_runs 行 status='running'**，再开始分析（不是最后才写）。这样：

- App 退出 / 崩溃后，下次启动时 HUDStore.swift 启动钩子扫一遍 `SELECT * FROM review_runs WHERE status='running' AND generated_at < (now - 35 minutes)`
- 残留 'running' 行 → 标 status='failed', failed_chats 加 `["__app_exited_during_run__"]`
- 用户进复盘 tab 看到旧 cache（最后一个 status='completed' 的 run），顶部金条提示"上次生成中断，可重新生成"
- review_runs 增量字段：`progress_chat_count INTEGER NOT NULL DEFAULT 0`,每个 chat 完成后 +1，让 UI 可显示 "8/18 已完成"

### 6.6 渐进显示推送机制

**SQLite 没有 push，自建机制**：

```swift
extension Notification.Name {
    static let retrospectiveLiveUpdate = Notification.Name("retrospectiveLiveUpdate")
}

// payload: ["runId": Int, "kind": "highlight" | "todo" | "progress" | "completed"]
```

- HUDStore.writeReviewHighlight / writeReviewTodo / updateReviewRunProgress 写完后立即 `NotificationCenter.default.post`
- 独立窗口的 `RetrospectiveLiveStore: ObservableObject`(@MainActor) 订阅该 Notification，命中本 runId 就重新 query 自己持有的 `@Published var liveRows: [TimelineRow]`
- 浮窗 tab 不订阅 live updates（避免 hover 中视图抖动），只在每次 `onAppear` 时刷新一次
- 完成时 post 一条 `kind: "completed"` 通知，浮窗 tab 下次打开看到顶部金条"新版本已生成"

### 6.7 RedBannerDetector 算法

**目标**：找出"用户公开承诺过、deadline 到了或临近、但用户没在原对话里 follow up"的事项。每个 RetrospectiveJob 完成后跑一次。

```swift
func detect() -> [RedBannerCandidate] {
    let now = Date().unix
    let recent = now - 14*86400  // 只看 14 天内的承诺

    // 1. 候选 todos: 我承诺的 + pending + deadline 已过或 24h 内到期
    let candidates = store.queryReviewTodos(
        direction: .mine,
        status: .pending,
        deadlineBetween: nil...(now + 86400),
        createdAfter: recent
    )

    var banners: [RedBannerCandidate] = []
    for todo in candidates {
        // 2. 跳过已被 dismiss 过的
        if store.hasRedBannerDismissal(todoId: todo.id, validForHours: 24) { continue }

        // 3. 在 source_chat_username 里找 todo.created_at 之后的我方消息
        let mySinceCommit = chatMonitor.queryMyMessages(
            chatUsername: todo.sourceChatUsername,
            since: todo.createdAt,
            until: now
        )

        // 4. 任意一条我方消息内容 Jaccard(content, todo.content) > 0.3 → 视作已 follow up,跳过
        let followedUp = mySinceCommit.contains { msg in
            TextSimilarity.jaccardCJK(msg.text, todo.content) > 0.3
        }
        if followedUp { continue }

        // 5. 也允许 involved 中的人在 source_chat 里主动提及该话题(他们 ping 我)→ 不算我失约
        // (留 v0.4 视情况加)

        banners.append(RedBannerCandidate(
            todoId: todo.id,
            content: todo.content,
            deadline: todo.deadline,
            counterpart: todo.involved.first,
            chatName: todo.sourceChatName,
            daysSinceCommit: (now - todo.createdAt) / 86400
        ))
    }

    // 6. 按 daysSinceCommit DESC 排序,只保留 top 3 (浮窗只放 1 条 banner,但独立窗口可 surface 全部)
    return banners.sorted { $0.daysSinceCommit > $1.daysSinceCommit }
}
```

**dismissal 机制**：用户点 `[其实我回过]` / `[AI 弄错了]` / `[先别提醒 24h]` 任一 → 写 `red_banner_dismissals` 一行；下次 detect 时 24h 内同 todoId 不再 surface。

**精度调优记录**：dismissal 累计 ≥ 3 次（同类 pattern）后，自动给该 todo 标 `confidence -= 0.2`，下个 run 可能落到 "AI 不确定" 区让用户根本判断该 todo 还要不要跟。这是简易的人工反馈学习路径，不需要训练。

---

## 7. AI 接口契约

### 7.1 群筛 prompt (batch)

```
输入: 候选群列表[ {chat_name, sample_messages[20]} ]
输出: JSON [
  { chat_name, decision: "include"/"exclude", confidence: 0-1, reason: 简短说明 }
]
```

仅当 confidence < 0.7 时把 decision 重写为 `ask_each_time`，让用户确认。

### 7.2 单对话深度分析 prompt

时间字段统一用 **unix epoch (Int)**，与 codebase 一致；**不混用 ISO 8601**。

```
输入: chat_name, relation, redacted_messages, my_codename
输出: JSON {
  highlights: [{
    date,                       -- unix epoch (Int)
    summary,                    -- 一句话陈述
    quoted_snippet,             -- 原话片段 ≤120 字
    involved,                   -- 代号数组
    category,                   -- "decision" / "progress" / "discussion" / "risk"
    confidence,                 -- 0-1
    source_msg_ids              -- 来源消息 id 数组
  }],
  todos: [{
    deadline,                   -- unix epoch (Int) 或 null
    content,
    direction,                  -- "mine" / "theirs" / "unclear"
    involved,
    confidence,
    source_msg_ids
  }]
}
```

AI 不返回 todo `status` 字段；系统统一写入 `status=pending`。后续状态变化全部由用户操作驱动（§3.3 四态按钮）或 carry-forward 流程更新。

模型温度 0.2，max_tokens 4096。

### 7.3 总结合成 prompt

```
输入: 全部 highlights + todos 列表 (已脱敏)
输出: JSON {
  top3: [{ text, evidence_highlight_ids: [...] }],
  risk: { text, evidence_highlight_ids: [...] } | null,
  missed: { text, evidence_highlight_ids: [...] } | null
}
```

总结的每条 evidence 必须指向具体 highlight id，前端按这个挂证据 chip。

---

## 8. 隐私与合规

### 8.1 默认行为

- 本地脱敏：默认开启
- 数据账本：默认开启，永久记录直到用户清空
- 第一次启用某群：弹原生 `NSAlert` 让用户勾"我已获群成员授权分析此对话"，存 `group_scope_policy.user_authorized`；未授权的群在 GroupScreener 阶段直接 exclude
- 私聊不需要单独授权（你跟对方的对话你自己有完整权利分析），但脱敏照常

### 8.1.5 ai_data_ledger 写入策略

每次 RetrospectiveJob 会写至少 N+2 行账本（group_screen 1 + 每 chat 1 + summary 1）。**统一用 SQLite 事务包一笔**：

```swift
nonisolated func recordLedgerBatch(_ entries: [LedgerEntry]) {
    db.exec("BEGIN TRANSACTION")
    for entry in entries {
        // INSERT INTO ai_data_ledger ...
    }
    db.exec("COMMIT")
}
```

避免 WAL 频繁 fsync。中途 chat 失败的也写一行 `purpose='chat_analysis_failed'` 入同一批次。

### 8.2 数据流向 disclosure

浮窗 tab 底部折叠 `🔒 隐私与范围 ›`，展开显示：

```
本次将向 OpenAI (gpt-5.4) 发送:
  18 个对话 · 3200 条消息 · ≈ 280 KB
  所有人名已替换为代号 · 金额/手机/邮箱已遮蔽
  [脱敏开关 ●]  [数据账本]  [群筛管理]  [Preferences ⌘,]
```

### 8.3 数据账本页

独立窗口 + Preferences 都能进。展示最近 90 天 AI 调用：

```
日期 / Provider / Model / Purpose / 对话数 / 消息数 / 字节数 / 是否脱敏
[导出 CSV]  [清空 30 天前]  [清空全部]
```

### 8.4 用户配置 Ollama 时

- ai_data_ledger 仍记账，但 provider = `ollama`
- 数据流向 banner 文案变 "本次将由本地 Ollama 处理 (不出网)"
- 脱敏开关默认仍为开（即使本地，让代号化的好处持续）

---

## 9. 替换/迁移现有功能

### 9.1 删除的代码

- `DailyReportTabView.swift` 里：
  - `weeklyContent` 视图段
  - `weeklyHierarchyTasks`, `itemsFromSuperior`, `itemsToSubordinate`, `itemsWithPeers`, `weeklyItems`
  - `weeklyOverview`, `weeklyCommitments`, `weeklyPendingAsks`
  - `exportButton`, `copyWeeklyReport`
  - `ReportMode.weekly` enum case（注意：`ReportMode` 是 internal enum，删除前必须 grep 全仓 + Tests 确认无残留引用，特别是 ChatMonitor / 测试文件）
  - segmented Picker 简化为单一 daily 视图

### 9.2 新增的代码

按 ≤ 800 行/文件 强制约束（见 user 全局 web 规则；Swift 项目同等执行）。每个文件单一职责。

- `Sources/WeChatHUD/Views/Retrospective/`
  - `RetrospectiveTabView.swift` — 浮窗 tab 顶层 (~150 行)
  - `RetrospectiveTabState.swift` — @StateObject 状态 (~80 行)
  - `RetrospectiveWindow.swift` — NSWindow 容器（必须 NSWindow，不复用 NSPanel/FloatingPanel；不进 PanelState.mouseExited 回调链）(~80 行)
  - `RetrospectiveWindowChrome.swift` — 顶栏 + 范围切换 (~120 行)
  - `RetrospectiveTimelineView.swift` — 时间轴 List (~200 行)
  - `RetrospectiveSummarySection.swift` — AI 总结块 (~150 行)
  - `RedBannerView.swift` — 红 banner + 反驳路径 (~120 行)
  - `UncertainCardStackView.swift` — AI 不确定卡片栈 (~150 行)
  - `TimelineRowView.swift` — 单行渲染 (~150 行)
  - `EvidenceChipPopover.swift` — 证据 chip + 反馈按钮 (~100 行)
  - `DataLedgerView.swift` — 数据账本（在 Preferences 复用）(~150 行)
  - `ScopePolicyManagerView.swift` — 群筛管理 (~150 行)
  - `RetrospectiveLiveStore.swift` — @MainActor ObservableObject，订阅 NotificationCenter (~100 行)
- `Sources/WeChatHUD/Services/Retrospective/` — 见 §6.1，每个模块独立文件
- `Sources/WeChatHUD/Data/`
  - `HUDStore+Retrospective.swift` — CRUD（≤ 400 行）
  - migration 函数 `migrateRetrospective()` 加进 HUDStore.init 末尾
- `Sources/WeChatHUD/App/`
  - `MenuBarController.swift` — 见 §2.3
  - `RetrospectiveWindowManager.swift` — NSWindow 单例（show / hide / makeKey）
- `Resources/Prompts/`
  - `retrospective_group_screen_v1.txt`
  - `retrospective_chat_analysis_v1.txt`
  - `retrospective_summary_synth_v1.txt`

**SwiftUI 状态注入路径**（避免散乱）：

- `RetrospectiveJob` 持有为 `ChatMonitor.retrospectiveJob` (`@MainActor ObservableObject`)，与 ChatMonitor 同生命周期
- `RetrospectiveTabView` 通过 `@EnvironmentObject monitor: ChatMonitor` 拿到，再 `monitor.retrospectiveJob` 拿子对象
- `RetrospectiveTabState` 用 `@StateObject` 在 RetrospectiveTabView 里持有，存 UI-only 状态（当前 range 选择、展开/折叠 disclosure、滚动 offset 缓存）
- `RetrospectiveLiveStore` 用 `@StateObject` 在 RetrospectiveWindow 里持有，独立窗口生命周期

### 9.3 Tab 列表更新

`ExtendedTabsView` 把 `日报` tab 之后的"周报"概念彻底拿掉。新 tab 顺序：
`关注 / 待回 / 未读 / 追赶 / 承诺 / 工作台 / 日报 / 复盘 / 洞察`

---

## 10. 测试要求

按 `~/.claude/rules/swift/testing.md` 用 Swift Testing 框架。最低 80% 覆盖率。

**单元测试（必须）：**

- `RedactorTests`:
  - 人名/金额/手机/邮箱替换正确性
  - reverseMap 双向一致
  - 同 run 内同 senderUsername 始终映同代号
  - 多群同名（wxid 不同）映不同代号
  - AI 失败兜底也走 reverseMap，不泄漏代号到日志
- `ScopeResolverTests`: 时间范围解析 + whitelist 过滤 + "自上次复盘" 基线计算
- `ReviewTodoManagerTests`:
  - 四态状态机（pending → completed / snoozed / not_mine / delegated / archived）
  - carry-forward dedupe 三种命中条件覆盖（msg_ids 重叠 / Jaccard / involved+deadline）
  - carry_count 累加
  - 4 周 + 自动归档触发
- `UndoStoreTests`: ⌘Z pop 顺序 / 30 分钟过期清理 / 跨 view scope 隔离
- `TextSimilarityTests`: jaccardCJK 中英文 / 空字符串 / 完全相同 / 完全不相交 / 标点干扰
- `RedBannerDetectorTests`:
  - 承诺过但未动的检测准确性（构造已 follow up vs 未 follow up 两组用例）
  - dismissal 后 24h 内不再触发
  - 同类 pattern 累计 dismissal ≥3 次后 confidence 衰减
- `GroupScreenerTests`: 三态记忆 / sample drift 检测 / 缓存命中 / Codex provider 路径
- `DataLedgerTests`: BEGIN…COMMIT 批写 / 每次 AI 调用记账 / 90 天清理 / CSV 导出 / chat_analysis_failed 行
- `HUDStore+Retrospective`: 全部 CRUD + 7 张表 IF NOT EXISTS 幂等 + ALTER 兼容老库

**集成测试：**

- `RetrospectiveJob` 端到端（mock AIService）：完整流程 → 校验 review_runs/highlights/todos 写入正确
- 单对话失败时 review_runs.failed_chats 正确填充 + 不阻塞其他 chats
- 渐进显示通知 fire 顺序（NotificationCenter 收到的顺序与写入顺序一致）
- App 中途退出后 status='running' 行启动时被标 'failed'
- TaskGroup 并发上限 = 4 严格遵守
- 跨 chat 总超时 30 分钟触发后未完成 chats 标 failed
- Codex provider 不接受 temperature/max_tokens 参数时 prompt 流程不崩溃

**集成测试：**

- `RetrospectiveJob` 端到端：mock AI service → 完整流程 → 校验 review_runs/review_todos 写入正确
- 单对话失败时 review_runs.failed_chats 正确填充 + 不阻塞
- 渐进显示通知 fire 顺序

**UI 测试（可选）：**

- 浮窗 tab 在 cache hit / miss / generating 三态渲染正确
- 独立窗口的 hover-dismiss 隔离（hover 移开窗口不消失）

---

## 11. 已知待权衡（v0.4 候选，本次不做）

以下是评审中提到但**故意未纳入本版**，作为后续迭代候选记录：

- **Reflect 风格的 retro prompts**（"What energized / drained / surprised you" 五题）：超出"周报抽取"定位，需要文本输入框，浮窗装不下
- **AI 总结块的"💡 漏掉" 一键 carry-forward 到 GTD 工具**（如 Things 3 URL scheme）：跨应用集成，先不做
- **跨周 diff 视图**（"上周说要做 X，这周完成度 Y%"）：需要更结构化的目标数据，先把单周流程跑顺
- **菜单栏 icon "本周复盘已就绪" badge 持久化**：暂用系统通知 + 浮窗金条提示，不在 status item 上加数字 badge
- **Markdown 导出模板可配置**：暂硬编码两张表 + 标题格式
- **AI 反馈信号反哺到全局风格学习器**（StyleProfiler）：先孤立运行，避免相互污染

---

## 附录 A: UI 状态机

```
RetrospectiveTabState:
  empty                   — 无任何缓存
  cached_only             — 有缓存,显示
  generating              — 任务在跑(菜单栏 icon 显示进度)
  generating_with_cache   — 任务在跑且有旧缓存(显示旧 + 顶部"新版本生成中")
  ready                   — 任务完成,顶部金条提示新版本

RetrospectiveJobState:
  idle
  resolving_scope
  screening_groups
  analyzing_chats(progress: Int/Total)
  synthesizing_summary
  detecting_red_banner
  completed(run_id)
  failed(error)
  partial(run_id, failed_chats[])
```

## 附录 B: 关键约束回顾

物理：浮窗 420×520，独立窗口 800×900 起步。深色唯一。字号 12/11/10/9pt。

技术：SwiftUI + AppKit；ChatMonitor / HUDStore 已有；AIService 已有(支持 OpenAI/Ollama/Codex)；`FirstMouseHostingView` 包行避免首次点击吞。

数据：所有新表落 hud.sqlite3；schema migration 幂等；脱敏映射 in-memory only。

