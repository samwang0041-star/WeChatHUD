# 第 32 轮：窗口走错了时钟、升级路径把降级放大成退出、暂停期间的积压

判据：多子代理持续质检到没有 P0。本轮三路并发（时钟/时间轴、常驻资源增长、读失败塌陷）
＋一路（老库升级路径），逐条回源码判定，成立 4 条 P0、修 3 条判阴 1 条，另收 P1 两条。

## §157 三处「窗口」记在墙钟上，用户拨一次表就把护栏和提醒一起抹掉

`Date()` 是系统**拥有**的量，不是它**测量**的量：用户可以手动改，macOS 也会在硬件时钟漂移后
校正。而这三处记录的窗口，比的都是「本进程亲眼看到的两个事件之间过了多久」：

- `AutopilotService.globalSendTimestamps` —— 每小时发送上限。墙钟**前进** 2 小时，
  所有时间戳被判成「一小时以前」→ 清空 → 同一个真实小时内可以再发一整轮无人值守回复。
  这条是无人值守发送的最后一道兜底，被一次拨表解除。
- `ProactiveAlertEngine.alertHistory` / `pushedIdentifiers` —— 每小时 5 条配额与
  按标识符的静默期（到期承诺是 24 小时）。**前进**：配额退回 + 未解决的到期承诺立刻再提醒一次；
  **后退**：所有记录变成「未来时间」→ 整个主动提醒（含 P0 未回规则）静默到墙钟追上来为止，
  而设置页仍然写着「已开启提醒」。这与第 30 轮修的「未来时间戳把对话永久静音」同一形状。
- `batchTimers` / `batchStartTimes` / `recentStallByContact` —— 批处理截止与缓兵之计去重。

新增 `Services/MonotonicClock.swift`（`ProcessInfo.processInfo.systemUptime`，只计开机后的
清醒时间）与可注入的 `MonotonicSeconds`。**判据是一条可复述的界线**：本进程自己观察到、
只跟自己比的时间 → 单调轴；要和数据库里的瞬间比、或要落盘的 → 墙钟。因此
`scheduledSendTime`（落盘、跨重启）、热聊 10 分钟窗口（比 `createTime`）、
`verifySend` 的 `startedAt`、`stalePendingSendReason` 全部**留在墙钟**上，代码里写明了为什么。
睡眠期不计是刻意的：睡着时本来就不发送也不评估，窗口跟着停只会让上限更严、批处理更晚，
不会让它提前触发。

会话时长 `SessionStats.duration` 的锚点是数据库里的 `started_at`（必须留在墙钟），
只补了 `max(0, …)`：倒退的墙钟以前会印出「-7200s」。

配套判据（`AutopilotBatchWindowTests` / `ProactiveAlertTests`）：
- `testBatchWindowIsMeasuredOnTheInjectedAxis` —— 注入一个「开机秒级」的时钟，
  只有这条轴越过截止点才排空批次。旧实现下截止点≈17.7 亿，怎么推都不动 → 该测试红。
- `testForwardWallClockJumpDoesNotRefireAnOverdueCommitment` /
  `testForwardWallClockJumpDoesNotRefillTheHourlyBudget` /
  `testBackwardWallClockJumpDoesNotMuteAlertsForever` —— 墙钟跳 ±3 天，单调轴只走 1 秒，
  三个方向各钉一条。
- `testSendCapAndStallWindowReadTheMonotonicAxis` —— 闸门函数体内必须出现 `monotonic()`
  且不得出现 `Date()`/`3600`；阈值只许在 `rollingSendHour` 里算一次。

变异记录（每次都用 python 断言锚点在，跑完 `cp` 还原，还原后 grep 变异标记为 0）：
M13（提醒窗口退回墙钟）→ 3 条新测试全红；M14（批处理排空退回墙钟）→ 注入轴测试 3 条断言红；
M15（每小时上限退回墙钟）→ 接线判据红；M18b（淘汰阈值改成 `.infinity`）→ 接线判据红。

顺手删掉两条假测试：`testRateLimitPreventsExcessAlerts` / `testRateLimitAllowsAfterPrune`
各自在测试里现造一个 `[Date]` 数组、用**自己写的** `removeAll { $0 < oneHourAgo }` 判一条
自己刚塞进去的断言，一行生产代码都没碰到。引擎级的窗口行为已由注入 `monotonic` 的
`testIdentifierDedupExpiresAfterOneHour` / `testHourlyBudgetIncludesInFlightAndReopensAfterWindow`
真实覆盖。

## §158 被吞掉错误的 ALTER，被一条硬 `try` 消费：一次 BUSY 就让老库用户永远打不开应用

`HUDStore.createTables()`：

```swift
_ = try? exec("ALTER TABLE autopilot_log ADD COLUMN queue_id TEXT")
try   exec("CREATE INDEX IF NOT EXISTS idx_autopilot_log_queue_id ON autopilot_log(queue_id)")
```

上面两行注释明说 `queue_id` 缺失是**可运行状态**（旧行保持 NULL，退回 (chat, reply) 文本匹配），
而下一条索引语句却把这条 ALTER 的成功当成前提。ALTER 真失败（另一个进程持有写锁超过
busy_timeout=5000、磁盘满、`hardenTree` 之后文件不可写）时，`no such column: queue_id`
从 `createTables()` 抛到 `store.open()`，`AppDelegate.swift:100` 的 catch 给出一个模态框
然后 `NSApp.terminate` —— **每个老库用户每次启动都是这样**。全仓 21 处 ALTER 里这是唯一一处
这种配对（`autopilot_inbound_queue.content_key` 与 `classification_queue.content_key` 都是
两条 `try?` 配套，做法正确）。

同一模式的第二处（P1）：`SchemaMigrator.migrateToV3RetrospectiveIndexes` 用硬 `try` 在
`red_banner_dismissals` / `review_todos` 上建索引，而这两张表由 `migrateRetrospective()` 的
`execIgnoringError` 建立 —— 表没建起来时同样是启动即退。

第三处（P1）：`conversation_memory` 的补列守卫只探测 `shared_context` 一列就跳过整段。
若第一条 ALTER 成功、第二条 BUSY，该库永久停在「有 shared_context、无 communication_notes」，
以后每次启动守卫都已满足，**再没有任何代码路径补这一列**，而读写它的地方全部静默失败。
改成逐列判断（新增 `HUDStore.tableInfo(_:)`，名字里非标识符字符直接返回空，
因为 PRAGMA 不能绑参）。

判据：`SchemaUpgradeResilienceTests`
- `testNoIndexHardFailsOnAColumnThatMayBeMissing` —— 扫全文件，任何 `try exec("CREATE INDEX …
  ON t(col)` 都不得建在被 `_ = try?` 吞掉的 ALTER 列上。带覆盖度下限（至少扫出 12 列 /
  10 条硬索引），否则「零命中」和「全部合格」长得一样。M16（还原成硬 `try`）→ 该判据红并
  指名 `665:autopilot_log.queue_id`。
- `testHalfMigratedConversationMemoryIsCompletedOnNextOpen` —— 真造一个「有
  shared_context、无 communication_notes」的库文件，重开一次必须补齐三列。
  旧守卫下重开十次也不会补。

## §159 暂停期间积压：缓冲区只进不出，恢复时回答几天前的消息

`handleNewMessages` 里 `allExpired = isPaused ? [] : …` —— 暂停时**没有任何批次会被排空**，
而：

- `batchBuffer` 全文件没有容量上限（`removeAll()` 只在 start/stop）；
- 暂停时不 ack，`ackedMsgUIDs` 只来自被处理的批次，`deleteAutopilotInbound` 完全依赖它 →
  磁盘表 `autopilot_inbound_queue` 只进不出；
- 去重屏障会被击穿：`processedMsgUIDs` 超 5000 裁到 2500，被裁掉的 UID 因为仍在磁盘队列里，
  会被 `loadPendingAutopilotInbound(limit: 200)` 重新喂进缓冲区。

用户可见的后果不是「内存有点大」，而是**恢复自动回复时去回答几天前的消息**。
「暂停」是用户主动关掉又不动它的最自然方式（不是异常态），所以可达。

修法是一条谓词、两个消费点：`AutopilotService.isPastReplyHorizon(timestamp:now:horizon:)`
（10 分钟，与它身边的缓兵去重/热聊窗口同量级，远大于 60 秒批处理上限）。
喂入时超龄的消息不进缓冲区（落一条 `.skipped` 审计行 + ack，让磁盘行随之消失）；
`ageOutBufferedMessages` 每趟扫一次已缓冲的内容，暂停期间也扫（`allExpired` 那一步被
`isPaused` 挡住，这一趟没有）。谓词刻意单边：未来时间戳算出负龄 → 保持可回复，
不让对端时钟超前把自己的对话永久静音（§128 的教训）。

判据：`testMessagePastTheHorizonIsDroppedAndAcknowledged`（旧代码 5 条断言全红，M17）、
`testBufferedBacklogAgesOutInsteadOfReplaying`、`testFutureTimestampsStayEligible`、
`testFeedPathRunsTheAgeOutSweepAndKeepsItsResult`。最后一条是接线判据而不是行为判据 ——
淘汰阈值可以从外部注入，`handleNewMessages` 里那一趟却没法用不动真实时间的测试驱动，
所以钉住「调用点存在 + 用生产阈值 + 返回的行与 id 都被接走」。

## §160 判阴：批处理 deadline 不会「永久卡住」

时钟轴那路代理另报一条 P0：「future-dated 批处理截止时间把队列永久卡住，重启后
`batchBuffer` 清零 → 这批消息永久不再被分类」。回源码不成立：

- 未 ack 的行**不会被删**（`deleteAutopilotInbound` 只吃 `ackedMsgUIDs`），因此重启后
  `loadPendingAutopilotInbound` 会把它们重新喂进来，`processedMsgUIDs` 是内存态、重启即空，
  于是拿到一个**全新的**截止时间 —— 不会永久不再分类。
- 唯一的永久清除发生在 `stop()`（`clearAutopilotInboundQueue`），那是用户亲手按下停止，
  丢弃是它该做的事。
- 所以墙钟倒退的真实伤害是「这段时间里批次不排空」，可自愈。仍然随 §157 一起换到单调轴，
  但记为 P2 而不是 P0。

同轮另两条判阴：
- 「扫描风暴」：`ChatMonitor.chasesPendingBatches(hasPending:paused:)` 已经处理过
  （注释里就写着暂停时批次永远排不掉，所以不再追），不是本轮新问题。
- 「autopilotActive 为真但 sessionId 为空时磁盘队列无限增长」：`autopilotActive` 只在
  `service.start()` 成功后置真、`stopAutopilot()` 无条件置假，两条路径都不留这个组合，
  判为不可达；真要加固应是「载入时按龄过滤」，但那会把该留审计行的消息静默删掉，
  与 §159 的做法相反，故不加。

## §161 未收口的（已定价，等决定）

`read-failure` 那路另报 3 条 P0 + 2 组 P1，逐条回源码后确认成立、但都不在本轮的时钟轴上，
留作下一轮：`isWhitelisted` 读失败 → 分类队列把该消息**当已处理删掉**（永久跳过，界面无痕）；
`resolveAutopilotLogSent` 事务被 `try?` 吞掉 → 双胞胎仍是 pending → 二次「确认发送」双发；
`?? AutopilotConfig()` 六处（含设置页的 merge-update 以默认值为基底覆写未暴露字段后仍显示
「已保存」）。以及通知授权（`error == nil` 当成送达、不检查 authorization、
`granted` 被丢弃、真话 `notificationExplanation` 是死代码）—— 那条单独一轮。

## §162 「已提醒」原来是算出来的：系统通知被拒时，配额和 24 小时静默期照扣

`ProactiveAlertEngine.pushAlert` 把 `completion(error == nil)` 当成「已送达」，
`systemNotificationSender` 提交前不看授权，`requestAuthorization` 的 `granted` 直接丢弃。
macOS 在通知被拒时 `add()` **不报错**，只是什么都不显示 —— 于是每条规则每次都：
扣掉一格每小时配额、给这个标识符记上静默期（到期承诺是 24 小时）。
用户后来去系统设置里打开通知，那一整段时间里仍然一条提醒都收不到，
而设置页写的是「接收待办提醒与重要更新。」——一句只有 macOS 同意才算数的话。

同页其实早就有一句按授权状态说实话的 `notificationExplanation`（`.denied` 分支写着
「通知未获允许，顶部浮窗和窗口仍可使用。」），**全仓零引用**，是死代码。

修法：
- 纯谓词 `canSubmitNotification(authorization:)`：`.authorized/.provisional/.ephemeral` 可提交
  （静默进通知中心也算送达，该扣配额），`.denied/.notDetermined` 不提交、**不扣任何账**，
  下一次评估就能补上；读取还没落地时 `nil` 失败打开，启动后第一条 P0 提醒不能因为
  一个还没回来的异步读被丢掉。
- 授权状态按 30 秒的节奏在 `evaluate` / `evaluateCommitmentDeadlines` 入口刷新，
  读的操作者自带回主 actor 的一跳（测试里同步完成）。生产 init 读真值，
  测试 init 默认 `.authorized`：`UNUserNotificationCenter.current()` 在测试宿主里不可用，
  而规则测试不该替通知中心回答「这条会不会显示」。
- 设置页那一行的副标题改成 `notificationExplanation`，删掉那句无条件的好处。

判据：`testDeniedAuthorizationDeliversNothingAndChargesNothing`（被拒不发 → 开启后**立刻**能发）、
`testAuthorizationGateFailsOpenOnlyBeforeTheFirstRead`、
`testNotificationRowSaysWhatTheSystemAllows`（钉住「一处定义、一处渲染」，
再少一处就是它又变回死代码）。变异 M19（闸门只看返回值不放行）→ 第一条断言红；
M20（`nil` 当不能提交）→ 纯谓据红，并且整套提醒测试一起红（说明「失败打开」是承重的）；
M21（被拒时仍记静默期）→ 「开启之后就该立刻提醒」那条红。

未覆盖面（本轮没查）：`RetrospectiveJob` 与其他直接 `add()` 的通知生产者是否有同形问题、
点击横幅的回跳路由、以及在 HUD 里处理完之后通知中心里的旧横幅是否还在说话。已另派一路。
