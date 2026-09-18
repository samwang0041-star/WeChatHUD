# 「我答应的事」提取算法规范

**状态**：as-built 基线（2026-09-18 从代码逆向整理，未改动任何行为）
**范围**：`commitments` 表的准入、判定、期限换算、状态推进、可见性；不含 UI 视觉与文案
**参考实现**：`Services/CommitmentTracker.swift`、`Services/CommitmentDeadlineResolver.swift`、`Services/MessageFeatureExtractor.swift`（反向门）、`Services/ScanEngine.swift`（selfOutgoingMessages 收集）、`Services/ChatMonitor.swift`（runPostScanAI 第 4 / 第 10 步）、`Data/HUDStore.swift`（upsert / 状态推进 / 清扫）、`Resources/prompts/commitment_v1.txt`

## 0. 定义

一句话：**把「你自己发出的、承诺了未来动作的消息」变成一张带原话、对象、期限和下一步的卡片；一条消息最多一张，且一生只判定有限次。**

| 项 | 规则 |
| --- | --- |
| 输入域 | 白名单会话 ∩ 水位线之后的"新消息"（含首次关注时覆盖的未读积压） |
| 排除 | sysmsg / 撤回事件行；非本人发送；本 App 代发（autopilot）的 uid |
| 输出 | `commitments` 一行（`msg_uid` 唯一），或什么都不写 |
| 归属 | 只属于"我"的承诺。对方承诺、我的提问都不属于本表 |

不变量：

1. 只有本人发出的消息能产生承诺；App 代发不算（否则是"AI 自己答应、自己确认"的自证循环）。
2. `msg_uid` 唯一：重放 / 重扫不会产生重复卡片；重新分析可覆盖字段，但不会抹掉已有期限（`COALESCE(excluded.deadline_at, commitments.deadline_at)`）。
3. `created_at` 取**消息发出时间**，不是扫描时间。
4. 一条消息一生最多判定 3 次，判过即定稿：改 prompt 不会自动重跑历史消息。
5. 唯一质量闸是 `is_commitment && confidence ≥ 0.72`；本页不接「待办」页的三档严格度（那条只管 `discussion_items`）。
6. 期限算不出来就是无期限；宁可缺，不做错。
7. 用户手动终态（已完成 / 已取消）永不被自动化覆盖。

## 1. 主流程（六段漏斗）

```text
for msg in newMessages(chat ∈ whitelist):

  L0 准入
    msg.sysKind != nil             → skip
    !isFromSelf(msg)               → skip
    msg.id ∈ autopilotSent         → skip
    !markCommitmentAnalyzedIfNew   → skip        # 已判过 / 3 次用尽

  L1 反向门（纯规则，不调 AI、不写审计）
    isOutgoingInquiryToPeer(原话)   → 判否，结束

  L2 AI 判定（commitment_v1）
    prompt 载入失败                 → 放弃，不留痕
    返回不可解析                    → 追加"只输出 JSON"重试 1 次
    两次都不可解析                  → 放弃（parseError 审计）

  L3 门槛
    !(is_commitment && conf ≥ 0.72) → skip

  L4 期限换算（程序负责）
    resolve(extracted, label, sourceText, messageDate) → Date?

  L5 归一化 + 落库
    upsert(msg_uid 唯一, status=pending, created_at=消息时间)

  L6 发布
    reloadLiveCommitments() → 侧栏徽标 / 列表 / 日报 / 提醒
```

### L0 准入（什么时机）

| 事件 | 时机与规则 |
| --- | --- |
| 常规新消息 | FSEvents 监听微信 DB 写入（秒级触发）；另有 `max(10, sync.intervalSeconds)` 的兜底定时扫描 |
| 首次关注某会话 | 同一次扫描内覆盖未读积压：页上限 100，未读多时按需后翻，单会话 ≤3 页、全局 6 页/扫描 |
| 重复消息 | 每条消息一生最多 3 次判定；老版本遗留的 `commitment_scans` 行 `attempts` 默认 3，即已定稿、永不重试 |
| 代发消息 | App 自己发出的回复永不算承诺，也不做交付证据 |
| 失败降级 | `markCommitmentAnalyzedIfNew` 抛错时**放行**（宁可多花一次 AI，不漏承诺）；审计写失败不影响判定 |

### L1 反向门（提问 ≠ 承诺）

命中任一 → 判否：

| 形态 | 例子 |
| --- | --- |
| 以 ？ / ? 结尾 | "这个多少钱？" |
| 提问动词开头（可省"我"，可出现在「，/ 。」呼唤名之后） | "问一下报价"、"谢潘，问下…" |
| `我来问…` | "我来问一下进度" |
| 以 吗 / 么 结尾 | "周五能到吗" |
| 以 呢 结尾 且含疑问词（什么 / 怎么 / 哪 / 谁 / 几 / 多少 / 为啥 / 为何 / 为什） | "发货呢？" |
| 含疑问短语：怎么样 / 多少钱 / 什么时候 / 哪天 / 怎么卖 / 什么情况 / 能否 / 可否 / 是否 / 如何（"无论如何"除外） | "能否本周交付" |

例外（**不**判提问，交给 AI）：含自我跟进标记的行——我去 / 我明天 / 我今天内 / 我稍后 / 回头告诉 / 回头回你(您) / 再回你(您) / 回你(您)一声 / 我处理 / 我安排 / 我跟进 / 我确认下 / 我确认一下 / 之后回你(您) / 之后回复你(您)。

- "我问一下老板，之后回你" → 是承诺（followup）
- "问一下六七千的报价" → 不是承诺（方向相反）

判否时返回固定理由 `发出的消息是向对方提问或咨询，非承诺`，`confidence = 0`，**不产生 AI 调用**。

### L2 AI 判定

模型输入：

| 槽位 | 内容 |
| --- | --- |
| 接收者 | 联系人显示名 + 角色（无记录时 acquaintance） |
| 时间锚点 | 该消息的绝对时间（含星期）——"明天 / 下周三"全靠它，模型不做日历换算 |
| 信号词 | 是否命中承诺信号词（明天 / 下周 / 今天内 / 稍后 / 马上 / 我去 / 我来 / 我发 / 我看看 / 我确认 / 帮你 / 好的 / 收到 / 没问题 / 月底前 …），仅作提示，不作门槛 |
| 上下文 | 该会话最近 10 条 → 裁剪为**最多 8 条、前看 5 条、后看 0 条**；中间断聊超过会话连续性阈值即切断 |
| 原话 | 脱敏后的消息文本 |

生成约束（写在 prompt 里）：`content` 20–36 字、必须含动作与交付物；`deadline_extracted / deadline_label` **原样照抄原话时间说法**，禁止自行换算；`commitment_kind ∈ {deliverable, followup, coordination, decision, schedule, other}`；`source_text` ≤60 字；`next_step` 必须可执行。

分类边界（算法真正的判别表）：

| 上文（对方 / 群） | 我的回复 | 判定 |
| --- | --- | --- |
| 明确任务或请求 | 好的 / 收到 | 是承诺（单独"收到"confidence 封顶 0.78，仍过 0.72 线） |
| 只是通报 / 群发 | 好的 / 收到 | 不是（已阅） |
| 明确请求 | 我看看 / 我了解下 / 我确认下 | 是（隐性承诺） |
| 问题或咨询 | 我去问一下再回你 | 是，kind = followup |
| 邀约 / 时间安排 | 可以 / 行 / OK | 是，kind = schedule |
| 任意 | 我向对方提问 | 不是（方向相反） |
| 任意 | 转述第三方（"他说明天发我"） | 不是（不是我的动作） |

调用参数：`temperature 0.05`、`maxTokens 512`、JSON 模式、超时 30s。JSON 解析失败追加"只输出符合 schema 的 JSON"重试一次（审计记 `commitment_v1_retry`）；两次失败按 `parseError` 落审计、不建卡。每次调用都写 `ai_audit`（`role = commitment_tracker`，含 provider 实际返回的模型名）。

`is_commitment = true` 但 `content` 或 `commit_to` 为空 → 视为畸形响应，整条丢弃。

### L3 门槛

`is_commitment == true` 且 `confidence ≥ 0.72`。confidence 读出后先钳制到 `0…1`（防 `1e400 → +inf`）。

### L4 期限换算（程序负责，模型只负责照抄）

优先级 `deadline_extracted → deadline_label → source_text`：原话只在模型两个结构化字段都无信号时兜底（原话里的日期可能是别人的事）。`deadline_extracted == "none"` 直接无期限、**不兜底**——模型明说没有时间，就不许从别的字段"凑"一个出来。

| 词形 | 语义 |
| --- | --- |
| 2026-09-20 / 2026/9/20 / 2026年9月20日 | 绝对日期 |
| 今天 / 今日、明天 / 明日 / tomorrow、后天 | 消息日 +0 / +1 / +2 |
| 本周X / 这周X、下周X、下下周X、上周X | 消息所在自然周（周一为首日）对应的星期 |
| 裸"周五" | 最近的将来那一次（周六说"周五"= 下个周五） |
| 无时间的日期 | 当天 23:59:59 |
| 只有时间（"下午 3 点"） | 落在消息当天，即使已过去也**不**顺延到明天 |
| +2h / +1d 这类相对量 | 消息时间 + 偏移 |

放弃规则（一律 → 无期限）：出现两个不同日期 / 畸形日期 / 多个"今天·明天·后天"标记 / 绝对日期与相对日期混用 / 畸形时间（如 24:00）/ 时间说法无法解析。宁可缺，不做错。

### L5 归一化与落库

| 字段 | 模型的 | 兜底 |
| --- | --- | --- |
| content | 20–36 字承诺 | —（空则整条丢弃） |
| commit_to | 承诺对象 | 裸 id（`…@chatroom`）→ 解析成会话显示名 |
| source_text | 原话 | 消息原文 |
| context_text | context_summary | 上下文窗口快照 |
| deadline_label | 人类可读期限 | 由 extracted + 解析结果生成 |
| next_step | 下一步 | `回到「会话名」确认并推进：{content}` |
| capture_reason | 判定理由 | `你的发言承诺了后续动作` |

写入 `status = pending`、`prompt_version = commitment_v1`、`created_at = 消息时间`；`ON CONFLICT(msg_uid)` 更新，期限用 COALESCE 保住旧值。

### L6 发布

异步任务收尾执行 `reloadLiveCommitments()` + `refreshWorkspaceChrome()`。消费方：侧栏徽标（窗口内 pending + overdue 条数）、承诺页、工作台、日报（pending / overdue 计数）、到期提醒。

## 2. 生命周期状态机

```text
                  交付证据命中（§2.1）
   pending ─────────────────────────────► fulfilled ──┐
      │  ▲                                            │
      │  │ 用户「恢复进行中」                           │ 用户手动
      │  └──────────────────────────────┐             │
      │ 截止已过且无证据                  │             │
      ▼                                 │             │
   overdue ──(迟到交付证据)──────────────►┘             │
      │                                                │
      └─ 撤回原话 / 移出白名单 / 30 天清扫 / 用户取消 ──► cancelled
```

要点：自动推进**只碰 pending**（`overdue → fulfilled` 为允许的例外，迟到交付可恢复）；手动终态不被覆盖；撤回原话与移出白名单是级联墓碑，会同时关掉同源待办。

### 2.1 自动闭环（交付证据）判定

```text
subject = 承诺内容 −前缀{我会,我来,我,明天,今天,稍后,回头,把,发送,发}
                    −后缀{发给你,发给您,给你,给您,发你} −标点
要求 |subject| ≥ 4 字，否则永不自动完成（退回人工）

候选 = 该会话最近 50 条消息
        ∧ 时间 > 承诺创建时间
        ∧ 本人发送 ∧ 非 App 代发

命中条件（全部满足）：
  含 subject
  ∧ 含交付词 {发你了,发给你了,发给您了,已发,已给你,已发送,给你了,给您了,传你了,传给你,
              推你了,推给你,搞定了,搞定,完成了,完成,已完成,处理完了,处理好了,处理完,处理完毕,
              做好了,做完了,做完,弄好了,弄完,OK了,ok了,Ok了,好了,办好了,安排好了,安排完了,跟进完了}
  ∧ 不含反悔/未完成/未来/模糊词 {没,未,不,还差,等,将,会,准备,打算,明天,稍后,回头,能否,是否,如果,
              吗,么,？,?,部分,初稿,草稿,进度,一半,%,其中,你说,他说,据说,说过,待,需要,
              完成后,完成前,完成时,完成再,完成就,预计,计划,正在,怎么}
→ fulfilled（理由写日志）
否则 deadline < now → overdue；否则 stillPending
```

### 2.2 可见性与清扫

| 机制 | 规则 |
| --- | --- |
| 读窗口 | 14 天：`created_at`、`deadline_at`、`updated_at` 任一 ≥ cutoff 即可见（页面与徽标同一口径） |
| 清扫（小时级，启动后首扫必跑） | pending / overdue 且 `created_at` 与 `updated_at` 都早于 30 天 且（无期限 或 期限早于 30 天）→ cancelled |
| 到期提醒 | 剩余 < 1 小时「承诺即将到期」；已过期「承诺已到期」（24 小时冷却） |

## 3. 纠偏通道（历史脏数据）

每次扫描 apply 后幂等执行：`repairStaleChatNames`（会话名）、`repairStaleCommitTargets`（承诺对象裸 id）、`repairInvertedInquiryRecords`（把 L1 上线前误判为承诺的"提问 + 去问…之后回复"行直接取消）。这是纠偏通道，不是新判定；同类输入此后已在 L1 入口拦截。

## 4. 可观测与验收

- 审计查询：`select ts, model, prompt_version, status, substr(input_text,1,40) from ai_audit where role='commitment_tracker' order by ts desc limit 50;`
- 纯函数即测试面：`MessageFeatureExtractor.isOutgoingInquiryToPeer`（反向门）、`CommitmentDeadlineResolver.resolve`（期限）、`CommitmentTracker.evaluateFulfillment`（闭环）、`SafeNumber.clamped`（数值钳制）
- 已有覆盖：`CommitmentTrackerTests`（信号词 / 提问不建卡 / 追问式承诺 / 审计模型名 / 修复历史行）、`CommitmentDeadlineResolverTests`（今天·明天·周X·冲突·畸形·none 约 20 例）、`CommitmentFulfillmentTests`（关键词闭环 / 无关媒体不闭环 / 早于承诺的证据无效 / 模糊证据仍可超期）、`NewSchemaTests`、`HUDStoreTests`（upsert / 窗口 / 幂等）

## 5. 已知缺口（待拍板）

| # | 缺口 | 影响 | 可能方向 |
| --- | --- | --- | --- |
| G1 | 0.72 是全局单点、无分层；同族 discussion 管线观测到 confidence 饱和 | 门槛的实际区分力未知 | 用 `ai_audit` 抽样测精确率/召回，再按 kind 或会话类型分层 |
| G2 | 每条自身消息一次 AI 调用，无每扫描上限 | 首次关注一个积压会话时会连发多次调用 | 加每扫描预算或按会话合并 |
| G3 | 交付证据只看该会话最近 50 条 | 聊天热闹时会漏闭环，卡片挂在"进行中" | 改为按承诺锚点向前查询 |
| G4 | `subject ≥ 4` 字 | 短承诺无法自动完成，只能人工点完成 | 允许"短但唯一"的匹配 |
| G5 | 期限词表有限（无"月底 / 十一 / 下周内"） | 多数卡片落到"无期限" | 扩词表；与 2026-09-12 报告里的 `due_at` 空值缺陷同批修 |
| G6 | 群聊承诺与私聊同权、无标注 | 群里的客套"好的我来"也会进本页，而同一句在自动托管里是要人工确认的 | 参照自动托管：群聊承诺加标注或需确认 |

## 6. 变更流程

§1 的判定表是基线：改算法先改本文档对应表格，再改代码，并在 §4 增加对应测试；prompt 语义变化时同步升版 `prompt_version`（现固定 `commitment_v1`，严格重试记 `commitment_v1_retry`）。
