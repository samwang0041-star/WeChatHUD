# WeChatHUD AI 管家 — 统一收件箱 V2 + 设置面板产品化

**Date**: 2026-04-13
**Status**: Draft → Pending Review

---

## 一、产品定位

WeChatHUD 不是微信消息通知窗口，而是 **AI 管家**。

- 管家读消息、分析消息、告诉用户该做什么
- 用户不看原始消息，看管家消化后的分析结论
- 算法精确提取数据（客观事实），AI 只做最终总结（主观结论）
- AI 挂了系统降级为智能通知窗口，不完全失效

---

## 二、三态交互系统

### 2.1 状态机

```
         鼠标移入              点击齿轮 / 右键→查看详情
Compact ────────→ Extended ──────────────────────→ Detail
   ↑     ←────────    ↑                              │
   │     鼠标移出      │          Esc / 关闭按钮        │
   │     400ms 防抖    └──────────────────────────────┘
   │
   └── 新消息到达 → compact 内容更新 + 脉冲动画
```

三种状态，三种用户时刻：
- **Compact**：用户在忙别的事 → 信号灯
- **Extended**：用户决定处理消息 → 行动列表
- **Detail**：用户想深入管理 → 设置/对话分析

### 2.2 Compact（信号灯）

90% 时间用户看到的界面。余光可判断"要不要停下来"。

**三档视觉状态：**

| 条件 | 显示 | 宽度 |
|------|------|------|
| 无待处理 + 同步正常 | `● 一切正常  ⚙` | 200px |
| 无待处理 + 同步异常 | `⚠ 微信未运行  ⚙` 或 `⚠ 未同步  ⚙` | 200px |
| 仅 P2 | `● N条待处理  ⚙`（中性灰色） | 240px |
| 有 P0/P1 | `🔴 AI摘要...  +N  ⚙` | 380px |
| P0/P1 + 超时 | `🔴 AI摘要...  超时N分  +N  ⚙` | 380px |

有 P0/P1 时显示**最高优先级那条的 AI 摘要**（不是原始消息），让用户余光就能判断是什么事。

**Compact 交互：**
- 鼠标移入 → Extended
- 点击齿轮 → Detail
- 新消息到达 → 内容更新 + SwiftUI opacity 脉冲动画
- 无其他交互（compact 是信号灯，不是操作面板）

### 2.3 Extended（行动列表）

鼠标移入 compact → 窗口向下展开。

```
┌──────────────────────────────────────────────────┐
│  收件箱 (3)                    刚刚同步       ⚙   │
├──────────────────────────────────────────────────┤
│                                                  │
│  🔴 凌慧  VIP 😐 · 超时                    15分   │
│     等你确认方案修改稿，她已催过一次                │
│                                                  │
│  🔴 产品群 @你                              5分    │
│     张总问你方案排期，需要给出时间                  │
│                                                  │
│  🟡 ponge                                 25分    │
│     聊天闲聊，无需紧急回复                         │
│                                                  │
│  ┈┈┈ 已处理 (2) ┈┈┈┈┈┈┈┈┈┈┈ [展开]              │
└──────────────────────────────────────────────────┘
```

**列表规则：**
- 纯行动项列表。不放"仅通知"、不放信息流。收件箱 = 待办清单
- 每行第二行是 **AI 摘要**（管家分析），不是原始消息预览
- AI 未返回时先显示原始 preview（灰色斜体），返回后动画替换
- 排序：P0 → P1 → P2，同优先级按时间倒序
- 最多 20 条，超出显示"还有 N 条较低优先级消息"
- 底部折叠"已处理"区（静音/贪睡的消息）

**窗口尺寸：**
- 空列表：280×80（显示"✓ 没有待处理消息"）
- 有内容：480×(header 38 + rows × 48 + 已处理区 30)，最大 480×500

**收起逻辑：**
- 鼠标移出 → 400ms 防抖 → 收回 compact
- 有行展开时不因鼠标短暂移出边缘就收起
- 处理完所有行后等 1 秒自动收起

### 2.4 Detail（深度管理）

点击齿轮进入。全高面板 700×500。

包含设置（4 个 tab）+ 面板（3 个 tab）。详见第六章。

ESC 或关闭按钮 → 回到 compact。

---

## 三、行的三层交互

所有行统一交互模式，不因类型而不同。

### 3.1 默认态（扫一眼）

```
🔴 凌慧  VIP 😐 · 超时                    15分
   等你确认方案修改稿，她已催过一次
```

| 元素 | 来源 | 出现条件 |
|------|------|---------|
| 🔴/🟡 色点 | 算法（ReplyDebtScorer） | 始终 |
| 联系人名 | DB | 始终 |
| `VIP` 橙色标签 | DB（attention_level） | isVIP=true |
| 情绪 emoji（😐😊😠） | Layer 2 AI（预计算） | isVIP=true 且有 vipInsight |
| `超时` 红色小字 | 算法（回复窗口对比） | isOverdue=true |
| `已回复` 绿色小字 | 算法（检测到 outbound） | replied=true（即将消失） |
| 时间 | 算法 | 始终 |
| AI 摘要 | Layer 2 AI / 算法降级 | 始终（AI 未返回时显示原始 preview） |

### 3.2 Hover 态（决定怎么办）

```
🔴 凌慧  VIP 😐 · 超时               ⏰  ✕   15分
   等你确认方案修改稿，她已催过一次
```

| 按钮 | 图标 | 行为 | 出现条件 |
|------|------|------|---------|
| ⏰ | clock | 弹出贪睡菜单（30分/2小时/今晚/明早） | 行未被回复 |
| ✕ | xmark | dismiss（新消息来了会重新出现） | 始终 |

**只有两个按钮，始终在同一位置。**

⏰ 贪睡菜单：
```
┌──────────────┐
│  30 分钟后    │
│  2 小时后     │
│  今晚 20:00  │
│  明早 09:00  │
└──────────────┘
```

选择后：行滑出列表 → 底部显示 3 秒撤销条 → 进入已处理区。

✕ dismiss 后：行滑出列表 → 底部显示 3 秒撤销条：
```
已忽略 "凌慧在等你确认方案修改"         [撤销]
```

### 3.3 点击态（管家简报）

点击行本身 → 展开管家简报面板。

```
🔴 凌慧  VIP 😐 · 超时                        15分
   等你确认方案修改稿，她已催过一次
┌──────────────────────────────────────────────────┐
│                                                  │
│  📋 情况                                         │
│  凌慧发来方案修改稿（第二版），标注红字部分需要你     │
│  确认。上周你们讨论过这个方案，你当时说"周末看看"。   │
│  她今天发了两次消息，语气比平时急。                  │
│                                                  │
│  💡 建议                                         │
│  尽快回复确认收到，避免她继续催。周末前完成审阅。     │
│                                                  │
│  回复                                            │
│  ✅ "收到，我看看红字部分，周末前给你反馈"    [选择]  │
│     "好的，我仔细看看修改的地方"              [选择]  │
│     "收到"                                  [选择]  │
│                                                  │
│  ──────────────────────────────────────────────   │
│                    [在微信中打开]                   │
└──────────────────────────────────────────────────┘
```

**简报结构统一，内容因类型而异：**

| 行类型 | 📋 情况 侧重 | 💡 建议 侧重 |
|--------|-------------|-------------|
| VIP 需回复 | 意图 + 关系动态 + 情绪 + 你的承诺 | 回复时机 + 关系维护 |
| 群聊 @ | 群聊讨论主题 + 为什么 @你 + 你需要回应什么 | 怎么回应 |
| 普通需回复 | 意图 + 上次你们的对话 | 怎么回复 |

**回复建议交互：**
1. 点击 `[选择]` → 复制到剪贴板 → 行内显示"✓已复制 [在微信中打开并粘贴]"
2. 点击"在微信中打开并粘贴" → 跳转微信 + 0.8s 后自动粘贴
3. 或直接点底部"在微信中打开"→ 不用建议，自己打字

**加载策略：**
1. 点击 → 立即展开面板框架
2. 立即填充算法数据（"你上次: xxx"）
3. 显示 loading 在简报区
4. AI 返回 → 替换为完整简报
5. AI 超时（>5s）→ 显示"管家分析暂时不可用" + "在微信中打开"

**同时只展开一行。点击另一行 → 当前行折叠，新行展开。**

### 3.4 右键菜单

```
┌───────────────────┐
│  复制消息原文       │
│  在微信中打开       │
│  ─────────────    │
│  查看对话详情   →   │
│  ─────────────    │
│  静音此对话         │    ← 永久静音（比 dismiss 更强）
│  设为 VIP          │    ← 仅非 VIP 白名单联系人
│  降为普通关注       │    ← 仅 VIP
│  忽略此发送人       │    ← 仅群聊
└───────────────────┘
```

### 3.5 已处理区

列表底部，默认折叠：

```
┈┈┈ 已处理 (2) ┈┈┈┈┈┈┈┈┈┈┈ [展开 ▾]
```

展开后：
- 被贪睡的行显示 `⏰ 还有 25 分钟` + `[恢复]`
- 被 dismiss 的行显示 `[恢复]`
- 被静音的行显示 `🔇 已静音` + `[取消静音]`
- 贪睡到期 → 下次 scan 自动移回行动项区

### 3.6 消息生命周期

| 事件 | 结果 |
|------|------|
| 用户通过 HUD "在微信中打开并粘贴"后回复 | HUD 知道用户刚操作 → 该行**立即移除** |
| 用户直接在微信里回复 | 下次 scan 检测到 outbound → 移除 |
| 用户 dismiss | 进入已处理区。同一对话新消息到达 → 重新出现 |
| 用户贪睡 | 进入已处理区。到期后重新出现 |
| 用户静音 | 进入已处理区。不自动恢复，需手动取消 |

---

## 四、AI 架构

### 4.1 四层架构

| 层 | 职责 | 时机 | 阻塞 UI |
|----|------|------|---------|
| Layer 1 算法 | 优先级评分、超时检测、排序、compact 选择 | scan 时即时 | 否 |
| Layer 2 预计算 AI | 消息摘要、情绪检测、互动趋势 | scan 后异步 | 否 |
| Layer 3 按需 AI | 完整简报、回复建议 | 用户点击展开 | 展开面板内 loading |
| Layer 4 学习 | 优先级权重调整、风格学习、建议排序优化 | 持续后台 | 否 |

**核心原则：AI 挂了，Layer 1 算法照常工作。系统降级但不停机。**

### 4.2 AI 降级策略

| AI 状态 | 列表摘要 | 展开面板 | Compact |
|---------|---------|---------|---------|
| 正常 | AI 摘要 | 完整简报 + 推荐回复 | AI 摘要 |
| 延迟（>3s） | 原始 preview（灰色斜体），AI 返回后替换 | loading → 超时后显示"在微信中打开" | 原始 preview |
| 不可用 | 原始 preview | 只显示算法数据 + "在微信中打开" | 原始 preview |

### 4.3 InboxContext 数据包

算法为每个 inbox item 构建的结构化数据，供 AI 分析用：

```swift
struct InboxContext {
    // 1. 触发消息
    let triggerMessage: MessageInfo
    let triggerMessageText: String
    
    // 2. 对话窗口（动态大小）
    let recentMessages: [MessageInfo]   // 上下文窗口
    let myLastReply: MessageInfo?
    let myLastReplyText: String?
    let timeSinceMyLastReply: TimeInterval?
    
    // 3. 发送人画像
    let senderRole: ContactRole
    let senderAttentionLevel: AttentionLevel
    let senderReplyWindow: Int          // 从角色配置读取
    let isOverdue: Bool
    let overdueMinutes: Int
    
    // 4. 交互历史
    let weeklyInteractionCount: Int
    let weeklyTrend: Trend              // up / down / stable
    let avgResponseTimeMinutes: Int
    
    // 5. 关联数据
    let pendingCommitments: [Commitment]
    let pendingAsks: [PendingAsk]
    
    // 6. 群聊特有
    let isGroupChat: Bool
    let mentionedMe: Bool
    let groupRecentContext: [MessageInfo]?  // @之前 5-10 条
    
    // 7. 消息信号
    let hasUrgentKeyword: Bool
    let hasAskSignal: Bool
    let inboundCountSinceMyLastReply: Int
}
```

**上下文窗口动态规则：**

| 触发消息长度 | recentMessages 条数 | 理由 |
|------------|-------------------|------|
| ≤5 字 | 15 条 | 消息本身无信息，必须看上下文 |
| 6-20 字 | 10 条 | 可能是回应或追问 |
| 21-50 字 | 6 条 | 有一定自含信息 |
| >50 字 | 3 条 | 消息自身信息充足 |

群聊 @：在以上基础上，额外取 @之前 5-10 条群消息。
有未兑现承诺：额外关联承诺记录。

**构建性能：批量查询优化。** 一次加载所有相关对话的最近消息，内存中分配到各 InboxContext。不逐个查 DB。

### 4.4 AI 调用优先级队列

```
P0 摘要 > P1 摘要 > P2 摘要 > 用户点击的简报（插队到队首）
```

本地模型串行处理时，保证用户最先看到 P0 的 AI 分析。

### 4.5 摘要缓存

- 缓存 key = `chatUsername + latestMsgId`
- 新消息到达 → 缓存失效 → 重新分析
- 无新消息 → 复用缓存（0 AI 调用）

### 4.6 学习层

| 用户操作 | 学习信号 | 系统调整 |
|---------|---------|---------|
| 总是先处理某人 | 该人优先级偏低 | 上调评分权重 |
| 选了某条回复建议 | 偏好该风格/语气 | 推荐排序调整 |
| 修改建议后发送 | 学习修改模式 | 风格模型更新 |
| 总是贪睡某对话 | 该对话优先级偏高 | 降低评分 |
| dismiss 未回复 | 不需要回复 | 降低 actionRequired 权重 |

（学习层为 Phase 2，本次 spec 只预留接口，不实现。）

---

## 五、Compact → Extended 过渡细节

### 5.1 展开动画

窗口从 compact 尺寸向下展开到 extended 尺寸。时长 ~200ms。

compact 显示的 AI 摘要在展开后自然成为列表第一行。视觉连贯，不跳跃。

### 5.2 空列表展开

```
收件箱 (0)                  刚刚同步  ⚙
──────────────────────────────────────
         ✓ 没有待处理消息
┈┈┈ 已处理 (3) ┈┈┈┈┈┈┈ [展开]
```

已处理区始终可见可操作。

### 5.3 Detail 态收到新消息

Detail 面板顶部出现内嵌通知条：
```
🔴 凌慧在等你确认方案修改 · 超时15分          [查看]
```
点击 `[查看]` → 切换到 Extended 列表。

### 5.4 Smart Digest

离开 30+ 分钟后 hover compact 展开时，Extended 顶部显示橙色 banner：
```
⏰ 离开了 45 分钟 — 2条待回 · 1条超时          [知道了]
```
点击"知道了"关闭 banner。用户在列表中自行处理。

### 5.5 菜单栏 Badge

| 状态 | Badge |
|------|-------|
| 无消息 | 无 badge |
| 有 P0/P1 | 红色数字（行动项总数） |
| 仅 P2 | 灰色数字 |

### 5.6 快捷键

| 快捷键 | 行为 |
|--------|------|
| Esc | 收起到 compact（任何状态） |
| Cmd+, | 打开设置（Detail） |
| Cmd+R | 立即触发 scan 刷新 |

移除 Cmd+1-5。更新 onboarding 文案。

---

## 六、设置面板产品化

### 6.1 新结构

从 11 个 tab 重组为 4 设置 + 3 面板：

**设置（可配置）：**

| Tab | 图标 | 名称 | 合并自 |
|-----|------|------|--------|
| 1 | 👤 | 联系人 | 联系人 + 角色配置 + 忽略列表 |
| 2 | 🤖 | AI 管家 | AI 引擎 + 通知行为 |
| 3 | 🔄 | 自动托管 | 自动托管（不变） |
| 4 | 🔧 | 系统 | 同步 + 数据 + 关于 |

**面板（dashboard）：**

| Tab | 图标 | 名称 | 内容 |
|-----|------|------|------|
| 5 | 📋 | 日报 | 日报/周报 |
| 6 | ✅ | 承诺 | 承诺追踪 |
| 7 | 📝 | 托管日志 | 自动回复活动日志 |

侧栏设置和面板之间用分隔线区分。

### 6.2 联系人 Tab

合并原来的联系人管理 + 角色配置 + 忽略列表。

联系人列表，点击展开编辑：
- 关注级别（VIP / 白名单 / 灰名单 / 陌生人）
- 角色（boss / key_client / family / colleague 等）
- 回复窗口（分钟）
- 通知级别（强提醒 / 标准 / 轻提醒 / 无）
- 回复语气（reporting / professional / casual 等）
- 备注

底部：忽略的发送人列表 + 取消忽略按钮。

**后端修复：** 联系人的 replyWindowMinutes 和通知级别要被 ReplyDebtScorer 和通知逻辑实际读取。

### 6.3 AI 管家 Tab

合并 AI 引擎 + 通知行为。

**AI 服务连接：**
- 服务地址、模型、API Key
- `[测试连接]` 按钮 + 状态显示

**统一为一套 AI 配置。** 去掉 `AIClassifierConfig`，所有 AI service 统一从 `AIConfig` 读取连接参数。各 service 的特殊参数（temperature, maxTokens, promptVersion）作为 service 自身的 init 参数。

**管家行为开关：**
- 消息分析（AI 摘要）：开/关
- 回复建议：开/关
- 情绪检测：开/关
- 回复债务 AI 判断：开/关 + Shadow 模式

**通知过滤：**
- @提及时提醒：开/关
- VIP 消息时提醒：开/关
- 白名单消息时提醒：开/关
- 提醒时长：秒数

**AI 审计日志：** 最近 N 条 AI 调用记录。

**后端修复：**
- 统一 `ai` / `classifier` 为一套配置
- 通知过滤 3 个开关接入通知触发逻辑
- 各 AI 能力开关控制是否调用对应 AI service

### 6.4 自动托管 Tab

保持不变。当前设计已 OK，后端读取正常。

### 6.5 系统 Tab

合并同步 + 数据。

**同步配置：**
- 扫描间隔（秒）
- 缓存策略
- 微信数据路径（自动检测 / 手动指定）

**数据管理：**
- HUD 数据库路径 + 大小
- `[导出报告]` `[清除缓存]`

**关于：**
- 版本号
- 快捷键说明

**后端修复：**
- `intervalSeconds` 接入 ChatMonitor 的 scan timer
- `wechatDBPath` 非 auto 时使用用户指定路径

---

## 七、后端修复清单

| # | 修复项 | 影响 |
|---|--------|------|
| 1 | 合并 AIConfig / AIClassifierConfig 为一套 | 所有 AI service 改为从 AIConfig 读取 |
| 2 | 联系人 replyWindowMinutes 接入 ReplyDebtScorer | Scorer 读取联系人配置替代硬编码默认值 |
| 3 | 通知过滤 3 个开关接入通知逻辑 | showNotification 前检查开关 |
| 4 | 同步间隔接入 scan timer | ChatMonitor.start() 读取 intervalSeconds |
| 5 | DB 路径接入 WeChatReader | 非 auto 时使用用户路径 |
| 6 | AI 能力独立开关 | 新增字段到 AIConfig，各 service 检查开关 |
| 7 | 角色配置的通知级别接入通知系统 | 不同角色不同提醒强度 |

---

## 八、清理清单

| 文件 / 功能 | 处理 |
|-------------|------|
| CompactBarView.swift | 删除（已不使用） |
| ExtendedTabsView.swift | 删除（被 InboxView 替代） |
| ExtendedBarView.swift | 删除（已不使用） |
| CatchupTabView.swift | 删除（功能被收件箱替代） |
| WhitelistSettingsView.swift | 删除（合并到 ContactsSettingsView） |
| RoleConfigSettingsView.swift | 删除（合并到 ContactsSettingsView） |
| IgnoredSendersSettingsView.swift | 删除（合并到 ContactsSettingsView） |
| NotificationSettingsBody.swift | 删除（合并到 AI 管家 tab） |
| SyncSettingsView.swift | 删除（合并到系统 tab） |
| DataSettingsView.swift | 删除（合并到系统 tab） |
| Cmd+1-5 快捷键 | 移除代码 + 更新 onboarding 文案 |
| .notification PanelState | 标记 deprecated，不再触发 |
| AIClassifierConfig | 移除，统一用 AIConfig |

---

## 九、数据模型变更

### 9.1 InboxItem 增强

```swift
struct InboxItem: Identifiable {
    // 已有字段
    let id: String
    let chatUsername: String
    let chatName: String
    let senderName: String
    let preview: String              // 原始消息预览（降级用）
    let isGroup: Bool
    let timestamp: Date
    let actionRequired: Bool
    let priority: InboxPriority
    let isVIP: Bool
    let isWhitelisted: Bool
    let unreadCount: Int
    let isAtMention: Bool
    let askType: AskType
    let reasons: [ReplyDebtReason]
    let suggestedReplyMinutes: Int
    var status: InboxStatus
    var dismissedAtMsgId: Int64?
    
    // 新增字段
    var aiSummary: String?           // AI 摘要（"等你确认方案修改"）
    var moodEmoji: String?           // 情绪 emoji（仅 VIP）
    var isOverdue: Bool              // 是否超时
    var overdueMinutes: Int          // 超时分钟数
    var replied: Bool                // 是否已回复（待消失）
    var snoozedUntil: Date?          // 贪睡到期时间
    var silenced: Bool               // 是否永久静音
}
```

### 9.2 Briefing 结构

```swift
struct InboxBriefing {
    let situation: String            // 📋 情况
    let suggestion: String           // 💡 建议
    let replies: [SuggestedReply]    // 回复建议
}

struct SuggestedReply {
    let text: String
    let tone: String                 // 友好 / 正式 / 简洁
    let isRecommended: Bool          // ✅ 管家推荐
}
```

### 9.3 AIConfig 统一

```swift
struct AIConfig: Codable {
    // 连接参数
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    
    // 通用参数
    var maxTokens: Int = 2048
    var temperature: Double = 0.3
    
    // 能力开关
    var summaryEnabled: Bool = true       // 消息摘要
    var suggestionsEnabled: Bool = true   // 回复建议
    var moodDetectionEnabled: Bool = true // 情绪检测
    var debtJudgeEnabled: Bool = true     // 回复债务 AI 判断
    var debtJudgeShadowMode: Bool = true  // Shadow 模式
}
```

---

## 十、不做的事（明确排除）

| 排除项 | 理由 |
|--------|------|
| Tab 系统 | 统一列表是核心设计决策 |
| 仅通知/信息流区域 | 收件箱 = 待办清单，FYI 不是待办 |
| 白名单建议行 | 推荐逻辑属于设置，不属于收件箱 |
| 撤回消息独立行 | 不可操作不进待办清单（在对话详情中查看） |
| 复杂动画 | 展开/折叠用简单高度过渡 |
| Layer 4 学习层实现 | 本次只预留接口，Phase 2 实现 |
| 追赶模式 | 功能被 Smart Digest + 收件箱替代 |

---

## 十一、Phase 规划

**Phase 1（本次实施）：**
- InboxContext 数据管线
- AI 摘要 + 简报 + 推荐回复
- InboxView / InboxRowView 全新 UI
- Compact 三态
- 展开面板（管家简报）
- 已处理区 + 撤销
- AI 降级策略
- 设置面板重组（4+3）
- 7 项后端修复
- 代码清理

**Phase 2（后续）：**
- Layer 4 学习层实现
- 跨对话关联检测
- 自然语言搜索收件箱
- 批量操作（全部已读/全部贪睡）
