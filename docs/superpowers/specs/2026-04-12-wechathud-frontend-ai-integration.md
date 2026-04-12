# WeChatHUD Frontend AI Integration Design Spec

**Date:** 2026-04-12
**Status:** Approved

## Overview

将 WeChatHUD 已有的 11 个 AI 后端服务全部接入前端 UI，采用渐进式嵌入策略——所有 AI 功能嵌入现有交互层级，不新增面板或窗口状态。

## Tab 结构变更

现有：`关注 | 待回 | 未读`
变更为：`关注 | 待回 | 未读 | 日报`

"日报"tab 承载 AIDailyRetrospector 和 CommitmentTracker 的输出。

## 功能详细设计

### 1. 智能回复（AIReplySuggester）

**位置：** 待回 tab，每条 ReplyDebtRow 内嵌

**交互流程：**
1. 用户点击待回消息行 → 行内向下展开回复区域
2. 展开区域显示 3 条候选回复，每条标注语气（如"正式""友好""简洁"）
3. 用户点击某条候选 → 内容复制到剪贴板
4. 弹出确认对话框："是否打开微信对话框？"
5. 确认后自动打开微信对应对话窗口，将 AI 内容粘贴到输入框
6. 用户自行确认后手动发送

**加载状态：** 展开时显示加载动画（首次需调用 AI），缓存结果避免重复调用。

**UI 结构：**
```
┌─ ReplyDebtRow ─────────────────────────────┐
│ [P0] 林总              3分钟前              │
│  林总: 明天把预算单发给我                    │
│  [@你] [待回复]                              │
├─ 展开区域 ─────────────────────────────────-─┤
│  💬 候选回复                                 │
│  ┌──────────────────────────────────────┐   │
│  │ 正式  好的林总，明天上午发您。         │   │
│  ├──────────────────────────────────────┤   │
│  │ 友好  收到！明早第一件事就发～         │   │
│  ├──────────────────────────────────────┤   │
│  │ 简洁  好的，明天发。                  │   │
│  └──────────────────────────────────────┘   │
└────────────────────────────────────────────-─┘
```

### 2. "什么情况"按钮增强（AIGroupCatchup + ContextAnalyzer）

**位置：** 关注 tab 和未读 tab 的消息行，复用现有 GroupContextBriefingButton

**变更：** 合并 AIGroupCatchup 和 ContextAnalyzer 的输出到同一个 popover，内容分区：

```
┌─ 什么情况 Popover ────────────────────────┐
│ 📋 群摘要                                  │
│ headline: 张总要求紧急开会讨论客户方案       │
│ • 明天 10 点紧急会议                        │
│ • 客户方案需要重做                          │
│ • @你 参会，主讲你那块内容                   │
│ ⚠️ 需要你回应                               │
├────────────────────────────────────────────┤
│ 🔍 深度分析                                │
│ 背景：客户上周反馈方案不满意...              │
│ 他想要什么：你准备并主讲方案修改部分          │
│ 利益方：张总(决策者) 李姐(执行) 客户(最终)   │
│ 你的立场：核心参与者，需要准备内容            │
│ 建议行动：今晚准备修改方案要点               │
│ ⚠️ 风险：不响应可能被视为不配合              │
│                                 置信度 87%  │
└────────────────────────────────────────────┘
```

**加载策略：** 群摘要（GroupCatchup）先加载显示，深度分析（ContextAnalyzer）异步加载追加。

### 3. 日报 Tab（AIDailyRetrospector + CommitmentTracker）

**位置：** 第四个 tab "日报"

**布局：**
```
┌─ 日报 Tab ─────────────────────────────────┐
│ 📊 今日概览                    2026-04-12   │
│ ┌──────────────────────────────────────┐   │
│ │ 消息 128 条 │ 待处理 3 件 │ 承诺 2 件 │   │
│ └──────────────────────────────────────┘   │
│                                            │
│ 📝 今日总结                                │
│ 处理了客户预算审批和团队会议安排...           │
│                                            │
│ ⏰ 明天第一件事                             │
│ 给林总发预算单（已逾期 1 小时）              │
│                                            │
│ 📋 承诺追踪                                │
│ ┌─────────────────────────────────────┐    │
│ │ 🔴 逾期  给林总发预算单    昨天到期  │    │
│ │ 🟡 今天  准备客户方案修改   今天到期  │    │
│ │ ✅ 完成  发送周报          已完成     │    │
│ └─────────────────────────────────────┘    │
│                                            │
│ 📄 微信日报草稿                   [复制]    │
│ ┌──────────────────────────────────────┐   │
│ │ 今日工作：                            │   │
│ │ 1. 处理客户预算审批流程               │   │
│ │ 2. 协调团队会议安排                   │   │
│ │ ...                                   │   │
│ └──────────────────────────────────────┘   │
└────────────────────────────────────────────┘
```

**数据源：**
- 今日概览：HUDStats + PendingAsk count + Commitment count
- 今日总结 / 明天第一件事 / 微信日报：AIDailyRetrospector.retrospect()
- 承诺追踪列表：HUDStore.loadCommitments()，按状态分组（逾期 → 今天到期 → 进行中 → 已完成）

**触发时机：** 切到日报 tab 时按需加载，缓存当天结果。每次打开如果距上次生成超过 30 分钟则刷新。

### 4. VIP 洞察（VIPAggregator）

**位置：** 两层展示

**第一层 — 消息行标签：**
在关注 tab 的 VIP 消息行上，显示情绪和紧急度标签：
```
┌─ VIP MessageRow ───────────────────────────┐
│ [VIP] 林总                     5分钟前      │
│  明天开会讨论预算                            │
│  [情绪:焦虑↑] [紧急] [什么情况]             │
└────────────────────────────────────────────┘
```

**第二层 — VIP 洞察卡片：**
点击 VIP 消息行展开，显示完整的 VIP 分析卡片：
```
┌─ VIP 洞察 ─────────────────────────────────┐
│ 📊 林总 · 老板                              │
│ 情绪趋势：平静 → 焦虑（近3天）              │
│ 依据：连续追问预算进度，语气加重              │
│                                            │
│ 🎯 建议行动                                │
│ 尽快发送预算单，主动汇报进度                  │
│ 建议时机：今天下班前                         │
│                                            │
│ 📌 关键话题                                │
│ 预算审批、客户方案、团队调整                  │
└────────────────────────────────────────────┘
```

**数据流：** VIPAggregator 在 ChatMonitor 扫描周期中后台运行，结果存入 HUDStore 的 vip_traces 表，UI 从 store 读取展示。

### 5. 撤回消息分析（RecallAnalyzer）

**位置：** 消息列表中，撤回消息用特殊样式标出

**UI：**
```
┌─ 撤回消息行 ──────────────────────────────-─┐
│ ⚠️ 林总 撤回了一条消息          2分钟前      │
│  原文：下季度预算可能砍掉你们部门的...        │
│  [情报价值:高] [原因:泄露敏感信息]            │
│  AI 分析：可能涉及组织架构调整的内部消息      │
└────────────────────────────────────────────-─┘
```

**展示逻辑：**
- `shouldNotify == true` 的撤回消息才在列表中高亮
- `intelligenceValue` 为 high 时用红色左侧条标记
- 点击展开显示完整的 `detail` 分析
- 在关注 tab 的 VIP 洞察卡片中也聚合显示该 VIP 的撤回记录

### 6. 白名单自动分类（AIWhitelistCategorizer）

**两种触发路径：**

**路径 A — 自动触发（新消息）：**
- 收到非白名单联系人的消息时，ChatMonitor 后台调用 AIWhitelistCategorizer
- 如果 `shouldWhitelist == true`，在消息行上显示 "建议关注" 标签
- 点击标签弹出确认：显示 AI 建议的分类（work/life/other）和理由
- 用户确认后一键添加到白名单

**路径 B — 手动批量扫描（设置 → 联系人管理）：**
- 联系人设置页增加"AI 扫描建议"按钮
- 点击后分批扫描（每批 10 个联系人），显示进度条
- 扫描在后台进行，不阻塞 UI
- 结果逐批展示，每条建议可以单独接受/拒绝
- 提供"全部接受"和"全部忽略"的批量操作
- 首次扫描提示预计耗时

**手动扫描 UI：**
```
┌─ AI 扫描建议 ──────────────────────────────┐
│ 扫描进度  ████████░░░░  67%  (20/30)       │
│                                            │
│ 📋 建议结果                                │
│ ┌──────────────────────────────────────┐   │
│ │ 张经理  work  置信度92%  [接受] [忽略] │   │
│ │ 理由：频繁讨论工作安排和项目进度        │   │
│ ├──────────────────────────────────────┤   │
│ │ 李姐    work  置信度88%  [接受] [忽略] │   │
│ │ 理由：主要沟通会议和文件传递            │   │
│ └──────────────────────────────────────┘   │
│                        [全部接受] [全部忽略] │
└────────────────────────────────────────────┘
```

### 7. 内部管线（不直接面向用户）

以下服务作为其他 AI 功能的预处理管线，不需要独立 UI：

- **ConversationSegmenter** — 为 GroupCatchup 和 ContextAnalyzer 提供对话分段
- **MessageFeatureExtractor** — 为 AIClassifier 提供消息特征向量
- **ContextWindowBuilder** — 为所有需要上下文的 AI 服务构建合适大小的上下文窗口

## Extended 面板高度适配

新增日报 tab 和消息行展开（回复建议、VIP 洞察）会改变内容高度。

**规则：**
- Tab 切换时根据内容量动态调整 extended 面板高度
- 日报 tab 固定高度 400px（内容可滚动）
- 消息行展开时面板高度动态增长，但不超过 500px（超出滚动）
- 收起时恢复原高度

## 微信自动粘贴实现

**流程：**
1. 用户选择候选回复 → 复制到 NSPasteboard
2. 弹出 NSAlert 确认对话框
3. 确认后通过 `NSWorkspace.shared.open(URL)` 或 AppleScript 打开微信对应对话
4. 使用 AppleScript 模拟 Cmd+V 粘贴
5. 不自动发送，等用户确认

**注意：** 需要辅助功能权限（Accessibility），首次使用时提示用户授权。

## 技术要点

### 新增 View 文件
- `ReplyDebtExpandedView.swift` — 待回消息展开的回复建议区
- `DailyReportTabView.swift` — 日报 tab 主视图
- `CommitmentListView.swift` — 承诺追踪列表
- `VIPInsightCardView.swift` — VIP 洞察卡片
- `RecalledMessageRow.swift` — 撤回消息行
- `WhitelistScanView.swift` — 白名单批量扫描界面
- `WhitelistSuggestionBadge.swift` — 消息行上的"建议关注"标签

### 需修改的现有文件
- `ExtendedTabsView.swift` — 新增日报 tab，支持行展开
- `ReplyDebtRow` (in ExtendedTabsView) — 增加点击展开回复建议
- `MessageRow` (in ExtendedTabsView) — 增加 VIP 标签、撤回样式、建议关注标签
- `GroupContextBriefingButton.swift` — 合并 GroupCatchup + ContextAnalyzer 输出
- `ContactsSettingsView.swift` — 增加 AI 扫描建议入口
- `AppDelegate.swift` — 面板高度动态适配逻辑
- `ChatMonitor.swift` — 接入 WhitelistCategorizer 自动触发 + VIPAggregator 后台运行

### 数据流新增
- ChatMonitor 新增 `@Published var commitments: [Commitment]`
- ChatMonitor 新增 `@Published var recalledMessages: [RecalledMessage]`
- ChatMonitor 新增 `@Published var vipInsights: [String: VIPAggregateResult]` (keyed by username)
- ChatMonitor 新增 `@Published var whitelistSuggestions: [String: WhitelistSuggestion]`
- ChatMonitor 新增 `@Published var dailyReport: Retrospective?`
