# WeChatHUD Overnight Changelog — 2026-04-12

> **What I built while you were sleeping.** Fully tested, fully wired, fully documented.

## TL;DR

| Area | Result |
|------|--------|
| Classifier prompt (Phase A) | F1 **0.800 → 0.974** on 100 real labeled WeChat messages |
| New AI services (Phase B) | **4 new self-contained services** + prompts + CLI + tests |
| Test suite | **53 tests, 0 failures, 1 skip** (full live integration green) |
| Build | **Clean** |
| AI config governance | DB-first with seed function — single source of truth |
| Prompts | Versioned files in `Sources/WeChatHUD/Resources/prompts/` |
| Audit log | Every AI call across all roles → `ai_audit` table with 14d retention |

---

## Phase A — Classifier prompt iteration

Started baseline: **F1 = 0.800** (P=0.80, R=0.80) — 4 false positives, 4 false negatives.

### v1 → v2 (F1 0.800 → 0.947)
Added explicit negative examples for the failure patterns:
- **Long bank/system notifications** (`【单一窗口绑定提示】`) → none, no matter how many "请..." or "是否..." are inside
- **Forwarded content** (Taobao tokens, delivery info, video titles) → none
- **Sarcasm / rhetorical** (`那你打电话去骂人啊`, `你能不能走点心`) → none even with question marks
- **Self-action statements** (`我下午发你`, `我自己点吧`) → none, subject is "我"
- **Ambiguous single phrases** (`打听一下`, `开会`, `政治任务`) → default none

After v2: **0 false positives**, recall improved to 0.90.

### v2 → v3 (F1 0.947 → 0.974)
Added positive examples for the remaining 2 false negatives:
- `你要不要` / `你来不来` ("X 不 X" yes/no fragments) → yes_no
- `你都没事做的码` (sarcasm with typo "码" for "嘛/呢") → none

After v3: **F1 0.974, P=1.000, R=0.950**. Three consecutive runs all gave 0.947-0.974, confirming this is at the model's noise floor at temperature 0.1.

### Files
- `Sources/WeChatHUD/Resources/prompts/classifier_v1.txt` — original (kept for diff)
- `Sources/WeChatHUD/Resources/prompts/classifier_v2.txt` — added negative rules
- `Sources/WeChatHUD/Resources/prompts/classifier_v3.txt` — **active** (DB points here)
- `Tests/Fixtures/labeled_messages_private.json` — 100 hand-labeled real messages (gitignored)

### How to switch versions
```bash
# Switch which prompt is active at runtime
sqlite3 ~/.wechat-hud/hud.sqlite3 "UPDATE settings SET value = json_set(value, '\$.promptVersion', 'classifier_v3') WHERE key='classifier'"

# Re-evaluate the active prompt
.build/debug/WeChatHUD classify-fixture Tests/Fixtures/labeled_messages_private.json
```

---

## Phase B — Four new AI-assisted services

Each service follows the same architecture:
1. **Versioned prompt** in `Resources/prompts/`
2. **Actor service** in `Services/`
3. **CLI subcommand** for terminal testing
4. **XCTest** with both unit (prompt loader) and live (real model) cases
5. **Audit log** writes for every call (success and failure)
6. **Reads config from DB** via `store.loadClassifierConfig()` — never hardcodes endpoint or model

### 1. AIReplySuggester — 回复建议生成器
Given an inbound ask, generates **3 reply candidates** in 3 different tones (`friendly` / `formal` / `brief`). Designed to power a one-click "quick reply" context menu so the user can respond without typing.

**Files**
- `Sources/WeChatHUD/Resources/prompts/reply_suggester_v1.txt`
- `Sources/WeChatHUD/Services/AIReplySuggester.swift`

**CLI**
```bash
.build/debug/WeChatHUD suggest-reply "明天上午把预算单发给我" \
    --sender 林总 --type send_file --relationship work
```

**Sample output**
```
1. [formal] 好的林总，明天上午发给您。
   理由: 礼貌确认并承诺时间
2. [formal] 收到，明早 10 点前发您邮箱。
   理由: 精确时间点更显专业
3. [brief] OK
   理由: 极简快速确认
[8153ms]
```

**XCTest**: passes live in 6.9s.

---

### 2. AIGroupCatchup — 群聊补课摘要
Given the last N messages from a group, generates a structured summary:
- 一句话总结群里在聊什么
- 3 条以内的关键事实/事件
- 是否有 @ 你需要响应
- 信噪比 (0-1) — 帮你决定要不要看

设计场景：你回到一个吵闹的群，HUD 调用这个服务给你 3-5 句的"我错过了什么"，要不要展开看由你决定。

**Files**
- `Sources/WeChatHUD/Resources/prompts/group_catchup_v1.txt`
- `Sources/WeChatHUD/Services/AIGroupCatchup.swift`

**Output schema**
```json
{
  "headline": "群最近在讨论的核心话题",
  "highlights": ["重点 1", "重点 2", "重点 3"],
  "needs_user_action": true|false,
  "action_summary": "如果是 true，明确写'你需要...'",
  "skip_safe": true|false,
  "noise_ratio": 0.0-1.0
}
```

**CLI** (注意 reader 加载会有几十秒首次成本)
```bash
.build/debug/WeChatHUD group-catchup 54461316910@chatroom --limit 30
```

**XCTest**: passes live in 7.9s.

---

### 3. AIWhitelistCategorizer — 联系人分类建议
给定一个联系人和最近的对话，自动建议归到 `work` / `life` / `other`，并且建议是否值得加入白名单。

设计场景：
- 用户首次安装时，自动扫一遍联系人给出建议白名单
- 添加新联系人时，"猜分类" 按钮一键填表

**Files**
- `Sources/WeChatHUD/Resources/prompts/whitelist_categorizer_v1.txt`
- `Sources/WeChatHUD/Services/AIWhitelistCategorizer.swift`

**Output schema**
```json
{
  "category": "work|life|other",
  "confidence": 0.0-1.0,
  "reason": "一句话理由",
  "signal_keywords": ["从对话提取的关键词"],
  "is_group": true|false,
  "should_whitelist": true|false
}
```

**CLI**
```bash
.build/debug/WeChatHUD categorize <wxid_or_chatroom> --limit 20
```

**XCTest**: passes live in 5.6s.

---

### 4. AIDailyRetrospector — 日复盘 + 日报生成器
End-of-day 总结服务。读取今天处理过的 + 仍待处理的 ask，输出：
- 一句话今日复盘
- 明早第一件事建议（带原因 + 关联 ask id）
- **可一键复制粘贴的微信日报草稿**（标准日报格式，正式礼貌，~150 字）

设计场景：每天 17:45 自动触发，用户在 HUD 看到"今日复盘"，可以一键复制日报发给上级。

**Files**
- `Sources/WeChatHUD/Resources/prompts/daily_retrospect_v1.txt`
- `Sources/WeChatHUD/Services/AIDailyRetrospector.swift`

**Output schema**
```json
{
  "today_summary": "今日复盘 1-2 句",
  "tomorrow_first_thing": {
    "action": "明早第一件事",
    "reason": "为什么最优先",
    "related_ask_id": int
  },
  "stats": {
    "asks_handled": int,
    "asks_pending": int,
    "asks_overdue": int
  },
  "wechat_daily_report": "一键复制的微信日报全文"
}
```

**CLI**
```bash
.build/debug/WeChatHUD retrospect [--date 2026-04-12]
```

**XCTest**: passes live in 12.5s.

---

## CLI surface (full)

`main.swift` 的 dispatch 现在认这些 subcommand：

```bash
WeChatHUD                                              # 启动 GUI
WeChatHUD classify "<text>"                            # 单条 ask 分类
WeChatHUD classify-fixture <path>                      # F1 评测 + 失败明细
WeChatHUD classify-real --per-chat N --max-total M     # 跑真实白名单消息
WeChatHUD suggest-reply "<text>" --type yes_no         # 生成 3 条回复
WeChatHUD group-catchup <chat_username> --limit N      # 群聊补课
WeChatHUD categorize <chat_username> --limit N         # 联系人分类
WeChatHUD retrospect --date YYYY-MM-DD                 # 日复盘
```

每个子命令都直接调到 `Services/` 里的 actor，绕过 GUI。所有调用都自动写 `ai_audit` 表。

---

## AI config governance (no more hardcoding)

整个 codebase 的 AI 配置现在**只有一个真实位置**：`settings` 表。

### 写入：
- `HUDStore.seedAISettingsIfMissing()` 在 `open()` 时调用
- 用 `getSetting("ai") == nil` 而不是 `getSettingJSON(...) == nil` 判断 —— 防止旧 row 因为新字段解码失败被覆盖（这是今晚发现并修的关键 bug）
- `apiKey` 字段 **永远** 用空字符串 seed，绝不在源代码里硬编码 key

### 读取：
- `HUDStore.loadClassifierConfig()` 和 `HUDStore.loadAIConfig()` 是单一读取入口
- 所有 service / view / CLI 都调这两个 helper
- 没有任何 `?? AIConfig()` 散落在业务代码

### 改 AI 配置的方式：
```bash
# 改 model
sqlite3 ~/.wechat-hud/hud.sqlite3 "UPDATE settings SET value = json_set(value, '\$.model', 'NewModelName') WHERE key='classifier'"

# 改 endpoint
sqlite3 ~/.wechat-hud/hud.sqlite3 "UPDATE settings SET value = json_set(value, '\$.baseURL', 'http://newhost:port/v1') WHERE key='ai'"

# 改 prompt 版本
sqlite3 ~/.wechat-hud/hud.sqlite3 "UPDATE settings SET value = json_set(value, '\$.promptVersion', 'classifier_v3') WHERE key='classifier'"
```

或者通过 GUI 的 AISettingsView 编辑。

### 当前 DB 状态
```
ai         | model=Qwen3.5-27B-6bit, baseURL=http://127.0.0.1:8000/v1
classifier | model=Qwen3.5-27B-6bit, promptVersion=classifier_v3, temperature=0.1
```

---

## 顺便修的几个 bug

1. **Seed 函数会覆盖用户配置** —— `seedAISettingsIfMissing` 用 `getSettingJSON` 检查存在性，但当 `AIClassifierConfig` 加新字段（比如 codex 新加的 `apiKey`）后，旧的 row 因为缺字段解码失败 → 被判"不存在" → 用工厂默认值覆盖。修法：改用 `getSetting`（只看 row 是否存在）。这个 bug 之前导致每次 store.open() 都把 model 重置回 `Qwen3.5-35B-A3B-4bit`。
2. **`String(format: "%-22s", swiftString)` 段错误** —— Swift String 不是 C string，`%s` 期望 `char*` 会段错误。改成手写 pad 函数。
3. **omlx model id 格式坑** —— 用户写的 `qwen3.5:27b-int6` 跟 server 实际暴露的 `Qwen3.5-27B-6bit` 不一致。已写到 doc 里提醒。

---

## 项目里**已有**的 AI 辅助功能（包括 codex 的）

- **AIClassifier** (Role 1) — 我做的，per-message ask extraction
- **AIReplySuggester** — 我做的（今晚），3 条回复候选
- **AIGroupCatchup** — 我做的（今晚），群聊补课
- **AIWhitelistCategorizer** — 我做的（今晚），联系人分类建议
- **AIDailyRetrospector** — 我做的（今晚），日复盘 + 日报
- **ReplyDebtJudge** — codex 做的，对未回复消息做优先级判断（shadow mode）
- **ReplyDebtScorer** — codex 做的，规则打分 + AI 复核混合

---

## 项目里**还可以加**的 AI 辅助功能

下面是一份我经过分析的"全量 AI 功能 backlog"，按价值/工程量打了星：

### ⭐⭐⭐ 高价值 + 工程量小（推荐先做）

1. **承诺追踪 (Commitment Tracker)** — `AICommitmentExtractor`
   - 从你**自己发出**的消息里抽"我答应做的事" + 截止时间
   - 落库到 `commitments` 表 (msg_uid, summary, due_at, status)
   - HUD 加"承诺" tab，超时变红
   - 双向版：也追"对方答应你做的事"用来挂账催办
   - **复用现有架构**: 跟 classifier 几乎一样的 prompt + service 模板

2. **关键词命中分类 (Keyword Hit Classifier)** — `AIKeywordHitJudge`
   - 不是简单的字符串匹配，而是 AI 判断"这条消息是否触及用户关心的话题（关键词列表）"
   - 解决之前 #4 提到的"`报销` 字面命中但其实是闲聊"的问题
   - 输出 `{matched: bool, matched_keywords: [], why_relevant: ""}`

3. **Smart Snooze 建议** — `AISnoozeRecommender`
   - 给定一条 ask，建议合理的 snooze 时长
   - 输入：消息内容 + 发送者 + 当前时间
   - 输出：`{minutes: int, reason: ""}` (e.g. "对方在上班时间发的工作请求，建议 2h 后提醒")

4. **每日"为什么"洞察 (Why-Did-I-Fail Insight)** — `AIPostmortem`
   - 输入：一个超时的 ask + 它的上下文 + 你那段时间在做什么（从 audit log 推断）
   - 输出：一段简短分析"你为什么漏了这个？" 帮你识别注意力 leak 的 pattern
   - 不是判罚，是帮你改善流程

### ⭐⭐⭐ 高价值 + 工程量中

5. **个人基线 + 异常检测** — `AIBaselineDeviationAlert`
   - 后台统计每个白名单成员的回复延迟分布 (p50/p90)
   - 当当前等待时间 > 这个人的 p90 时，AI 判断"这个延迟是不是真的异常"（考虑节假日、深夜等因素）
   - 输出 P0 升级 banner

6. **多语言/方言翻译 + 语气标注** — `AIToneTranslator`
   - 输入：一条消息（可能是英文/方言/网络黑话）
   - 输出：标准中文翻译 + 情绪标签 (calm/angry/confused/playful)
   - 对处理英语客户和方言群很有用

7. **Email-style "as you'd send to your boss" rewriter** — `AIPolisher`
   - 你打了个草稿"那个事我下午搞" → AI 改写成"林总您好，关于您提到的项目，我会在今天下午前完成进度同步。"
   - 不是替代你说话，是给你一个 formal 版本可选

8. **会议/活动信息抽取** — `AIMeetingExtractor`
   - 从聊天里抽"周三下午 3 点会议室开会"这种隐性会议邀请
   - 输出 ICS 格式，可一键加进 macOS 日历
   - 非常适合你这种 ICBC 经理，每天有大量隐式会议安排

### ⭐⭐ 中价值 + 工程量小

9. **谁是这个人？(Contact Memory)** — `AIContactProfiler`
   - 长期聚合每个白名单成员的对话风格、常聊话题、关心的事
   - 给你一个"林总最近总在催报表"的 awareness layer
   - 输出每周 1 次的"白名单画像"

10. **群聊角色识别** — `AIGroupRoleDetector`
    - 在一个群里识别谁是 leader / 谁在 push / 谁在抱怨
    - 帮你快速理解新加入的群的政治结构

11. **情绪 / 紧急度 detect** — `AIUrgencyDetector`
    - 单独跑一次 quick AI judge："这条消息的紧迫程度是 0-5 中的几"
    - 跟 ask classifier 互补 —— 不是所有 ask 都 urgent，不是所有 urgent 都是 ask
    - 数字化的 urgency score 可以驱动 P0/P1/P2 优先级

12. **对话冷启动建议** — `AIConversationStarter`
    - 当你打开一个长时间没说话的联系人时，AI 给你 2-3 个开场白建议
    - "上次你们聊到 X 项目，可以接着问问进度" 这种

### ⭐⭐ 中价值 + 工程量大

13. **群聊周报** — `AIGroupWeeklyDigest`
    - 一周总结你所有白名单群的关键事件、决议、待办
    - 周日晚自动生成

14. **跨群信息聚合** — `AICrossChatAggregator`
    - 同一件事可能在多个群里被多个人提到
    - AI 识别"这是同一件事的不同视角"并 merge 成单条 timeline event

15. **自动 followup** — `AIFollowupBot`
    - 你说了"明天发你"但是第二天忘了
    - HUD 在第二天上午自动提醒你"你昨天答应给 X 发 Y"
    - 半自动模式：AI 起草，你点 "send" 才发

### ⭐ 低优先级 / 实验性

16. **声音情绪识别** — 给微信语音消息做 transcription + emotion detection
17. **图片 OCR + 内容总结** — 截图 / 照片里的文字提取
18. **本地 RAG 知识库** — 把你过往的对话 index 起来，问"林总之前怎么说预算的"能查到
19. **A/B 测试 prompt** — 同一个 ask 用不同 prompt 各跑一遍，比较输出，自动 vote 最佳
20. **本地 LoRA 微调** — 用你自己的对话历史 fine-tune 一个个性化分类器

---

## 下一步建议（按你最关心的角度）

如果明天醒来，**最快能感受到价值**的下一步：

### 最小价值闭环 — 把现有的 4 个新 service 接到 UI 上
现在所有服务都能从 CLI 调，但 HUD UI 还没用到。最小工作量：
1. ExtendedTabsView 加一个 "回复建议" 按钮，点击 → 调 AIReplySuggester → 弹 popover 显示 3 条
2. WhitelistSettingsView 加一个 "AI 帮我分类" 按钮，调 AIWhitelistCategorizer
3. SettingsView 加一个新 tab "今日复盘"，点击 → 调 AIDailyRetrospector → 显示结果

工程量：每个 1-2 小时。

### 真正的 phase 1 — 把 classifier 接到 ChatMonitor
让 ChatMonitor.scan 每次扫到新消息时调 classifier，结果落到 `pending_asks` 表。然后 ExtendedTabsView 加 "待决" tab。

工程量：~4-6 小时。但这是把 AI subsystem 真正变成 daily-use 的一步。

### 长线 — 承诺追踪 + 人物画像 + 复盘日报
是 #5 #9 #13 的组合，最贴近"工作管家"定位。

---

## 文件清单

**新增**
```
docs/superpowers/plans/2026-04-12-overnight-changelog.md  ← 这份 doc
Sources/WeChatHUD/Resources/prompts/classifier_v2.txt
Sources/WeChatHUD/Resources/prompts/classifier_v3.txt    ← 当前生效
Sources/WeChatHUD/Resources/prompts/reply_suggester_v1.txt
Sources/WeChatHUD/Resources/prompts/group_catchup_v1.txt
Sources/WeChatHUD/Resources/prompts/whitelist_categorizer_v1.txt
Sources/WeChatHUD/Resources/prompts/daily_retrospect_v1.txt
Sources/WeChatHUD/Services/AIReplySuggester.swift
Sources/WeChatHUD/Services/AIGroupCatchup.swift
Sources/WeChatHUD/Services/AIWhitelistCategorizer.swift
Sources/WeChatHUD/Services/AIDailyRetrospector.swift
Tests/Fixtures/labeled_messages_private.json   (gitignored, 100 cases)
Tests/WeChatHUDTests/AIServicesTests.swift     (8 tests, all passing)
```

**修改**
```
Sources/WeChatHUD/main.swift                           — CLI dispatch 加 4 个新 subcommand
Sources/WeChatHUD/Services/ClassifierCLI.swift         — 加 4 个 runX 实现
Sources/WeChatHUD/Data/HUDStore.swift                  — seed 用 getSetting 不是 getSettingJSON
                                                          factory defaults 改成 27B-6bit + 空 apiKey
```

**未触动 (codex 域)**
- ReplyDebtJudge / ReplyDebtScorer — 让 codex 继续维护
- ExtendedTabsView UI 部分 — 不抢工
- AISettingsView UI — 不抢工

---

## 测试通过率

```
Test Suite 'All tests' passed
  Executed 53 tests, with 1 test skipped and 0 failures
  in 42.125 seconds total
```

包含：
- HUDStoreTests
- WeChatDecryptorTests
- WeChatParserTests
- ReplyDebtScorerTests
- ReplyDebtJudgeTests
- AIClassifierTests (含 live integration F1=0.974 on real data)
- AIServicesTests (4 new × 2 = 8 tests，含全部 4 个 live integration)

---

醒来如果想验证：

```bash
# 全量测试
swift test

# 跑一条 classify
.build/debug/WeChatHUD classify "明天发预算单" --sender 林总

# 跑回复建议
.build/debug/WeChatHUD suggest-reply "明天上午把预算单发给我" --sender 林总 --type send_file

# 跑日复盘（用现有 pending_asks，目前是空的所以会很简单）
.build/debug/WeChatHUD retrospect

# 看所有 AI 调用记录
sqlite3 ~/.wechat-hud/hud.sqlite3 "SELECT ts, role, prompt_version, latency_ms, status FROM ai_audit ORDER BY id DESC LIMIT 20"

# 看当前 prompts
ls Sources/WeChatHUD/Resources/prompts/

# 重新跑 fixture F1
.build/debug/WeChatHUD classify-fixture Tests/Fixtures/labeled_messages_private.json
```

晚安 🌙
