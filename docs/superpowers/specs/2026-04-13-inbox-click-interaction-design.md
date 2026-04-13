# InboxRow 点击交互重设计

> 日期: 2026-04-13
> 状态: Draft

## 1. 背景

当前 InboxRow 点击后展开 BriefingPanelView，自动触发 AI 分析（情况 + 建议 + 回复建议），群聊和私聊逻辑完全一致。问题：

1. 自动加载 AI 浪费调用 — 用户可能只想快速处理，不需要分析
2. 群聊和私聊需要不同的分析维度
3. 回复建议质量低 — AI 不了解用户与对方的关系，生成的回复脱离实际
4. 回复建议流程冗余 — 复制后还要手动点"在微信中打开"

## 2. 设计目标

- 点击展开只显示操作按钮，AI 分析按需触发
- 群聊和私聊展示不同的分析按钮
- 回复建议基于 AI 推断的关系画像，只对已推断用户显示
- 回复建议一步完成：点击 → 复制 + 跳转微信

## 3. 展开面板结构

### 3.1 群聊

点击 InboxRow → 就地展开操作面板：

```
┌──────────────────────────────────────────┐
│  🔍 在聊什么    💬 回复建议*    📱 打开微信  │
└──────────────────────────────────────────┘
```

*"回复建议"仅在该群有需要我回应的内容（@我、直接提问）且关系画像已就绪时显示。

### 3.2 私聊

```
┌──────────────────────────────────────────┐
│  🔍 帮我分析    💬 回复建议*    📱 打开微信  │
└──────────────────────────────────────────┘
```

*"回复建议"仅在关系画像已推断时显示。无画像的联系人不显示此按钮。

### 3.3 交互流程

1. 点击"在聊什么"/"帮我分析"/"回复建议" → 按钮区下方出现 loading 动画
2. AI 返回结果 → 替换 loading 为结果卡片
3. 点击"打开微信" → 直接跳转，无 AI 调用
4. 点击回复建议中的任一条 → 复制到剪贴板 + 打开微信跳转到对话（一步完成）
5. 再次点击 InboxRow → 收起面板

### 3.4 处理操作保持不变

忽略/贪睡/静音继续在 hover 按钮和右键菜单中，不放入展开面板。展开面板只负责分析。

## 4. AI 分析上下文规则

### 4.1 消息范围

- 最近 **50 条**消息
- 在 **48 小时**内
- 先到先截断（50 条或 48h，谁先触达就在谁那里截断）

### 4.2 追溯逻辑

- 从最新消息往回追溯到用户上次回复的位置（在 50 条/48h 范围内）
- 如果 50 条内没有找到用户回复，全部纳入分析，AI 提示词中注明"未找到你的近期回复"

## 5. AI 提示词设计

### 5.1 群聊"在聊什么"

**输入：** 最近 50 条消息（含发送者、时间戳、内容）

**提示词要点：**
```
你是微信群聊分析助手。根据以下群聊消息，为用户生成一份简报。

输出 JSON：
{
  "topics": "群里在讨论什么（如有多个话题用分号分隔）",
  "decisions": "已达成的决策/结论（没有则为 null）",
  "my_action_items": "分配给我的任务或需要我跟进的事（没有则为 null）",
  "key_speakers": "关键人物说了什么（领导/发起者的核心发言摘要）",
  "status": "discussing|concluded|waiting_for_me",
  "one_liner": "一句话总结，≤30字"
}

规则：
1. topics 要具体，不要"大家在讨论工作" — 要说清楚讨论什么工作
2. decisions 只列明确达成共识的，不要猜测
3. my_action_items 只列明确指向用户的，@用户或点名要求的
4. key_speakers 只列最重要的 2-3 条，不要流水账
5. status: discussing=还在聊, concluded=已聊完, waiting_for_me=在等我回应
6. 所有字段用中文
```

### 5.2 私聊"帮我分析"

**输入：** 最近 50 条消息 + 关系画像（如有）

**提示词要点：**
```
你是微信私聊分析助手。根据以下私聊消息，帮用户快速理解情况。

输出 JSON：
{
  "intent": "对方找我干什么（一句话）",
  "urgency": "urgent|normal|low",
  "urgency_reason": "判断依据（≤15字）",
  "mood": "对方情绪：anxious|calm|frustrated|friendly|neutral",
  "mood_evidence": "情绪判断依据（≤15字）",
  "context": "与之前对话的关联（没有明显关联则为 null）",
  "one_liner": "一句话总结，≤30字"
}

规则：
1. intent 要具体 — 不是"找你聊天"，而是"问你周三方案的修改进度"
2. urgency 判断依据：连续多条消息=urgent，带感叹号/催促词=urgent，纯通知=low
3. mood 要从措辞推断，不要默认 neutral
4. context 关联之前的对话主题，帮用户回忆"上次聊到哪了"
```

### 5.3 回复建议（重设计）

**输入：** 最近 50 条消息 + 关系画像 + ask_type

**提示词要点：**
```
你是微信回复建议助手。根据对话上下文和用户与对方的关系，生成 3 条可以直接发送的回复。

关系画像：
- 关系: {relationship}（如：直属领导、合作方对接人、下属、朋友）
- 沟通风格: {tone_preference}（如：正式、随意、简洁）
- 备注: {user_note}（用户手动补充的备注）

输出 JSON：
{
  "suggestions": [
    {
      "text": "回复内容",
      "tone": "friendly|formal|brief",
      "rationale": "为什么推荐这条（≤15字）",
      "recommended": true/false
    }
  ]
}

核心规则：
1. 每条回复必须能直接发送，不要任何前缀
2. 长度 ≤ 30 字
3. 三条回复方向不同：一条正面回应、一条推迟/委婉、一条简洁确认
4. 根据关系画像调整语气 — 对领导不要太随意，对朋友不要太正式
5. 不要生成"好的收到""感谢分享"这类万能废话，除非这真的是最合适的回复
6. 如果对方在等一个具体答案（文件/决定/时间），回复里必须包含具体承诺或明确推迟理由
7. 如果是群聊且需要回应 @，回复要针对具体问题，不要泛泛而谈
8. recommended=true 只标一条，选择最符合关系和场景的那条
```

## 6. 关系画像系统

### 6.1 自动推断

当用户将联系人加入白名单时，触发关系推断：

1. 读取该对话最近 50 条消息（48h 内）
2. AI 分析对话模式，推断关系

**推断提示词：**
```
根据以下微信对话记录，推断用户与对方的关系。

输出 JSON：
{
  "relationship": "关系描述（如：直属领导、同事-平级、客户、家人、朋友）",
  "hierarchy": "superior|peer|subordinate|external|personal",
  "tone_preference": "formal|casual|brief",
  "context": "关系背景（≤30字，如：负责审批用户的方案）",
  "confidence": 0.0-1.0
}

规则：
1. 从称呼、语气、内容主题推断
2. 如果信息不足以判断，confidence < 0.5，relationship 写"待确认"
3. hierarchy 决定回复建议的语气基准
4. tone_preference 从用户自己的历史回复风格推断
```

### 6.2 数据存储

在 HUDStore 的 SQLite 中新增 `relationship_profile` 表：

```sql
CREATE TABLE IF NOT EXISTS relationship_profile (
    username TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    relationship TEXT NOT NULL,       -- "直属领导"
    hierarchy TEXT NOT NULL,          -- "superior"
    tone_preference TEXT NOT NULL,    -- "formal"
    context TEXT,                     -- "负责审批我的方案"
    confidence REAL NOT NULL,         -- 0.85
    user_note TEXT,                   -- 用户手动备注
    user_edited INTEGER DEFAULT 0,    -- 用户是否手动修改过
    inferred_at INTEGER NOT NULL,     -- 推断时间戳
    updated_at INTEGER NOT NULL       -- 最后更新时间戳
);
```

### 6.3 用户可见可编辑

在联系人设置页（ContactsSettingsView）中，每个白名单联系人显示：

- **关系**: 可编辑文本（如"直属领导" → 用户可改为"前领导"）
- **层级**: 下拉选择（上级/平级/下属/外部/私人）
- **沟通风格**: 下拉选择（正式/随意/简洁）
- **备注**: 自由文本
- **AI 置信度**: 只读显示
- **重新推断按钮**: 让 AI 重新分析

用户修改后 `user_edited = 1`，后续不会被自动推断覆盖。

### 6.4 回复建议按钮显示条件

- `relationship_profile` 表中存在该用户的记录 → 显示"回复建议"按钮
- 不存在记录 → 不显示按钮
- 群聊：额外需要有 @我或直接向我提问的消息

## 7. 静音名单管理

### 7.1 入口

设置页面（SettingsView）新增"静音管理"入口。

### 7.2 功能

- 显示所有被永久静音的对话列表
- 每行显示：对话名称、静音时间、最后一条消息预览
- 操作：取消静音（恢复到 inbox 正常监控）
- 操作：永久删除（从白名单中移除）

## 8. 代码影响

### 8.1 修改文件

| 文件 | 变更 |
|------|------|
| `BriefingPanelView.swift` | 重写为按钮面板 + 按需加载，区分群聊/私聊按钮 |
| `InboxRowView.swift` | `expanded` 展开内容改为新面板；回复建议点击改为复制+跳转一步完成 |
| `HUDStore.swift` | 新增 `relationship_profile` 表 CRUD |
| `ContactsSettingsView.swift` | 新增关系画像编辑 UI |
| `SettingsView.swift` | 新增静音管理入口 |
| `AIService.swift` | 新增群聊分析/私聊分析/关系推断三个 AI 调用 |
| `ChatMonitor.swift` | 加入白名单时触发关系推断 |

### 8.2 新增文件

| 文件 | 用途 |
|------|------|
| `Resources/prompts/group_analysis_v1.txt` | 群聊"在聊什么"提示词 |
| `Resources/prompts/private_analysis_v1.txt` | 私聊"帮我分析"提示词 |
| `Resources/prompts/relationship_infer_v1.txt` | 关系推断提示词 |
| `Views/Settings/SilencedChatsView.swift` | 静音名单管理页 |
| `Data/RelationshipProfile.swift` | 关系画像 model |

### 8.3 修改提示词

`Resources/prompts/reply_suggester_v1.txt` — 注入关系画像字段，强化规则（不生成废话回复、根据关系调整语气）。

## 9. 不做的事

- 不做内容层面的按钮过滤 — "好的"也可能是重要信息，按钮始终出现
- 不在展开面板中放忽略/贪睡/静音 — 这些留在 hover 和右键
- 不自动触发 AI — 所有分析都是用户点击按钮后才调用
